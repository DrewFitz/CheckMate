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

    override init() {
        super.init()

        let privateSubscription = CKDatabaseSubscription()
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        privateSubscription.notificationInfo = notificationInfo
        let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [privateSubscription], subscriptionIDsToDelete: nil)

        container.privateCloudDatabase.add(operation)

        let todoZone = CKRecordZone(zoneName: "todos")
        let zoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [todoZone], recordZoneIDsToDelete: nil)
        container.privateCloudDatabase.add(zoneOperation)
    }

    private(set) var lists = [CKRecord]()
    private(set) var todos = [CKRecord]()
    private(set) var shares = [CKShare]()

    private var zoneChangeTokens = [CKRecordZone.ID: CKServerChangeToken]()
    private var databaseChangeToken: CKServerChangeToken?
    private var todoZoneID: CKRecordZone.ID?

    func fetchUpdates() {
        var zones = [CKRecordZone.ID]()

        let zonesOp = fetchChangedZones { newZones in
            zones = newZones
        }

        container.privateCloudDatabase.add(zonesOp)

        let next = BlockOperation {
            let changesOp = self.fetchChanges(in: zones)
            self.container.privateCloudDatabase.add(changesOp)

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
                share.recordID == shareReference.recordID
            }) {

            // existing share
            shareController = UICloudSharingController(share: share, container: container)
        } else {

            // new share
            shareController = UICloudSharingController(preparationHandler: { (controller, handler) in
                let newShare = CKShare(rootRecord: record)

                let op = CKModifyRecordsOperation(recordsToSave: [newShare, record], recordIDsToDelete: nil)

                op.modifyRecordsCompletionBlock = { saved, _, error in
                    saved?.forEach({ (record) in
                        if let recordAsShare = record as? CKShare {
                            // update share
                            self.shares.removeAll(where: { (localShare) -> Bool in
                                localShare.recordID == recordAsShare.recordID
                            })
                            self.shares.append(recordAsShare)
                        } else {
                            // update record
                            switch record.recordType {
                            case "todo":
                                self.todos.removeAll(where: { (localTodo) -> Bool in
                                    localTodo.recordID == record.recordID
                                })
                                self.todos.append(record)

                            case "list":
                                self.lists.removeAll(where: { (localList) -> Bool in
                                    localList.recordID == record.recordID
                                })
                                self.lists.append(record)

                            default:
                                break
                            }

                        }
                    })

                    handler(newShare, self.container, error)
                }

                self.container.privateCloudDatabase.add(op)
            })
        }

        shareController.delegate = self

        return shareController
    }

    func save(record: CKRecord) {
        let saveOperation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)

        saveOperation.modifyRecordsCompletionBlock = { savedRecords, deletedIDs, error in
            guard let records = savedRecords else {
                print("Error saving records: \(String(describing: error))")
                return
            }

            for record in records {
                switch record.recordType {
                case "todo":
                    self.todos.removeAll(where: { (local) -> Bool in
                        record.recordID == local.recordID
                    })
                    self.todos.append(record)
                case "list":
                    self.lists.removeAll(where: { (local) -> Bool in
                        record.recordID == local.recordID
                    })
                    self.lists.append(record)
                default:
                    break
                }
            }

            NotificationCenter.default.post(name: .ToDoCloudDidUpdate, object: self)
        }

        container.privateCloudDatabase.add(saveOperation)
    }

    func createToDo(with dictionary: [String: CKRecordValueProtocol]) {
        guard let todoZoneID = todoZoneID else { return }

        let newTodoID = CKRecord.ID(zoneID: todoZoneID)
        let newTodo = CKRecord(recordType: "todo", recordID: newTodoID)
        newTodo["title"] = dictionary["title"]
        newTodo["note"] = dictionary["note"]
        newTodo["dateCompleted"] = dictionary["dateCompleted"]
        newTodo["list"] = dictionary["list"]
        newTodo.parent = dictionary["parent"] as? CKRecord.Reference

        save(record: newTodo)
    }

    func createList(title: String) {
        guard let todoZoneID = todoZoneID else { return }
        let newListID = CKRecord.ID(zoneID: todoZoneID)
        let newList = CKRecord(recordType: "list", recordID: newListID)
        newList["title"] = title

        save(record: newList)
    }

    func deleteRecord(id: CKRecord.ID) {
        let deleteOperation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [id])

        deleteOperation.modifyRecordsCompletionBlock = { savedRecords, deletedIDs, error in
            guard let deletedIDs = deletedIDs else {
                print("Error saving records: \(String(describing: error))")
                return
            }

            for recordID in deletedIDs {
                self.todos.removeAll(where: { (local) -> Bool in
                    recordID == local.recordID
                })
                self.lists.removeAll(where: { (local) -> Bool in
                    recordID == local.recordID
                })
            }

            NotificationCenter.default.post(name: .ToDoCloudDidUpdate, object: self)
        }

        container.privateCloudDatabase.add(deleteOperation)
    }

    private func fetchChangedZones(completion: @escaping ([CKRecordZone.ID]) -> Void) -> CKDatabaseOperation {
        var zones = [CKRecordZone.ID]()
        let changeOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: databaseChangeToken)

        changeOperation.changeTokenUpdatedBlock = { token in
            self.databaseChangeToken = token
        }

        changeOperation.recordZoneWithIDChangedBlock = { zoneID in
            zones.append(zoneID)
            if zoneID.zoneName == "todos" {
                self.todoZoneID = zoneID
            }
        }

        changeOperation.recordZoneWithIDWasPurgedBlock = { zoneID in
            if zoneID.zoneName == "todos" {
                self.lists = []
                self.todos = []
                self.shares = []
            }
        }

        changeOperation.recordZoneWithIDWasDeletedBlock = { zoneID in
            if zoneID.zoneName == "todos" {
                self.lists = []
                self.todos = []
                self.shares = []
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

    private func fetchChanges(in zones: [CKRecordZone.ID]) -> CKDatabaseOperation {

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
            switch record.recordType {
            case "list":
                self.lists.removeAll(where: { localRecord in
                    record.recordID == localRecord.recordID
                })
                self.lists.append(record)

            case "todo":
                self.todos.removeAll(where: { localRecord in
                    record.recordID == localRecord.recordID
                })
                self.todos.append(record)

            default:
                if let share = record as? CKShare {
                    self.shares.removeAll(where: { localRecord in
                        share.recordID == localRecord.recordID
                    })
                    self.shares.append(share)

                }
            }
        }

        recordsOperation.recordWithIDWasDeletedBlock = { id, type in
            switch type {
            case "list":
                self.lists.removeAll(where: { (record) -> Bool in
                    record.recordID == id
                })
            case "todo":
                self.todos.removeAll(where: { (record) -> Bool in
                    record.recordID == id
                })
            default:
                self.shares.removeAll(where: { (share) in
                    share.recordID == id
                })
            }
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
        deleteRecord(id: share.recordID)
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        return "Item"
    }
}
