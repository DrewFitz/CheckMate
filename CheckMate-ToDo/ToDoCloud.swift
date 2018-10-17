//
//  ToDoCloud.swift
//  CheckMate-ToDo
//
//  Created by Drew Fitzpatrick on 10/16/18.
//  Copyright © 2018 Andrew Fitzpatrick. All rights reserved.
//

import CloudKit
import os.log

extension Notification.Name {
    static let ToDoCloudDidUpdate = Notification.Name("ToDoCloudDidUpdate")
}

class ToDoCloud {

    static let shared = ToDoCloud()

    init() {
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

    private let container = CKContainer.default()
    private var zoneChangeTokens = [CKRecordZone.ID: CKServerChangeToken]()
    private var databaseChangeToken: CKServerChangeToken?
    private var todoZoneID: CKRecordZone.ID?

    private let group: CKOperationGroup = {
        let group = CKOperationGroup()

        group.expectedSendSize = .kilobytes
        group.expectedReceiveSize = .kilobytes

        group.name = "Fetch all data"
        return group
    }()

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
            }
        }

        changeOperation.recordZoneWithIDWasDeletedBlock = { zoneID in
            if zoneID.zoneName == "todos" {
                self.lists = []
                self.todos = []
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
                break
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
                break
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
