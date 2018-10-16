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

class MasterViewController: UITableViewController {

    let container = CKContainer.default()

    var lists = [CKRecord]()

    var detailViewController: DetailViewController? = nil

    func fetchLists() {
        let query = CKQuery(recordType: "list", predicate: NSPredicate(value: true))
        let operation = CKQueryOperation(query: query)

        operation.recordFetchedBlock = { record in
            self.lists.append(record)
        }

        operation.queryCompletionBlock = { cursor, error in
            if let error = error {
                os_log(.error, "CKError: %{public}s", error.localizedDescription)
            } else {
                DispatchQueue.main.async {
                    self.tableView.reloadData()
                }
            }
        }

        container.privateCloudDatabase.add(operation)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.

        if let split = splitViewController {
            let controllers = split.viewControllers
            detailViewController = (controllers[controllers.count-1] as! UINavigationController).topViewController as? DetailViewController
        }

        fetchLists()
    }

    override func viewWillAppear(_ animated: Bool) {
        clearsSelectionOnViewWillAppear = splitViewController!.isCollapsed
        super.viewWillAppear(animated)
    }

    // MARK: - Segues

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "showDetail" {
            if let indexPath = tableView.indexPathForSelectedRow {
                let object = lists[indexPath.row]
                let controller = (segue.destination as! UINavigationController).topViewController as! DetailViewController
                controller.list = object
                controller.navigationItem.leftBarButtonItem = splitViewController?.displayModeButtonItem
                controller.navigationItem.leftItemsSupplementBackButton = true
            }
        }
    }

    // MARK: - Table View

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return lists.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)

        let object = lists[indexPath.row]
        cell.textLabel!.text = object["title"]
        return cell
    }

}

