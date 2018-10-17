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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(newItem))

        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: .ToDoCloudDidUpdate, object: cloud)
    }

    @objc func newItem() {
        let nav = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "newTodo") as! UINavigationController
        let newVC = nav.topViewController as! NewToDoViewController
        newVC.delegate = self
        present(nav, animated: true, completion: nil)
    }

    @objc func reloadData() {
        guard let list = list else { return }
        DispatchQueue.main.async {
            self.items = self.cloud.todos.filter { (todo) -> Bool in
                let reference = todo["list"] as! CKRecord.Reference
                return reference.recordID == list.recordID
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

extension ToDosViewController: NewToDoViewControllerDelegate {
    func done(_ vc: NewToDoViewController) {
        defer { dismiss(animated: true, completion: nil) }
        guard let list = list else { return }

        var newTodo = [String: CKRecordValueProtocol]()
        newTodo["title"] = vc.titleField.text
        newTodo["note"] = vc.noteField.text
        newTodo["dateCompleted"] = vc.completedSwitch.isOn ? Date() : nil
        newTodo["list"] = CKRecord.Reference(record: list, action: .deleteSelf)
        
        cloud.createToDo(with: newTodo)
    }

    func cancel(_: NewToDoViewController) {
        dismiss(animated: true, completion: nil)
    }
}

protocol NewToDoViewControllerDelegate: class {
    func done(_:NewToDoViewController)
    func cancel(_:NewToDoViewController)
}

class NewToDoViewController: UIViewController {
    @IBOutlet var titleField: UITextField!
    @IBOutlet var noteField: UITextField!
    @IBOutlet var dateCompletedField: UITextField!
    @IBOutlet var completedSwitch: UISwitch!

    weak var delegate: NewToDoViewControllerDelegate?

    @IBAction func cancelButtonTapped(_ sender: UIBarButtonItem) {
        delegate?.cancel(self)
    }

    @IBAction func doneButtonTapped(_ sender: UIBarButtonItem) {
        delegate?.done(self)
    }

}
