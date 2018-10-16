//
//  DetailViewController.swift
//  CheckMate-ToDo
//
//  Created by Drew Fitzpatrick on 10/15/18.
//  Copyright © 2018 Andrew Fitzpatrick. All rights reserved.
//

import UIKit
import CloudKit
import os.log

class DetailViewController: UITableViewController {

    let container = CKContainer.default()

    var list: CKRecord!
    var items = [CKRecord]()

    func fetchItems() {
        guard list != nil else { return }

        let predicate = NSPredicate(format: "list == %@", list.recordID)
        let query = CKQuery(recordType: "todo", predicate: predicate)
        let operation = CKQueryOperation(query: query)

        operation.recordFetchedBlock = { record in
            self.items.append(record)
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

        fetchItems()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "todo", for: indexPath)
        let todo = items[indexPath.row]
        cell.textLabel?.text = todo["title"] ?? "No title"
        cell.detailTextLabel?.text = todo["note"]
        cell.accessoryType = todo["dateCompleted"] == nil ? .none : .checkmark
        return cell
    }
}

