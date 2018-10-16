//
//  MasterViewController.swift
//  CheckMate-ToDo
//
//  Created by Drew Fitzpatrick on 10/15/18.
//  Copyright © 2018 Andrew Fitzpatrick. All rights reserved.
//

import UIKit
import CloudKit
import os.log

extension Notification.Name {
    static let ToDoCloudDidUpdate = Notification.Name(rawValue: "ToDoCloudDidUpdate")
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
    }

    private(set) var lists = [CKRecord]()
    private(set) var todos = [CKRecord]()

    private let container = CKContainer.default()
    private var zoneTokens = [CKRecordZone.ID: CKServerChangeToken]()
    private var databaseToken: CKServerChangeToken?

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

    private func fetchChangedZones(completion: @escaping ([CKRecordZone.ID]) -> Void) -> CKDatabaseOperation {
        var zones = [CKRecordZone.ID]()
        let changeOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: databaseToken)

        changeOperation.changeTokenUpdatedBlock = { token in
            print("Database token updated: \(token)")
            self.databaseToken = token
        }

        changeOperation.recordZoneWithIDChangedBlock = { zoneID in
            print("Zone changed: \(zoneID)")
            zones.append(zoneID)
        }

        changeOperation.recordZoneWithIDWasPurgedBlock = { zoneID in
            print("Zone was purged: \(zoneID)")
        }

        changeOperation.recordZoneWithIDWasDeletedBlock = { zoneID in
            print("Zone was deleted: \(zoneID)")
        }

        changeOperation.fetchDatabaseChangesCompletionBlock = { token, moreComing, error in
            print("Database changes completed: \(String(describing: token)), \(moreComing), \(String(describing: error))")
            completion(zones)
        }

        changeOperation.group = group

        return changeOperation
    }

    private func fetchChanges(in zones: [CKRecordZone.ID]) -> CKDatabaseOperation {

        let configurations = zones.map { (zone: CKRecordZone.ID) -> (CKRecordZone.ID, CKFetchRecordZoneChangesOperation.ZoneConfiguration)? in
            guard let token = zoneTokens[zone] else { return nil }
            return (zone, CKFetchRecordZoneChangesOperation.ZoneConfiguration(previousServerChangeToken: token, resultsLimit: nil, desiredKeys: nil))
        }

        var configsByID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
        for (zone, config) in configurations.compactMap({$0}) {
            configsByID[zone] = config
        }

        let recordsOperation = CKFetchRecordZoneChangesOperation(recordZoneIDs: zones, configurationsByRecordZoneID: configsByID)
        recordsOperation.recordChangedBlock = { record in
            print("record changed: \(record)")
            if record.recordType == "list" {
                self.lists.removeAll(where: { localRecord in
                    record.recordID == localRecord.recordID
                })
                self.lists.append(record)

            } else if record.recordType == "todo" {
                self.todos.removeAll(where: { localRecord in
                    record.recordID == localRecord.recordID
                })
                self.todos.append(record)
            }
        }

        recordsOperation.recordWithIDWasDeletedBlock = { id, type in
            print("record was deleted: \(type), \(id)")
        }

        recordsOperation.recordZoneFetchCompletionBlock = { id, token, clientTokenData, moreComing, error in
            self.zoneTokens[id] = token
            print("Record zone fetch completed: \(id), \(String(describing: token)), \(String(describing: clientTokenData)), \(moreComing), \(String(describing: error))")
        }

        recordsOperation.fetchRecordZoneChangesCompletionBlock = { error in
            print("Fetch record zone changes completion: \(String(describing: error))")
        }

        recordsOperation.recordZoneChangeTokensUpdatedBlock = { zoneID, token, clientTokenData in
            print("Record zone change tokens updated: \(zoneID), \(String(describing: token)), \(String(describing: clientTokenData))")
        }

        recordsOperation.group = group

        return recordsOperation
    }
}

class MasterViewController: UITableViewController {

    var detailViewController: DetailViewController? = nil

    var cloud = ToDoCloud.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.

        if let split = splitViewController {
            let controllers = split.viewControllers
            detailViewController = (controllers[controllers.count-1] as! UINavigationController).topViewController as? DetailViewController
        }

        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .ToDoCloudDidUpdate, object: cloud)

        cloud.fetchUpdates()
    }

    @objc func reloadData() {
        DispatchQueue.main.async {
            self.tableView.reloadData()
        }

    }

    override func viewWillAppear(_ animated: Bool) {
        clearsSelectionOnViewWillAppear = splitViewController!.isCollapsed
        super.viewWillAppear(animated)
    }

    // MARK: - Segues

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "showDetail" {
            if let indexPath = tableView.indexPathForSelectedRow {
                let object = cloud.lists[indexPath.row]
                let controller = (segue.destination as! UINavigationController).topViewController as! DetailViewController
                controller.list = object
                controller.navigationItem.leftBarButtonItem = splitViewController?.displayModeButtonItem
                controller.navigationItem.leftItemsSupplementBackButton = true
            }
        }
    }

    // MARK: - Table View

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return cloud.lists.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)

        let object = cloud.lists[indexPath.row]
        cell.textLabel!.text = object["title"]
        return cell
    }

}

