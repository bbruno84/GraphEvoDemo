import UIKit
import GraphEvo

@MainActor final class NotesSettingsViewController: UITableViewController {
    private let application: NotesApplicationModel
    private let container = UITextField()
    private let environment = UISegmentedControl(items: ["Development", "Production"])
    private var observation: UUID?
    private var busy = false
    init(application: NotesApplicationModel) { self.application = application; super.init(style: .insetGrouped) }
    deinit {
        let application = application, token = observation
        Task { @MainActor in if let token { application.removeObserver(token) } }
    }
    required init?(coder: NSCoder) { fatalError("Use the application initializer") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Settings"
        container.placeholder = "iCloud container identifier"; container.text = application.suggestedContainer
        container.autocapitalizationType = .none; container.autocorrectionType = .no; container.borderStyle = .roundedRect
        container.accessibilityLabel = "iCloud container"; container.accessibilityIdentifier = "cloudContainer"
        environment.selectedSegmentIndex = application.catalog.preferences?.environment == .production ? 1 : 0
        environment.accessibilityLabel = "Cloud environment"
        observation = application.observe { [weak self] in self?.refreshStatus() }
    }
    private func refreshStatus() {
        guard isViewLoaded else { return }
        // Keep the editable controls attached while background observations arrive.
        tableView.reloadRows(at: [IndexPath(row: 2, section: 0), IndexPath(row: 4, section: 0),
            IndexPath(row: 0, section: 2)], with: .none)
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 5 : (section == 1 ? 2 : 1) }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { ["iCloud", "Tools", "Status"][section] }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "These settings are remembered. Local notebooks work independently of iCloud. Use Development with the signed test configuration." : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0, indexPath.row < 2 {
            let control: UIView = indexPath.row == 0 ? container : environment
            control.translatesAutoresizingMaskIntoConstraints = false; cell.contentView.addSubview(control)
            NSLayoutConstraint.activate([control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                control.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
                control.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10), control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
            cell.selectionStyle = .none
        } else {
            switch (indexPath.section, indexPath.row) {
            case (0, 2): cell.textLabel?.text = busy ? "Connecting…" : (application.cloudReady ? "Reconnect iCloud" : "Connect iCloud")
            case (0, 3): cell.textLabel?.text = "Find my iCloud notebooks"
            case (0, 4): cell.textLabel?.text = "Accept or resume invitations"; cell.detailTextLabel?.text = "Pending Apple links: " + String(application.catalog.invitations.count)
            case (1, 0): cell.textLabel?.text = "Request synchronization"
            case (1, 1): cell.textLabel?.text = "Diagnostics and legacy tools"; cell.accessoryType = .disclosureIndicator
            default: cell.textLabel?.text = application.cloudReady ? "iCloud connected" : "iCloud is not ready"; cell.detailTextLabel?.text = application.issue ?? "Local saves are independent of cloud delivery."
            }
            cell.detailTextLabel?.numberOfLines = 0
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy else { return }
        if indexPath.section == 1, indexPath.row == 1 { navigationController?.pushViewController(DemoLaunchViewController(), animated: true); return }
        Task {
            busy = true; refreshStatus(); defer { busy = false; refreshStatus() }
            do {
                switch (indexPath.section, indexPath.row) {
                case (0, 2):
                    view.endEditing(true)
                    try await application.connect(container: container.text ?? "", environment: environment.selectedSegmentIndex == 0 ? .development : .production)
                case (0, 3): try await application.discoverNotebooks()
                case (0, 4): try await application.acceptInvitations()
                case (1, 0): try await application.requestSynchronization()
                default: break
                }
            } catch { application.recordFailure(error) }
        }
    }
}
