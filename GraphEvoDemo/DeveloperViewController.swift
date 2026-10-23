import UIKit

final class DeveloperViewController: UIViewController {

    private let viewModel = DeveloperViewModel(provider: GraphProvider.shared)
    private let readinessLabel = UILabel()
    private let cloudStatusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Developer"
        tabBarItem = UITabBarItem(
            title: "Dev",
            image: UIImage(systemName: "gearshape"),
            selectedImage: UIImage(systemName: "gearshape.fill")
        )
        view.backgroundColor = .white

        viewModel.onStatusChanged = { [weak self] in
            self?.updateProviderStatus()
        }
        setupButtons()
        updateProviderStatus()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("✅ DeveloperViewController is visible")
    }

    private func setupButtons() {
        let actions: [(String, Selector)] = [
            ("Clear Token", #selector(clearToken)),
            ("Print Token Status", #selector(printTokenStatus)),
            ("Print Author & Context", #selector(printAuthorAndContext)),
            ("Refresh CloudKit State", #selector(refreshCloudKitState)),
            ("Create CloudKit Probe", #selector(createCloudKitProbe)),
            ("Create Action & Group Probe", #selector(createActionAndGroupProbe)),
            ("Run Predicate Probe", #selector(runPredicateProbe))
        ]

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
        stack.isLayoutMarginsRelativeArrangement = true

        readinessLabel.font = .preferredFont(forTextStyle: .subheadline)
        readinessLabel.textColor = .secondaryLabel
        readinessLabel.numberOfLines = 0
        cloudStatusLabel.font = .preferredFont(forTextStyle: .subheadline)
        cloudStatusLabel.textColor = .secondaryLabel
        cloudStatusLabel.numberOfLines = 0
        stack.addArrangedSubview(readinessLabel)
        stack.addArrangedSubview(cloudStatusLabel)

        actions.forEach { title, selector in
            stack.addArrangedSubview(makeButton(title: title, selector: selector))
        }

        let separator = UIView()
        separator.backgroundColor = .systemGray4
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(separator)

        let stressTestActions: [(String, Selector)] = [
            ("Create Attachment (1.5MB)", #selector(createLargeAttachment)),
            ("Clear All", #selector(clearAllTestData)),
            ("Stress Test", #selector(stressTest)),
            ("DB Dump", #selector(dumpTestSummary))
        ]
        stressTestActions.forEach { title, selector in
            stack.addArrangedSubview(makeButton(title: title, selector: selector))
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func makeButton(title: String, selector: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addTarget(self, action: selector, for: .touchUpInside)
        return button
    }

    private func updateProviderStatus() {
        readinessLabel.text = viewModel.readinessDescription
        cloudStatusLabel.text = viewModel.cloudStatusDescription
        readinessLabel.textColor = viewModel.isReady ? .systemGreen : .systemOrange
    }

    @objc private func clearToken() { viewModel.clearToken() }
    @objc private func printTokenStatus() { viewModel.printTokenStatus() }
    @objc private func printAuthorAndContext() { viewModel.printAuthorAndContext() }
    @objc private func refreshCloudKitState() { viewModel.refreshCloudKitState() }
    @objc private func createCloudKitProbe() { viewModel.createCloudKitProbe() }
    @objc private func createActionAndGroupProbe() { viewModel.createActionAndGroupProbe() }
    @objc private func runPredicateProbe() { viewModel.runPredicateProbe() }
    @objc private func createLargeAttachment() { viewModel.createLargeAttachment() }
    @objc private func clearAllTestData() { viewModel.clearAllTestData() }
    @objc private func stressTest() { viewModel.stressTest() }
    @objc private func dumpTestSummary() { viewModel.dumpTestSummary() }
}
