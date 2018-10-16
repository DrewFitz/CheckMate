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

    let cloud = ToDoCloud.shared

    var list: CKRecord! {
        didSet {
            navigationItem.title = list["title"]
            reloadData()
        }
    }

    var items = [CKRecord]()

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .ToDoCloudDidUpdate, object: cloud)
    }

    @objc func reloadData() {
        DispatchQueue.main.async {
            self.items = self.cloud.todos.filter { (todo) -> Bool in
                let reference = todo["list"] as! CKRecord.Reference
                return reference.recordID == self.list.recordID
            }

            self.tableView.reloadData()
        }
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

