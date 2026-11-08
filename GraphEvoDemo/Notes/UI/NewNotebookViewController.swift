import UIKit

/// One creation action with an explicit, iCloud-first destination choice.
@MainActor final class NewNotebookViewController: UITableViewController {
    private let application: NotesApplicationModel
    private let onCreated: (UUID) -> Void
    private let nameField = UITextField()
    private let cloudSwitch = UISwitch()
    private var busy = false
    private var failure: String?

    init(application: NotesApplicationModel, onCreated: @escaping (UUID) -> Void) {
        self.application = application
        self.onCreated = onCreated
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use the application initializer") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New notebook"
        nameField.placeholder = "Notebook name"
        nameField.autocapitalizationType = .sentences
        nameField.accessibilityLabel = "Notebook name"
        nameField.accessibilityIdentifier = "notebookName"
        nameField.addTarget(self, action: #selector(updateCreateButton), for: .editingChanged)
        cloudSwitch.isOn = true
        cloudSwitch.accessibilityLabel = "iCloud"
        cloudSwitch.accessibilityIdentifier = "notebookUsesCloud"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Create", style: .done, target: self, action: #selector(createNotebook))
        updateCreateButton()
    }
    override func numberOfSections(in tableView: UITableView) -> Int { failure == nil ? 1 : 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 2 : 1 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "iCloud is selected by default. Turn it off to keep this notebook only on this device." : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section == 1 {
            cell.textLabel?.text = failure
            cell.textLabel?.numberOfLines = 0
        } else if indexPath.row == 0 {
            nameField.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(nameField)
            NSLayoutConstraint.activate([
                nameField.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                nameField.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                nameField.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                nameField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
                nameField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            ])
        } else {
            cell.textLabel?.text = "iCloud"
            cell.accessoryView = cloudSwitch
        }
        return cell
    }
    @objc private func updateCreateButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !busy && !(nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    @objc private func cancel() { guard !busy else { return }; dismiss(animated: true) }
    @objc private func createNotebook() {
        guard !busy else { return }
        let name = nameField.text ?? ""
        let mode: NotebookMode = cloudSwitch.isOn ? .iCloud : .local
        busy = true; failure = nil
        isModalInPresentation = true; navigationController?.isModalInPresentation = true
        nameField.isEnabled = false; cloudSwitch.isEnabled = false
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.title = "Creating…"
        updateCreateButton(); view.endEditing(true)
        Task {
            do {
                let session = try await application.createNotebook(name: name, mode: mode)
                let onCreated = onCreated, id = session.entryID
                dismiss(animated: true) { onCreated(id) }
            } catch {
                application.recordFailure(error)
                failure = application.issue
                busy = false; nameField.isEnabled = true; cloudSwitch.isEnabled = true
                isModalInPresentation = false; navigationController?.isModalInPresentation = false
                navigationItem.leftBarButtonItem?.isEnabled = true
                navigationItem.rightBarButtonItem?.title = "Create"
                updateCreateButton(); tableView.reloadData()
            }
        }
    }
}
