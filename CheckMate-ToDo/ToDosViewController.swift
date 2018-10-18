//
//  DetailViewController.swift
//  CheckMate-ToDo
//
//  Created by Drew Fitzpatrick on 10/15/18.
//  Copyright © 2018 Andrew Fitzpatrick. All rights reserved.
//

import UIKit
import CloudKit

class ToDosViewController: UITableViewController {

    let cloud = ToDoCloud.shared

    var list: CKRecord? {
        didSet {
            navigationItem.title = list?["title"]
            reloadData()
        }
    }

    var items = [CKRecord]()
    var editingItem: CKRecord?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        let addItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(newItem))
        let shareItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(presentShare(_:)))
        navigationItem.rightBarButtonItems = [addItem, editButtonItem, shareItem]

        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .ToDoCloudDidUpdate, object: cloud)
    }

    @objc func presentShare(_ sender: UIBarButtonItem) {
        guard let list = list else { return }

        let shareController = cloud.shareController(for: list)

        shareController.availablePermissions = [.allowPrivate, .allowReadWrite]

        shareController.popoverPresentationController?.barButtonItem = sender

        present(shareController, animated: true, completion: nil)
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
            editVC.titleField.text = item["title"]
            editVC.noteField.text = item["note"]
            if let date = item["dateCompleted"] as? Date {
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
                let reference = todo["list"] as! CKRecord.Reference
                return reference.recordID == list.recordID
                }.sorted(by: { (lhs, rhs) -> Bool in
                    let lhsTitle = lhs["title"] as! String?
                    let rhsTitle = rhs["title"] as! String?
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
        cell.textLabel?.text = todo["title"] ?? "No title"
        cell.detailTextLabel?.text = todo["note"]
        cell.accessoryType = todo["dateCompleted"] == nil ? .none : .checkmark
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
            cloud.deleteRecord(id: recordToDelete.recordID)
        default:
            break
        }
    }
}

extension ToDosViewController: EditToDoViewControllerDelegate {
    func done(_ vc: EditToDoViewController) {
        defer { dismiss(animated: true, completion: nil) }

        if let editingToDo = editingItem {
            editingToDo["title"] = vc.titleField.text
            editingToDo["note"] = vc.noteField.text

            // If done and no date set, set date to now.
            // Otherwise unset date.
            if vc.completedSwitch.isOn == true,
                editingToDo["dateCompleted"] == nil {

                editingToDo["dateCompleted"] = Date()
            } else {
                editingToDo["dateCompleted"] = nil
            }

            cloud.save(record: editingToDo)
            editingItem = nil

        } else {
            guard let list = list else { return }

            var newTodo = [String: CKRecordValueProtocol]()
            newTodo["title"] = vc.titleField.text
            newTodo["note"] = vc.noteField.text
            newTodo["dateCompleted"] = vc.completedSwitch.isOn ? Date() : nil
            newTodo["list"] = CKRecord.Reference(record: list, action: .deleteSelf)
            newTodo["parent"] = CKRecord.Reference(record: list, action: .none)
            cloud.createToDo(with: newTodo)
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
