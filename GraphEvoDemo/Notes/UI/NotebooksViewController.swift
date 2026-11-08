import UIKit

@MainActor final class NotebooksViewController: UITableViewController {
    private let application: NotesApplicationModel
    nonisolated private enum Row: Hashable, Sendable { case notebook(UUID), cloud }
    private var source: UITableViewDiffableDataSource<Int, Row>!
    private var selectedID: UUID?
    private var observation: UUID?
    var onSelect: ((UUID) -> Void)?
    init(application: NotesApplicationModel) { self.application = application; super.init(style: .insetGrouped) }
    deinit {
        let application = application, token = observation
        Task { @MainActor in if let token { application.removeObserver(token) } }
    }
    required init?(coder: NSCoder) { fatalError("Use the application initializer") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Notebooks"
        tableView.register(NotebookSubtitleCell.self, forCellReuseIdentifier: "notebook")
        tableView.register(NotebookSubtitleCell.self, forCellReuseIdentifier: "cloud")
        source = UITableViewDiffableDataSource<Int, Row>(tableView: tableView) { [weak self] _, index, item in self?.cell(for: item, at: index) }
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(settings))
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(promptNewNotebook))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "New notebook"
        refreshControl = UIRefreshControl(); refreshControl?.addTarget(self, action: #selector(discover), for: .valueChanged)
        observation = application.observe { [weak self] in self?.render() }
        render()
    }
    private func render() {
        navigationItem.prompt = application.issue
        let old = Set(source.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>(); snapshot.appendSections([0, 1])
        snapshot.appendItems(application.notebooks.map { .notebook($0.id) }, toSection: 0)
        snapshot.appendItems([.cloud], toSection: 1)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { old.contains($0) })
        source.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, let selectedID else { return }; markSelected(selectedID)
        }
        if application.notebooks.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "folder.badge.plus"); empty.text = "Your notebooks"
            empty.secondaryText = "Create a local notebook, or connect iCloud in Settings to find and share notebooks."
            contentUnavailableConfiguration = empty
        } else { contentUnavailableConfiguration = nil }
    }
    func markSelected(_ id: UUID) {
        selectedID = id
        if let index = source?.indexPath(for: .notebook(id)) { tableView.selectRow(at: index, animated: false, scrollPosition: .none) }
    }
    private func cell(for item: Row, at index: IndexPath) -> UITableViewCell {
        let identifier = item == .cloud ? "cloud" : "notebook"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier, for: index)
        if case .notebook(let id) = item, let entry = application.notebooks.first(where: { $0.id == id }) {
            cell.textLabel?.text = application.displayName(for: entry)
            cell.detailTextLabel?.text = entry.deleting || entry.leaving ? "Removal pending — tap to retry" : (entry.creating || entry.recovering ? "Setup pending — tap to continue" : (entry.mode == .local ? "On this device" : (entry.mode == .shared ? "Shared with you" : "iCloud")))
            cell.imageView?.image = UIImage(systemName: entry.mode == .shared ? "person.2.fill" : "folder.fill")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "notebook-" + entry.id.uuidString
            cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: entry.mode == .shared ? "Leave notebook" : "Delete notebook") { [weak self] _ in
                self?.confirmRemoval(entry); return true
            }]
        } else {
            cell.textLabel?.text = application.cloudReady ? "iCloud connected" : "iCloud settings"
            cell.detailTextLabel?.text = application.issue ?? (application.catalog.invitations.isEmpty ? "Find notebooks and accept invitations in Settings." : "An Apple invitation is ready to continue in Settings.")
            cell.detailTextLabel?.numberOfLines = 0; cell.imageView?.image = UIImage(systemName: "icloud")
        }
        cell.isAccessibilityElement = true; cell.accessibilityTraits.insert(.button)
        cell.accessibilityLabel = cell.textLabel?.text; cell.accessibilityValue = cell.detailTextLabel?.text
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .notebook(let id) = source.itemIdentifier(for: indexPath),
              let entry = application.notebooks.first(where: { $0.id == id }) else { settings(); return }
        if entry.deleting || entry.leaving { run { try await self.application.retryRemoval(entry.id) } }
        else { onSelect?(entry.id) }
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .notebook(let id) = source.itemIdentifier(for: indexPath),
              let entry = application.notebooks.first(where: { $0.id == id }) else { return nil }
        let action = UIContextualAction(style: .destructive, title: entry.mode == .shared ? "Leave" : "Delete") { [weak self] _, _, completion in
            self?.confirmRemoval(entry); completion(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .notebook(let id) = source.itemIdentifier(for: indexPath),
              let entry = application.notebooks.first(where: { $0.id == id }) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: entry.mode == .shared ? "Leave notebook" : "Delete notebook",
                image: UIImage(systemName: entry.mode == .shared ? "rectangle.portrait.and.arrow.right" : "trash"),
                attributes: .destructive) { _ in self?.confirmRemoval(entry) }])
        }
    }
    private func confirmRemoval(_ entry: NotebookEntry) {
        let title = entry.mode == .shared ? "Leave shared notebook?" : (entry.mode == .iCloud ? "Delete notebook for everyone?" : "Delete this notebook?")
        let message = entry.mode == .shared ? "Remove this replica and unsent changes from this device. The owner's notebook remains." : "Permanently delete all notes, covers and documents in this notebook."
        let alert = UIAlertController(title: title, message: message + " Retained drafts on this device will be discarded.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: entry.mode == .shared ? "Leave" : "Delete", style: .destructive) { [weak self] _ in
            self?.run { try await self?.application.deleteNotebook(entry.id) }
        })
        present(alert, animated: true)
    }
    @objc private func settings() { navigationController?.pushViewController(NotesSettingsViewController(application: application), animated: true) }
    @objc private func discover() {
        run { try await self.application.discoverNotebooks(); self.refreshControl?.endRefreshing() }
    }
    @objc private func promptNewNotebook() {
        let alert = UIAlertController(title: "New notebook", message: "Choose where this notebook belongs.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Notebook name"; $0.autocapitalizationType = .sentences }
        alert.addAction(UIAlertAction(title: "On this device", style: .default) { [weak self, weak alert] _ in
            self?.create(name: alert?.textFields?.first?.text ?? "", mode: .local)
        })
        alert.addAction(UIAlertAction(title: "iCloud", style: .default) { [weak self, weak alert] _ in
            self?.create(name: alert?.textFields?.first?.text ?? "", mode: .iCloud)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
    private func create(name: String, mode: NotebookMode) {
        run {
            let session = try await self.application.createNotebook(name: name, mode: mode)
            self.onSelect?(session.entryID)
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { application.recordFailure(error) }
            refreshControl?.endRefreshing(); render()
        }
    }
}

@MainActor private final class NotebookSubtitleCell: UITableViewCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) { super.init(style: .subtitle, reuseIdentifier: reuseIdentifier) }
    required init?(coder: NSCoder) { fatalError("Use the table cell initializer") }
}
