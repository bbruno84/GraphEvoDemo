import UIKit

/// Opening the laboratory never constructs the normal demo's GraphProvider.
final class LaunchViewController: UITableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "GraphEvoDemo"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = indexPath.row == 0 ? "GraphEvo v1 demo" : "Framework laboratory"
        cell.detailTextLabel?.text = indexPath.row == 0 ? "Notes, graph features and diagnostics" : "Isolated disposable stores; V01–V08 pending"
        cell.accessibilityTraits.insert(.button)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0 {
            let demo = MainTabBarController()
            demo.modalPresentationStyle = .fullScreen
            present(demo, animated: true)
        } else {
            navigationController?.pushViewController(LaboratoryViewController(style: .insetGrouped), animated: true)
        }
    }
}
