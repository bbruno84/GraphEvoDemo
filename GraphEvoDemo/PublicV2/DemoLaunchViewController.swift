import UIKit

/// Select the owning stack before any legacy cloud graph is initialized.
@MainActor final class DemoLaunchViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad(); title = "GraphEvoDemo"; view.backgroundColor = .systemBackground
        let label = UILabel(); label.numberOfLines = 0; label.textAlignment = .center
        label.text = "Choose the v1 demo or a separate GraphEvo 2 workspace. Existing stores are preserved."
        let legacy = UIButton(type: .system); legacy.setTitle("Open v1 demo", for: .normal)
        legacy.addTarget(self, action: #selector(openLegacy), for: .touchUpInside)
        let modern = UIButton(type: .system); modern.setTitle("Open GraphEvo 2", for: .normal)
        modern.addTarget(self, action: #selector(openModern), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, legacy, modern]); stack.axis = .vertical; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)])
    }
    @objc private func openLegacy() { view.window?.rootViewController = MainTabBarController() }
    @objc private func openModern() {
        do { navigationController?.pushViewController(try PublicV2ViewController.make(), animated: true) }
        catch {
            let alert = UIAlertController(title: "Cannot open v2 workspace", message: "Existing files have been preserved.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
        }
    }
}
