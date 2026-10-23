import UIKit

final class LaboratoryViewController: UITableViewController {
    private let session = LaboratorySession.shared
    private var observationToken: UUID?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Framework laboratory"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Reports", style: .plain, target: self, action: #selector(showReports))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if observationToken == nil {
            observationToken = session.observeChanges { [weak self] in self?.tableView.reloadData() }
        }
        tableView.reloadData()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let observationToken { session.removeObserver(observationToken) }
        observationToken = nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { LaboratoryExperiment.planned.count + 3 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        switch indexPath.row {
        case 0:
            cell.textLabel?.text = "V00 — Local harness check · \(session.state.rawValue)"
            cell.detailTextLabel?.text = "Direct Core Data. Two disposable SQLite fixtures; save, close, reopen. Tap to run."
            cell.isUserInteractionEnabled = session.canRun
        case 1:
            cell.textLabel?.text = "Clean temporary laboratory stores"
            cell.detailTextLabel?.text = "Includes interrupted runs. Retains JSON reports. No remote resources."
            cell.isUserInteractionEnabled = session.state != .running
        case 2:
            cell.textLabel?.text = session.message
            cell.detailTextLabel?.text = "Tap to view or share this run's report."
        default:
            let experiment = LaboratoryExperiment.planned[indexPath.row - 3]
            cell.textLabel?.text = "\(experiment.id) — \(experiment.title)"
            cell.detailTextLabel?.text = experiment.id == "V01"
                ? "T0 observed; T1 natively rejected (preflight protected); T2 not run. No T3–T5."
                : "Not run · implementation and framework/integration boundary pending"
            cell.selectionStyle = .none
        }
        if indexPath.row < 3 { cell.accessibilityTraits.insert(.button) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.row {
        case 3: navigationController?.pushViewController(V01ViewController(), animated: true)
        case 0: Task { await session.runLocalCheck() }
        case 1:
            let alert = UIAlertController(title: "Remove laboratory stores?", message: "Only local disposable laboratory stores are removed. JSON reports remain available.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Clean stores", style: .destructive) { [weak self] _ in
                do { try self?.session.cleanStores() }
                catch { self?.showText(error.localizedDescription) }
            })
            present(alert, animated: true)
        case 2:
            let controller = UIViewController()
            controller.title = "Run report"
            let text = UITextView()
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            text.text = session.readableReport
            controller.view = text
            controller.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Share", style: .plain, target: self, action: #selector(shareReport))
            navigationController?.pushViewController(controller, animated: true)
        default: break
        }
    }

    @objc private func shareReport() {
        guard let url = session.shareableReportURL else {
            showText("A current final report has not been retained. Sharing is unavailable.")
            return
        }
        share([url])
    }

    @objc private func showReports() {
        do {
            let urls = try session.completedReportURLs()
            if urls.isEmpty { showText("No completed reports retained. Initial or interrupted records are not shared.") } else { share(urls) }
        } catch { showText("No reports available: \(error.localizedDescription)") }
    }

    private func share(_ items: [Any]) {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationController?.topViewController?.navigationItem.rightBarButtonItem
        navigationController?.topViewController?.present(controller, animated: true)
    }

    private func showText(_ text: String) {
        let alert = UIAlertController(title: "Laboratory", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (navigationController?.topViewController ?? self).present(alert, animated: true)
    }
}
