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
    static let ToDoCloudDidUpdate = Notification.Name("ToDoCloudDidUpdate")
}

enum RecordLocation: Hashable {
    case privateDatabase
    case sharedDatabase
    case publicDatabase

    func database() -> CKDatabase {
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

enum RecordType: String {
    case unknown

    case todo
    case list
    case brag

    // system default types
    case share = "cloudkit.share"
    case users = "Users"
}

struct CloudRecord {
    var record: CKRecord
    var type: RecordType
    var location: RecordLocation

    init(with record: CKRecord, location: RecordLocation) {
        self.record = record
        self.location = location
        self.type = RecordType.init(rawValue: record.recordType) ?? .unknown
    }
}

class ToDoCloud: NSObject {

    static let shared = ToDoCloud()
    private let container = CKContainer.default()

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

    override init() {
        super.init()

        // make sure we're subscribed to both databases
        container.privateCloudDatabase.add(databaseSubscription())
        container.sharedCloudDatabase.add(databaseSubscription())

        // make sure we have a "todos" zone
        let todoZone = CKRecordZone(zoneName: "todos")
        let zoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [todoZone], recordZoneIDsToDelete: nil)
        container.privateCloudDatabase.add(zoneOperation)
    }

    private var records = [CloudRecord]()

    private func removeRecord(_ recordIDToRemove: CKRecord.ID) {
        records.removeAll { (localRecord) -> Bool in
            localRecord.record.recordID == recordIDToRemove
        }
    }

    private func removeRecord(_ recordToRemove: CloudRecord) {
        records.removeAll { (localRecord) -> Bool in
            localRecord.record.recordID == recordToRemove.record.recordID
        }
    }

    private func updateRecord(_ newRecord: CloudRecord) {
        removeRecord(newRecord)
        records.append(newRecord)
    }

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

    private var zoneChangeTokens = [CKRecordZone.ID: CKServerChangeToken]()
    private var databaseChangeTokens = [RecordLocation: CKServerChangeToken]()

    private var privateToDoZoneID: CKRecordZone.ID?

    func fetchAllUpdates() {
        fetchUpdates(in: .privateDatabase)
        fetchUpdates(in: .sharedDatabase)
    }

    func fetchUpdates(in location: RecordLocation) {
        let database = location.database()
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

    func shareController(for record: CKRecord) -> UICloudSharingController {
        let shareController: UICloudSharingController

        if let shareReference = record.share,
            let share = shares.first(where: { (share) -> Bool in
                share.record.recordID == shareReference.recordID
            }) {

            // existing share
            shareController = UICloudSharingController(share: share.record as! CKShare, container: container)
        } else {

            // new share
            shareController = UICloudSharingController(preparationHandler: { (controller, handler) in
                let newShare = CKShare(rootRecord: record)

                newShare[CKShare.SystemFieldKey.thumbnailImageData] = UIImage(named: "ShareIcon")!.pngData()

                let op = CKModifyRecordsOperation(recordsToSave: [newShare, record], recordIDsToDelete: nil)

                op.modifyRecordsCompletionBlock = { saved, _, error in
                    saved?.forEach({ (record) in
                        self.updateRecord(CloudRecord(with: record, location: .privateDatabase))
                    })

                    handler(newShare, self.container, error)
                }

                self.container.privateCloudDatabase.add(op)
            })
        }

        shareController.delegate = self

        return shareController
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

        record.location.database().add(saveOperation)
    }

    func createToDo(with dictionary: [String: CKRecordValueProtocol], in location: RecordLocation) {
        let listRef = dictionary["list"] as! CKRecord.Reference

        let zone = listRef.recordID.zoneID
        let newTodoID = CKRecord.ID(zoneID: zone)

        let newTodo = CKRecord(recordType: "todo", recordID: newTodoID)
        newTodo["title"] = dictionary["title"]
        newTodo["note"] = dictionary["note"]
        newTodo["dateCompleted"] = dictionary["dateCompleted"]
        newTodo["list"] = listRef
        newTodo.parent = dictionary["parent"] as? CKRecord.Reference

        save(record: CloudRecord(with: newTodo, location: location))
    }

    func createList(title: String) {
        guard let todoZoneID = privateToDoZoneID else { return }
        let newListID = CKRecord.ID(zoneID: todoZoneID)
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

        record.location.database().add(deleteOperation)
    }

    func deleteRecord(_ recordID: CKRecord.ID, in location: RecordLocation) {
        let deleteOperation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [recordID])

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

        location.database().add(deleteOperation)

    }

    private func fetchChangedZones(in location: RecordLocation, completion: @escaping ([CKRecordZone.ID]) -> Void) -> CKDatabaseOperation {
        var zones = [CKRecordZone.ID]()
        let changeOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: databaseChangeTokens[location])

        changeOperation.changeTokenUpdatedBlock = { token in
            self.databaseChangeTokens[location] = token
        }

        changeOperation.recordZoneWithIDChangedBlock = { zoneID in
            zones.append(zoneID)
            if zoneID.zoneName == "todos", location == .privateDatabase {
                self.privateToDoZoneID = zoneID
            }
        }

        changeOperation.recordZoneWithIDWasPurgedBlock = { zoneID in
            if zoneID.zoneName == "todos" {
                self.records = []
            }
        }

        changeOperation.recordZoneWithIDWasDeletedBlock = { zoneID in
            if zoneID.zoneName == "todos" {
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

        let configurations = zones.map { (zone: CKRecordZone.ID) -> (CKRecordZone.ID, CKFetchRecordZoneChangesOperation.ZoneConfiguration)? in
            guard let token = zoneChangeTokens[zone] else { return nil }
            return (zone, CKFetchRecordZoneChangesOperation.ZoneConfiguration(previousServerChangeToken: token, resultsLimit: nil, desiredKeys: nil))
        }

        var configsByID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
        for (zone, config) in configurations.compactMap({$0}) {
            configsByID[zone] = config
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
}

extension ToDoCloud: UICloudSharingControllerDelegate {
    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        os_log(.error, "Faled to save share with error: %{public}s", error.localizedDescription)
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        guard let share = csc.share else { return }
        deleteRecord(share.recordID, in: .privateDatabase)
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        return "Item"
    }
}
