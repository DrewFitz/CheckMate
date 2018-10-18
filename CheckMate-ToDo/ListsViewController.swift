//
//  ListsViewController.swift
//  CheckMate-ToDo
//
//  Created by Drew Fitzpatrick on 10/15/18.
//  Copyright © 2018 Andrew Fitzpatrick. All rights reserved.
//

import UIKit
import CloudKit

class ListsViewController: UITableViewController {

    var cloud = ToDoCloud.shared

    override func viewDidLoad() {
        super.viewDidLoad()

        let addItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addList))

        navigationItem.rightBarButtonItems = [addItem, editButtonItem]

        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .ToDoCloudDidUpdate, object: cloud)

        cloud.fetchAllUpdates()
    }

    @objc func addList() {
        presentEditor()
    }

    var editingRecord: CloudRecord?

    func presentEditor() {
        let nav = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "newList") as! UINavigationController

        let editVC = nav.topViewController as! EditListViewController

        editVC.delegate = self

        editVC.loadViewIfNeeded()
        editVC.titleField.text = editingRecord?.record["title"]

        present(nav, animated: true, completion: nil)
    }

    var sortedLists = [CloudRecord]()

    @objc func reloadData() {
        sortedLists = cloud.lists.sorted { (lhs, rhs) -> Bool in
            let lhsTitle = lhs.record["title"] as! String?
            let rhsTitle = rhs.record["title"] as! String?
            return (lhsTitle ?? "") < (rhsTitle ?? "")
        }

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
                let list = sortedLists[indexPath.row]
                let controller = (segue.destination as! UINavigationController).topViewController as! ToDosViewController
                controller.list = list
                controller.navigationItem.leftBarButtonItem = splitViewController?.displayModeButtonItem
                controller.navigationItem.leftItemsSupplementBackButton = true
            }
        }
    }

    // MARK: - Table View

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sortedLists.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)

        let list = sortedLists[indexPath.row]
        cell.textLabel!.text = list.record["title"]
        return cell
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let editAction = UIContextualAction(style: .normal, title: "Edit") { (action, view, completion) in
            self.editingRecord = self.sortedLists[indexPath.row]
            self.presentEditor()
            completion(true)
        }
        let config = UISwipeActionsConfiguration(actions: [editAction])

        return config
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        switch editingStyle {
        case .delete:
            let listToDelete = sortedLists[indexPath.row]
            cloud.deleteRecord(listToDelete)
        default:
            break
        }
    }
}

extension ListsViewController: EditListViewControllerDelegate {
    func cancel(_: EditListViewController) {
        dismiss(animated: true, completion: nil)
    }

    func done(_ editVC: EditListViewController) {
        defer {
            editingRecord = nil
            dismiss(animated: true, completion: nil)
        }
        guard let newTitle = editVC.titleField.text else { return }

        if let record = editingRecord {
            record.record["title"] = newTitle
            cloud.save(record: record)
        } else {
            cloud.createList(title: newTitle)
        }
    }
}

protocol EditListViewControllerDelegate: class {
    func cancel(_: EditListViewController)
    func done(_: EditListViewController)
}

class EditListViewController: UIViewController {
    @IBOutlet var titleField: UITextField!

    weak var delegate: EditListViewControllerDelegate?

    @IBAction func cancelButtonTapped(_ sender: UIBarButtonItem) {
        delegate?.cancel(self)
    }

    @IBAction func doneButtonTapped(_ sender: UIBarButtonItem) {
        delegate?.done(self)
    }
}
