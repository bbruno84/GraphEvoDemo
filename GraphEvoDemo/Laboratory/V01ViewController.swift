import UIKit

struct V01LaunchRequest {
    let role: String
    let runID: UUID
    let window: Int

    static func parse(_ arguments: [String]) -> V01LaunchRequest? {
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard arguments.contains("--v01-development-verified"),
              let role = value("--v01-role"), V01Session.validRoles.contains(role),
              let rawID = value("--v01-run-id"), let runID = UUID(uuidString: rawID),
              let window = Int(value("--v01-window") ?? "120"), (1...600).contains(window) else { return nil }
        return V01LaunchRequest(role: role, runID: runID, window: window)
    }
}

final class V01ViewController: UIViewController {
    private let session = V01Session.shared
    private var token: UUID?
    private let runIDField = UITextField()
    private let verified = UISwitch()
    private let output = UITextView()
    private let automaticRequest: V01LaunchRequest?

    init(automaticRequest: V01LaunchRequest? = nil) {
        self.automaticRequest = automaticRequest
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(automaticRequest:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "V01 — Framework trials"
        view.backgroundColor = .systemBackground
        let warning = UILabel()
        warning.text = "Direct frameworks, same account. T0: control. T1: rejected and preflight protected; T2 not run. T5: two distinct one-store owners and a dedicated fresh peer. No T3–T4 or wipe. One stage per process."
        warning.numberOfLines = 0
        runIDField.borderStyle = .roundedRect
        runIDField.placeholder = "Transfer the writer run UUID to the reader"
        runIDField.autocapitalizationType = .allCharacters
        runIDField.autocorrectionType = .no
        runIDField.text = automaticRequest?.runID.uuidString ?? UUID().uuidString
        let confirmation = UILabel()
        confirmation.text = "Signed dedicated Development configuration verified externally"
        confirmation.numberOfLines = 0
        let confirmationRow = UIStackView(arrangedSubviews: [confirmation, verified])
        let writer = UIButton(type: .system)
        writer.setTitle("Start writer (new run)", for: .normal)
        writer.addTarget(self, action: #selector(startWriter), for: .touchUpInside)
        let reader = UIButton(type: .system)
        reader.setTitle("Start fresh reader (no inserts)", for: .normal)
        reader.addTarget(self, action: #selector(startReader), for: .touchUpInside)
        let topologyWriter = UIButton(type: .system)
        topologyWriter.setTitle("T1: known rejected configuration (preflight only)", for: .normal)
        topologyWriter.addTarget(self, action: #selector(startT1), for: .touchUpInside)
        let peer = UIButton(type: .system)
        peer.setTitle("T2: not run (writer configuration rejected)", for: .normal)
        peer.isEnabled = false
        peer.addTarget(self, action: #selector(startT2), for: .touchUpInside)
        let independentWriter = UIButton(type: .system)
        independentWriter.setTitle("T5: two independent one-store owners", for: .normal)
        independentWriter.addTarget(self, action: #selector(startT5Writer), for: .touchUpInside)
        let independentReader = UIButton(type: .system)
        independentReader.setTitle("T5: fresh peer (no inserts or graph filter)", for: .normal)
        independentReader.addTarget(self, action: #selector(startT5Reader), for: .touchUpInside)
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.text = session.readableReport
        let stack = UIStackView(arrangedSubviews: [warning, runIDField, confirmationRow, writer, reader, topologyWriter, peer, independentWriter, independentReader, output])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Share", style: .plain, target: self, action: #selector(shareReport))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if token == nil { token = session.observeChanges { [weak self] in self?.output.text = self?.session.readableReport } }
        output.text = session.readableReport
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let request = automaticRequest, session.canStart {
            verified.isOn = true
            start(role: request.role, window: request.window)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let token { session.removeObserver(token) }
        token = nil
    }

    @objc private func startT1() { start(role: "t1-writer", window: 120) }
    @objc private func startT2() { start(role: "t2-reader", window: 120) }
    @objc private func startT5Writer() { start(role: "t5-writer", window: 120) }
    @objc private func startT5Reader() { start(role: "t5-reader", window: 120) }

    @objc private func startWriter() { start(role: "writer", window: 120) }
    @objc private func startReader() { start(role: "reader", window: 120) }

    private func start(role: String, window: Int) {
        guard verified.isOn, let runID = UUID(uuidString: runIDField.text ?? ""), session.canStart else {
            output.text = "Verify the Development signature, enter the shared run UUID, and restart before each stage."
            return
        }
        let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String ?? ""
        Task { await session.run(role: role, runID: runID, containerIdentifier: identifier,
                                 developmentVerified: true, windowSeconds: window) }
    }

    @objc private func shareReport() {
        guard session.finalReportRetained, !session.isRunning, let url = session.reportURL else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }
}
