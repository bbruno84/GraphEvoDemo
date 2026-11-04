import UIKit
import CloudKit
import UniformTypeIdentifiers
import GraphEvo

/// Explicit v2 demonstration; ordinary v1 screens and their stores keep their own lifecycle.
@MainActor final class PublicV2ViewController: UITableViewController, UIDocumentPickerDelegate {
    static func make() throws -> PublicV2ViewController {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("GraphEvoDemo-PublicV2")
        return PublicV2ViewController(model: try PublicV2ViewModel(baseURL: base))
    }
    func receiveNativeInvitation(_ metadata: CKShare.Metadata) {
        guard let url = metadata.share.url else { model.recordFailure(PublicV2DemoError.invalidRoute); return }
        do { try model.stageNativeInvitation(url: url, container: metadata.containerIdentifier) }
        catch { model.recordFailure(error) }
    }
    private let model: PublicV2ViewModel
    private var pickingSource = false
    private let actions = ["Create local graph", "Open existing graph", "Add demo note", "Refresh notes",
        "Connect private cloud", "Bind private zone", "Request sync", "Retry account checks", "Import attachment",
        "Convert stopped v1 source", "Advance authoritative publication", "Recover empty replica", "New workspace", "Share with Apple UI", "Accept pending Apple invitation",
        "Resume shared invitations", "Inspect sharing status", "Leave shared graph", "Stop sharing as owner", "Release sharing presentation"]
    init(model: PublicV2ViewModel) { self.model = model; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "GraphEvo 2"
        model.onChange = { [weak self] in self?.tableView.reloadData() }
        NotificationCenter.default.addObserver(self, selector: #selector(active), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inactive), name: UIApplication.willResignActiveNotification, object: nil)
        if UIApplication.shared.applicationState == .active { active() }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { let model = model; Task { try? await model.close() } }
    }
    @objc private func active() { run { try await self.model.setForegroundActive(true) } }
    @objc private func inactive() { run { try await self.model.setForegroundActive(false) } }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : section == 1 ? actions.count : model.notes.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Current workspace", "Explicit operations", "Demo notes"][section]
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            cell.textLabel?.text = model.message + (model.convertedNodeCount.map { "\nConversion committed: \($0) identity mappings." } ?? "")
            cell.detailTextLabel?.text = "Local: \(model.accountDescription)\nCloud: \(model.cloudDescription)\nGraph: \(model.graphID.rawValue)\nZone: \(model.zoneName)\nSharing: \(model.sharingDescription)\nPending Apple invitations: \(model.incomingInvitations.count)"
            cell.selectionStyle = .none
        } else if indexPath.section == 1 {
            cell.textLabel?.text = actions[indexPath.row]; cell.textLabel?.textColor = .systemBlue
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = actions[indexPath.row]
            cell.accessibilityIdentifier = "public-v2.action." + String(indexPath.row)
            cell.accessibilityTraits = model.isBusy ? [.button, .notEnabled] : .button
            cell.isUserInteractionEnabled = !model.isBusy
            cell.contentView.alpha = model.isBusy ? 0.5 : 1
        } else { cell.textLabel?.text = model.notes[indexPath.row].title }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        switch indexPath.row {
        case 0: run { try await self.model.create() }
        case 1: run { try await self.model.open() }
        case 2: run { try await self.model.addNote() }
        case 3: run { try await self.model.refreshNotes() }
        case 4: form("Cloud configuration", fields: ["Entitled v2 container identifier", "Environment: development or production"], defaults: [model.incomingInvitations.first?.container ?? "", ""]) { values in
            guard let environment = GraphCloudEnvironment(rawValue: values[1]) else { self.model.recordFailure(GraphCloudConnectionError.invalidConfiguration); return }
            self.run { try await self.model.connect(container: values[0], environment: environment) }
        }
        case 5: run { try await self.model.bindPrivate() }
        case 6: run { try await self.model.requestSync() }
        case 7: run { try await self.model.retryAccounts() }
        case 8: pick(source: false)
        case 9: pick(source: true)
        case 10: form("Explicit v1 cloud cutover", fields: ["Selected authoritative source", "Why its contents are complete", "How old writers were stopped", "How returning old clients are prevented"]) { values in
            let declaration = GraphCloudCutoverDeclaration(sourceSelection: values[0], completeness: values[1], stoppedWriters: values[2], returningClients: values[3])
            self.run { try await self.model.publish(declaration: declaration) }
        }
        case 11: form("Recover into an empty workspace", fields: ["Owner Graph UUID", "Owner private zone name"]) { values in
            guard let id = UUID(uuidString: values[0]) else { self.model.recordFailure(PublicV2DemoError.invalidRoute); return }
            self.run { try await self.model.recoverReplica(graphID: GraphID(rawValue: id), zoneName: values[1]) }
        }
        case 12: run { try await self.model.newWorkspace() }
        case 13: run {
            try await self.model.releaseNativeSharing()
            let sharing = try await self.model.prepareNativeSharing()
            try sharing.present(from: self)
        }
        case 14: run { try await self.model.acceptPendingNativeInvitation() }
        case 15: run {
            try await self.model.refreshInvitations()
            let alert = UIAlertController(title: "Shared invitations", message: "Choose an identified graph. Existing workspace files are preserved.", preferredStyle: .actionSheet)
            for value in self.model.invitations {
                let label = (value.graphID?.rawValue.uuidString ?? "Identity pending") + " / " + value.phase.rawValue
                alert.addAction(UIAlertAction(title: label, style: .default) { _ in self.run { try await self.model.openSharedInvitation(value.id) } })
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.popoverPresentationController?.sourceView = self.view
            alert.popoverPresentationController?.sourceRect = self.view.bounds
            self.present(alert, animated: true)
        }
        case 16: run { try await self.model.inspectSharing() }
        case 17: confirm("Leave shared graph?", message: "This removes the local replica, attachments and unsent changes. Remote leave may remain pending while offline.") {
            self.run { try await self.model.leaveSharing() }
        }
        case 18: confirm("Stop sharing?", message: "All participants will lose access. Your owner graph is preserved.") {
            self.run { try await self.model.stopSharing() }
        }
        default: run { try await self.model.releaseNativeSharing() }

        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { model.recordFailure(error) } }
    }
    private func confirm(_ title: String, message: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Confirm", style: .destructive) { _ in action() })
        present(alert, animated: true)
    }
    private func form(_ title: String, fields: [String], defaults: [String] = [], action: @escaping ([String]) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        for (index, field) in fields.enumerated() { alert.addTextField { $0.placeholder = field; $0.autocapitalizationType = .none; if index < defaults.count { $0.text = defaults[index] } } }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in action(alert.textFields?.map { $0.text ?? "" } ?? []) })
        present(alert, animated: true)
    }
    private func pick(source: Bool) {
        pickingSource = source
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: source ? [.folder] : [.data], asCopy: false)
        picker.delegate = self; present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if pickingSource {
            form("Stopped v1 source", fields: ["SQLite file name inside this complete directory", "Type STOPPED to confirm all source writers are stopped"]) { values in
                self.run { try await self.model.convertV1(sourceDirectory: url, sqliteName: values[0], stoppedWritersConfirmed: values[1] == "STOPPED") }
            }
        } else { run { try await self.model.importAttachment(from: url) } }
    }
}
