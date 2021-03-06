//
//  DetailViewController.swift
//  CheckMate-ToDo
//
//  Created by Drew Fitzpatrick on 10/15/18.
//  Copyright © 2018 Andrew Fitzpatrick. All rights reserved.
//

import UIKit
import os.log

class ToDosViewController: UITableViewController {

    let cloud = ToDoCloud.shared

    var list: CloudRecord? {
        didSet {
            navigationItem.title = list?.record["title"]
            reloadData()
        }
    }

    var items = [CloudRecord]()
    var editingItem: CloudRecord?

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let addItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(newItem))
        navigationItem.rightBarButtonItems = [addItem]

        let shareItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(presentShare(_:)))
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItems = [shareItem]

        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .ToDoCloudDidUpdate, object: cloud)
    }

    @objc func presentShare(_ sender: UIBarButtonItem) {
        guard let list = list else { return }

        let shareController = cloud.shareController(for: list.record)

        shareController.delegate = self
        shareController.availablePermissions = [.allowPrivate, .allowReadWrite]
        shareController.popoverPresentationController?.barButtonItem = sender

        self.present(shareController, animated: true, completion: nil)
    }

    @objc func newItem() {
        presentEditor()
    }

    func presentEditor() {
        let nav = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "newTodo") as! UINavigationController
        let editVC = nav.topViewController as! EditToDoViewController
        editVC.delegate = self

        editVC.loadViewIfNeeded()
        if let item = editingItem {
            editVC.titleField.text = item.record["title"]
            editVC.noteField.text = item.record["note"]
            if let date = item.record["dateCompleted"] as? Date {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                editVC.dateCompletedField.text = formatter.string(from: date)
                editVC.completedSwitch.isOn = true
            } else {
                editVC.completedSwitch.isOn = false
            }
        }

        present(nav, animated: true, completion: nil)
    }

    @objc func reloadData() {
        guard let list = list else { return }
        DispatchQueue.main.async {
            self.items = self.cloud.todos.filter { (todo) -> Bool in

                return todo.record.parent?.recordID == list.record.recordID

            }.sorted(by: { (lhs, rhs) -> Bool in
                let lhsTitle = lhs.record["title"] as! String?
                let rhsTitle = rhs.record["title"] as! String?
                return (lhsTitle ?? "") < (rhsTitle ?? "")
            })

            self.tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "todo", for: indexPath)
        let todo = items[indexPath.row]
        cell.textLabel?.text = todo.record["title"] ?? "No title"
        cell.detailTextLabel?.text = todo.record["note"]
        cell.accessoryType = todo.record["dateCompleted"] == nil ? .none : .checkmark
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        editingItem = items[indexPath.row]
        presentEditor()
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        switch editingStyle {
        case .delete:
            let recordToDelete = items.remove(at: indexPath.row)
            cloud.deleteRecord(recordToDelete)
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let editAction = UIContextualAction(style: .normal, title: "Edit") { (action, view, completion) in
            self.editingItem = self.items[indexPath.row]
            self.presentEditor()
            completion(true)
        }
        let config = UISwipeActionsConfiguration(actions: [editAction])

        return config
    }
}

extension ToDosViewController: EditToDoViewControllerDelegate {
    func done(_ vc: EditToDoViewController) {
        defer {
            editingItem = nil
            dismiss(animated: true, completion: nil)
        }

        guard let newTitle = vc.titleField.text,
            let newNote = vc.noteField.text,
            newTitle.isEmpty == false || newNote.isEmpty == false else {
                return
        }

        if let editingToDo = editingItem {
            editingToDo.record["title"] = newTitle
            editingToDo.record["note"] = newNote

            if vc.completedSwitch.isOn == true {
                if editingToDo.record["dateCompleted"] == nil {
                    // No completion date, so set it to now
                    editingToDo.record["dateCompleted"] = Date()
                } else {
                    // We already have a completion date, don't overwrite it
                }
            } else {
                // Switch is off, erase the completion date if there is one
                editingToDo.record["dateCompleted"] = nil
            }

            cloud.save(record: editingToDo)

        } else {
            guard let list = list else { return }

            var newTodo = [String: Any]()
            newTodo["title"] = newTitle
            newTodo["note"] = newNote
            newTodo["dateCompleted"] = vc.completedSwitch.isOn ? Date() : nil
            cloud.createToDo(with: newTodo, in: list)
        }

    }

    func cancel(_: EditToDoViewController) {
        dismiss(animated: true, completion: nil)
    }
}

protocol EditToDoViewControllerDelegate: class {
    func done(_:EditToDoViewController)
    func cancel(_:EditToDoViewController)
}

class EditToDoViewController: UIViewController {
    @IBOutlet var titleField: UITextField!
    @IBOutlet var noteField: UITextField!
    @IBOutlet var dateCompletedField: UITextField!
    @IBOutlet var completedSwitch: UISwitch!

    weak var delegate: EditToDoViewControllerDelegate?

    @IBAction func cancelButtonTapped(_ sender: UIBarButtonItem) {
        delegate?.cancel(self)
    }

    @IBAction func doneButtonTapped(_ sender: UIBarButtonItem) {
        delegate?.done(self)
    }

}

// MARK: - UICloudSharingControllerDelegate

extension ToDosViewController: UICloudSharingControllerDelegate {
    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        os_log(.error, "Faled to save share with error: %{public}s", error.localizedDescription)
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        guard let share = csc.share else { return }
        cloud.deleteRecord(share.recordID, in: .privateDatabase)
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        return list?.record["title"] ?? "List"
    }

    func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
        return UIImage(named: "ShareIcon")!.pngData()
    }
}
