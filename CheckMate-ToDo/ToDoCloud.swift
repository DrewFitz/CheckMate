//
//  ToDoCloud.swift
//  CheckMate-ToDo
//
//  Created by Drew Fitzpatrick on 10/16/18.
//  Copyright © 2018 Andrew Fitzpatrick. All rights reserved.
//

import CloudKit
import UIKit
import os.log

extension Notification.Name {
    /// Posted any time ToDoCloud updates, whether or not there was new data
    static let ToDoCloudDidUpdate = Notification.Name("ToDoCloudDidUpdate")
}

/// Enum for specifing where a CloudRecord is stored
enum RecordLocation: String, Hashable, Codable {
    case privateDatabase
    case sharedDatabase
    case publicDatabase

    var database: CKDatabase {
        switch self {
        case .privateDatabase:
            return CKContainer.default().privateCloudDatabase
        case .sharedDatabase:
            return CKContainer.default().sharedCloudDatabase
        case .publicDatabase:
            return CKContainer.default().publicCloudDatabase
        }
    }
}

/// Enum denoting the the CKRecord type names
enum RecordType: String {
    case unknown

    case todo
    case list
    case brag

    // system default types
    case share = "cloudkit.share"
    case users = "Users"
}

/// Basic CKRecord Wrapper that has nicer type accessor and saves database info
class CloudRecord: NSSecureCoding {

    var record: CKRecord
    var type: RecordType
    var location: RecordLocation

    init(with record: CKRecord, location: RecordLocation) {
        self.record = record
        self.location = location
        self.type = RecordType(rawValue: record.recordType) ?? .unknown
    }

    // MARK: - NSSecureCoding

    static var supportsSecureCoding: Bool = true

    func encode(with aCoder: NSCoder) {
        aCoder.encode(record, forKey: "record")
        aCoder.encode(type, forKey: "type")
        aCoder.encode(location, forKey: "location")
    }

    required init?(coder aDecoder: NSCoder) {
        self.record = aDecoder.decodeObject(forKey: "record") as! CKRecord
        self.type = aDecoder.decodeObject(forKey: "type") as! RecordType
        self.location = aDecoder.decodeObject(forKey: "location") as! RecordLocation
    }
}

enum ErrorHandling {
    enum Strategy {
        case crashy
        case resilient
    }

    case unknown
    case retryAfter(seconds: Double?)
    case partialFailure(errorsByID: [AnyHashable: Error])
    case mergeAndRetry(ancestor: CKRecord?, server: CKRecord?)
    case immediateRetry
    case noRetry
    case nukeCacheAndFetchEverything
    case checkServerDataBeforeRetrying
    case logAndCrash
    case promptUser
    case retryWhenNetworkIsAvailable
    case noErrorWithThisRecord
    case splitUpAndRetry
    case redirectUserToVerificationURL
    case fixInconsistencyAndRetryIfNeeded

    init(from error: CKError, with strategy: Strategy = .resilient) {

        switch error.code {

        // Broken Builds, Programmer Errors, or Acts of God
        case .internalError,
             .missingEntitlement,
             .constraintViolation,
             .serverRejectedRequest,
             .invalidArguments,
             .badContainer,
             .badDatabase:
            self = (strategy == .crashy) ? .logAndCrash : .promptUser

        // Essentially a merge conflict
        case .serverRecordChanged:
            self = .mergeAndRetry(ancestor: error.ancestorRecord, server: error.serverRecord)

        // General network fuckery, make sure the request wasn't actually saved before sending it up again
        case .serverResponseLost:
            self = .checkServerDataBeforeRetrying

        // There's data inconsistency that needs addressing
        case .zoneNotFound,
             .alreadyShared:
            self = .fixInconsistencyAndRetryIfNeeded

        // Does what it says on the tin
        case .operationCancelled:
            self = .noRetry

        // We can't fetch deltas, gotta start all over
        case .changeTokenExpired:
            self = .nukeCacheAndFetchEverything

        // Configuration issue, we need to make smaller batch requests
        case .limitExceeded:
            self = .splitUpAndRetry

        // Assorted things the user has to fix or manually retry
        case .managedAccountRestricted,
             .notAuthenticated,
             .incompatibleVersion,
             .tooManyParticipants,
             .permissionFailure,
             .unknownItem,
             .referenceViolation,
             .userDeletedZone,
             .assetFileModified,
             .assetFileNotFound,
             .assetNotAvailable:
            self = .promptUser

        // Need to wait until there's network access again
        case .networkUnavailable:
            self = .retryWhenNetworkIsAvailable

        // General network error, just retry
        case .networkFailure:
            self = .immediateRetry

        // User needs to complete Apple's account-link flow
        case .participantMayNeedVerification:
            self = .redirectUserToVerificationURL

        // Temporarily can't complete this request, automatically try again later
        case .zoneBusy,
             .serviceUnavailable,
             .requestRateLimited:
            self = .retryAfter(seconds: error.retryAfterSeconds)

        // These two are related to batching requests
        case .partialFailure:
            self = .partialFailure(errorsByID: error.partialErrorsByItemID!)
        case .batchRequestFailed:
            self = .noErrorWithThisRecord

        // IDK what the heck you would actually do about this :shrug:
        case .quotaExceeded:
            self = .unknown

        case .resultsTruncated:
            fatalError("This is deprecated and should never be returned by the API since iOS 10")
        }
    }
}

