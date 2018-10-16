//
//  ListsViewController.swift
//  CheckMate-ToDo
//
//  Created by Drew Fitzpatrick on 10/15/18.
//  Copyright © 2018 Andrew Fitzpatrick. All rights reserved.
//

import UIKit

class ListsViewController: UITableViewController {

    var detailViewController: ToDosViewController? = nil

    var cloud = ToDoCloud.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.

        if let split = splitViewController {
            let controllers = split.viewControllers
            detailViewController = (controllers[controllers.count-1] as! UINavigationController).topViewController as? ToDosViewController
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
                let controller = (segue.destination as! UINavigationController).topViewController as! ToDosViewController
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