class ToDoCloud: NSObject {

    // MARK: Singleton
    static let shared = ToDoCloud()

    override private init() {
        super.init()

        // make sure we're subscribed to both databases
        CKContainer.default().privateCloudDatabase.add(databaseSubscription())
        CKContainer.default().sharedCloudDatabase.add(databaseSubscription())

        // make sure we have a "todos" zone
        let todoZone = CKRecordZone(zoneName: "todos")
        let zoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [todoZone], recordZoneIDsToDelete: nil)
        CKContainer.default().privateCloudDatabase.add(zoneOperation)
    }

    // MARK: - Saved CloudKit Records
    private var records = [CloudRecord]()

    // MARK: - CloudKit Sync State Objects
    private var zoneChangeTokens = [CKRecordZone.ID: CKServerChangeToken]()
    private var databaseChangeTokens = [RecordLocation: CKServerChangeToken]()


    // MARK: - Private Data Accessors

    private func removeRecord(_ recordIDToRemove: CKRecord.ID) {
        records.removeAll { (localRecord) -> Bool in
            localRecord.record.recordID == recordIDToRemove
        }
    }

    private func removeRecord(_ recordToRemove: CloudRecord) {
        removeRecord(recordToRemove.record.recordID)
    }

    private func updateRecord(_ newRecord: CloudRecord) {
        removeRecord(newRecord)
        records.append(newRecord)
    }

    // MARK: - Public Data Accessors

    var lists: [CloudRecord] {
        return records.filter({ (record) -> Bool in
            record.type == .list
        })
    }

    var todos: [CloudRecord] {
        return records.filter({ (record) -> Bool in
            record.type == .todo
        })
    }

    var shares: [CloudRecord] {
        return records.filter({ (record) -> Bool in
            record.type == .share
        })
    }

    // MARK: - Public API Functions

    func fetchAllUpdates() {
        fetchUpdates(in: .privateDatabase)
        fetchUpdates(in: .sharedDatabase)
    }

    func shareController(for record: CKRecord) -> UICloudSharingController {
        if let shareReference = record.share,
            let share = shares.first(where: { (share) -> Bool in
                share.record.recordID == shareReference.recordID
            }) {

            // existing share
            return UICloudSharingController(share: share.record as! CKShare, container: CKContainer.default())

        } else {

            let shareController = UICloudSharingController { (controller, completion) in
                // new share
                let newShare = CKShare(rootRecord: record)

                newShare[CKShare.SystemFieldKey.thumbnailImageData] = UIImage(named: "ShareIcon")!.pngData()
                newShare[CKShare.SystemFieldKey.title] = record["title"]

                let op = CKModifyRecordsOperation(recordsToSave: [newShare, record], recordIDsToDelete: nil)

                op.modifyRecordsCompletionBlock = { saved, _, error in
                    saved?.forEach({ (record) in
                        self.updateRecord(CloudRecord(with: record, location: .privateDatabase))
                    })

                    completion(newShare, CKContainer.default(), error)

                    NotificationCenter.default.post(name: .ToDoCloudDidUpdate, object: self)
                }

                CKContainer.default().privateCloudDatabase.add(op)

            }

            return shareController
        }
    }

    func save(record: CloudRecord) {
        let saveOperation = CKModifyRecordsOperation(recordsToSave: [record.record], recordIDsToDelete: nil)

        saveOperation.modifyRecordsCompletionBlock = { savedRecords, deletedIDs, error in
            guard let records = savedRecords else {
                print("Error saving records: \(String(describing: error))")
                return
            }

            for newRecord in records {
                self.updateRecord(CloudRecord(with: newRecord, location: record.location))
            }

            NotificationCenter.default.post(name: .ToDoCloudDidUpdate, object: self)
        }

        record.location.database.add(saveOperation)
    }

    func createToDo(with dictionary: [String: Any], in list: CloudRecord) {
        let zone = list.record.recordID.zoneID

        let newTodoID = CKRecord.ID(zoneID: zone)
        let newTodo = CKRecord(recordType: "todo", recordID: newTodoID)

        newTodo["title"] = dictionary["title"] as! String
        newTodo["note"] = dictionary["note"] as! String
        newTodo["dateCompleted"] = dictionary["dateCompleted"] as! Date?
        newTodo["list"] = CKRecord.Reference(record: list.record, action: .deleteSelf)
        newTodo.parent = CKRecord.Reference(record: list.record, action: .none)

        save(record: CloudRecord(with: newTodo, location: list.location))
    }

    func createList(title: String) {
        let newListID = CKRecord.ID(zoneID: privateToDoZoneID)
        let newList = CKRecord(recordType: "list", recordID: newListID)
        newList["title"] = title

        save(record: CloudRecord(with: newList, location: .privateDatabase))
    }

    func deleteRecord(_ record: CloudRecord) {
        let deleteOperation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [record.record.recordID])

        deleteOperation.modifyRecordsCompletionBlock = { savedRecords, deletedIDs, error in
            guard let deletedIDs = deletedIDs else {
                print("Error saving records: \(String(describing: error))")
                return
            }

            for recordID in deletedIDs {
                self.removeRecord(recordID)
            }

            NotificationCenter.default.post(name: .ToDoCloudDidUpdate, object: self)
        }

        record.location.database.add(deleteOperation)
    }

    func deleteRecord(_ recordID: CKRecord.ID, in location: RecordLocation) {
        let deleteOperation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [recordID])

        deleteOperation.modifyRecordsCompletionBlock = { savedRecords, deletedIDs, error in
            guard let deletedIDs = deletedIDs else {
                print("Error deleting records: \(String(describing: error))")
                return
            }

            for recordID in deletedIDs {
                self.removeRecord(recordID)
            }

            NotificationCenter.default.post(name: .ToDoCloudDidUpdate, object: self)
        }

        location.database.add(deleteOperation)

    }

    // MARK: - Private Functions For Fetching Changes

    private func fetchUpdates(in location: RecordLocation) {
        let database = location.database
        var zones = [CKRecordZone.ID]()

        let zonesOp = fetchChangedZones(in: location) { newZones in
            zones = newZones
        }

        database.add(zonesOp)

        let next = BlockOperation {
            guard zones.count != 0 else { return }
            let changesOp = self.fetchChanges(in: zones, location: location)
            database.add(changesOp)

            let completionOp = BlockOperation {
                NotificationCenter.default.post(name: .ToDoCloudDidUpdate, object: self)
            }

            completionOp.addDependency(changesOp)
            OperationQueue.main.addOperation(completionOp)
        }

        next.addDependency(zonesOp)

        OperationQueue.main.addOperation(next)
    }

    private func fetchChangedZones(in location: RecordLocation, completion: @escaping ([CKRecordZone.ID]) -> Void) -> CKDatabaseOperation {
        var zones = [CKRecordZone.ID]()
        let changeOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: databaseChangeTokens[location])

        changeOperation.changeTokenUpdatedBlock = { token in
            self.databaseChangeTokens[location] = token
        }

        changeOperation.recordZoneWithIDChangedBlock = { zoneID in
            zones.append(zoneID)
        }

        changeOperation.recordZoneWithIDWasPurgedBlock = { zoneID in
            if zoneID == self.privateToDoZoneID {
                self.records = []
            }
        }

        changeOperation.recordZoneWithIDWasDeletedBlock = { zoneID in
            if zoneID == self.privateToDoZoneID {
                self.records = []
            }
        }

        changeOperation.fetchDatabaseChangesCompletionBlock = { token, moreComing, error in
            guard error == nil else {
                os_log(.error, "Fetch database changes error: %{public}s", error!.localizedDescription)
                return
            }

            if moreComing == false {
                completion(zones)
            }
        }

        changeOperation.group = group

        return changeOperation
    }

    private func fetchChanges(in zones: [CKRecordZone.ID], location: RecordLocation) -> CKDatabaseOperation {

        var configsByID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()

        zones.forEach { (zone) in
            if let token = zoneChangeTokens[zone] {
                configsByID[zone] = CKFetchRecordZoneChangesOperation.ZoneConfiguration(previousServerChangeToken: token, resultsLimit: nil, desiredKeys: nil)
            }
        }

        let recordsOperation = CKFetchRecordZoneChangesOperation(recordZoneIDs: zones, configurationsByRecordZoneID: configsByID)

        recordsOperation.recordChangedBlock = { record in
            self.updateRecord(CloudRecord(with: record, location: location))
        }

        recordsOperation.recordWithIDWasDeletedBlock = { id, _ in
            self.removeRecord(id)
        }

        recordsOperation.recordZoneFetchCompletionBlock = { zoneID, token, data, moreComing, error in
            guard error == nil else {
                os_log(.error, "Fetch Record Zone Error: %{public}s", error!.localizedDescription)
                return
            }
            self.zoneChangeTokens[zoneID] = token
        }

        recordsOperation.fetchRecordZoneChangesCompletionBlock = { error in
            guard error == nil else {
                os_log(.error, "Fetch Record Zone Changes Error: %{public}s", error!.localizedDescription)
                return
            }
            // do nothing
        }

        recordsOperation.group = group

        return recordsOperation
    }

    // MARK: - Private Conveniences

    private let privateToDoZoneID = CKRecordZone(zoneName: "todos").zoneID

    private let group: CKOperationGroup = {
        let group = CKOperationGroup()

        group.expectedSendSize = .kilobytes
        group.expectedReceiveSize = .kilobytes

        group.name = "Fetch all data"
        return group
    }()

    private func databaseSubscription() -> CKModifySubscriptionsOperation {
        let subscription = CKDatabaseSubscription()
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        return CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
    }
}
