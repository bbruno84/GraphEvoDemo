import Foundation
import UIKit
import CloudKit

nonisolated struct V02Report: Codable {
    var procedure = "V02-cross-account-smoke-v1"
    let runID: UUID
    let stageID: UUID
    let processID: UUID
    let role: V02Role
    let started: Date
    let windowSeconds: Int
    let environment: [String: String]
    var finished: Date?
    var phase = "Preflight"
    var outcome = "Running; not completed evidence"
    var stores: [String: String] = [:]
    var baseline: [V02Row] = []
    var members: [V02Row] = []
    var fixtureSaved = false
    var participantEditSaved = false
    var invitationPersisted = false
    var acceptanceCompleted = false
    var exactObservation = false
    var preparationObserved = false
    var sensitiveArtifact: String?
    var events: [V01NativeEvent] = []
    var droppedEvents = 0
    var errors: [String] = []
    var traceWriteFailures = 0
    var traceDroppedEntries = 0
    var finalReportRetained = false
}

/// Files contain account identity and invitation URLs. Only filenames appear in reports.
@MainActor
enum V02SensitiveFiles {
    static func write(_ envelope: V02Envelope, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw V02Error.retentionFailure }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var directory = url.deletingLastPathComponent()
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read(_ url: URL) throws -> V02Envelope {
        let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
        guard attributes.isSymbolicLink != true, attributes.isRegularFile == true,
              (attributes.fileSize ?? Int.max) < 32_768 else { throw V02Error.invalidEnvelope }
        return try JSONDecoder().decode(V02Envelope.self, from: Data(contentsOf: url))
    }
}

@MainActor
final class V02Session {
    static let shared = V02Session()
    private let root: URL
    private let permitSimulator: Bool
    private let account: @MainActor (String) async throws -> CKRecord.ID
    private let makeStore: @MainActor (CKRecord.ID, T6Trace) -> V02StoreAccess
    private let now: @MainActor () -> Date
    private let sampleSleep: @MainActor () async throws -> Void
    private var started = false
    private(set) var report: V02Report?
    private(set) var reportURL: URL?
    var didChange: ((String) -> Void)?

    init(root: URL? = nil, permitSimulatorForTests: Bool = false,
         account: @escaping @MainActor (String) async throws -> CKRecord.ID = { identifier in
             let container = CKContainer(identifier: identifier)
             guard try await container.accountStatus() == .available else { throw V01Error.accountUnavailable }
             return try await container.userRecordID()
         }, makeStore: @escaping @MainActor (CKRecord.ID, T6Trace) -> V02StoreAccess = { V02CloudStore(currentUser: $0, trace: $1) },
         now: @escaping @MainActor () -> Date = Date.init,
         sampleSleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("V02Laboratory")
        permitSimulator = permitSimulatorForTests
        self.account = account; self.makeStore = makeStore
        self.now = now; self.sampleSleep = sampleSleep
    }

    func run(_ request: V02Request, container: String) async {
        guard !started else { return }
        started = true
        let stage = UUID()
        let basename = "\(request.runID)-\(request.role.rawValue)-\(stage)"
        let reportURL = root.appendingPathComponent("Reports/" + basename + ".json")
        self.reportURL = reportURL
        var environment = Dictionary(uniqueKeysWithValues: ["LaboratoryDemoRevision", "LaboratoryGraphEvoRevision", "LaboratorySourceState", "LaboratoryToolchain"].map {
            ($0, Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "Unrecorded")
        })
        environment["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        environment["deviceClass"] = UIDevice.current.model
        environment["topology"] = "One owner, private and shared SQLite; run-scoped reads in both stores"
        report = V02Report(runID: request.runID, stageID: stage, processID: UUID(), role: request.role,
                           started: Date(), windowSeconds: request.window, environment: environment)
        var store: V02StoreAccess?
        var trace: T6Trace?
        var heartbeat: Task<Void, Never>?
        func persist() throws {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: reportURL, options: .atomic)
            didChange?(String(decoding: data, as: UTF8.self))
        }
        func checkpoint(_ phase: String) throws { report?.phase = phase; try persist() }
        do {
            try persist()
            guard !GraphProvider.wasInitialized, !container.isEmpty else { throw V01Error.missingConfiguration }
            #if targetEnvironment(simulator)
            guard permitSimulator else { throw V01Error.missingConfiguration }
            #endif
            let recorder = try T6Trace(url: reportURL.deletingPathExtension().appendingPathExtension("trace.jsonl"))
            trace = recorder
            recorder.record(.runStarted)
            heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                    recorder.record(.mainActorHeartbeat)
                    report?.traceWriteFailures = recorder.counts.failures
                    report?.traceDroppedEntries = recorder.counts.dropped
                    do { try persist() } catch { recorder.record(.checkpointFailed) }
                }
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
            try checkpoint("Checking current account")
            let user = try await account(container)
            let sensitive = root.appendingPathComponent("Sensitive/\(request.runID)")
            if request.role == .identity {
                let file = sensitive.appendingPathComponent("participant-identity.json")
                try V02SensitiveFiles.write(V02Envelope(purpose: "participant-identity", runID: request.runID,
                    containerIdentifier: container, account: V02PrivateID(user)), to: file)
                report?.sensitiveArtifact = file.lastPathComponent
                report?.outcome = "Participant identity retained locally; no fixture, invitation or acceptance performed."
            } else {
                let side = request.role.isOwner ? "owner" : "participant"
                let bindingURL = sensitive.appendingPathComponent(side + "-binding.json")
                if request.role.createsStores {
                    try V02SensitiveFiles.write(V02Envelope(purpose: "account-binding", runID: request.runID,
                        containerIdentifier: container, account: V02PrivateID(user)), to: bindingURL)
                } else {
                    let binding = try V02SensitiveFiles.read(bindingURL)
                    try binding.validate(runID: request.runID, container: container, purpose: "account-binding")
                    guard binding.account.recordID == user else { throw V02Error.invalidAccount }
                }
                let opened = makeStore(user, recorder)
                store = opened
                try checkpoint(request.role.createsStores ? "Opening fresh private/shared stores" : "Reopening existing private/shared stores")
                try await opened.open(directory: root.appendingPathComponent("Stores/\(request.runID)/\(side)"),
                    container: container, fresh: request.role.createsStores) { [weak self] event in
                    guard let self, self.report?.finished == nil else { return }
                    if self.report?.events.count ?? 0 < 128 { self.report?.events.append(event) }
                    else { self.report?.droppedEvents += 1 }
                }
                report?.stores = opened.inventory
                report?.baseline = try await opened.snapshot(runID: request.runID)
                try persist()
                switch request.role {
                case .ownerPrepare:
                    guard report?.baseline.isEmpty == true else { throw V02Error.invalidFixture }
                    try checkpoint("Saving new owner fixture in private scope")
                    try await opened.insertFixture(runID: request.runID)
                    report?.fixtureSaved = true
                    let saved = try await opened.snapshot(runID: request.runID)
                    guard V02Fixture.exact(saved, owner: true, edited: false, requireShares: false) else { throw V02Error.invalidFixture }
                    for graph in ["A", "B"] {
                        try checkpoint("Creating owner-only share for " + graph)
                        try await opened.createShare(graph: graph, runID: request.runID) { try persist() }
                    }
                    try await observe(opened, request: request, persist: persist)
                case .ownerInvite:
                    guard request.invitationAuthorized, let name = request.input, V02Request.validFilename(name) else { throw V02Error.unauthorizedInvitation }
                    let identity = try V02SensitiveFiles.read(root.appendingPathComponent("Inbox/" + name))
                    try checkpoint("Resolving the explicitly authorized participant and persisting a private A invitation")
                    let invitation = try await opened.invite(identity, runID: request.runID, container: container) { try persist() }
                    report?.invitationPersisted = true
                    let file = sensitive.appendingPathComponent("private-invitation.json")
                    try V02SensitiveFiles.write(invitation, to: file)
                    report?.sensitiveArtifact = file.lastPathComponent
                    try await observe(opened, request: request, persist: persist)
                case .participantAccept:
                    guard report?.baseline.isEmpty == true, let name = request.input, V02Request.validFilename(name) else { throw V02Error.invalidFixture }
                    let invitation = try V02SensitiveFiles.read(root.appendingPathComponent("Inbox/" + name))
                    try checkpoint("Validating metadata and accepting the private invitation into shared scope")
                    try await opened.accept(invitation, runID: request.runID, container: container) { try persist() }
                    report?.acceptanceCompleted = true
                    try await observe(opened, request: request, persist: persist)
                case .participantEdit:
                    try checkpoint("Saving the single participant edit to the existing shared A child")
                    try await opened.edit(runID: request.runID)
                    report?.participantEditSaved = true
                    try await observe(opened, request: request, persist: persist)
                case .ownerObserve, .ownerReopen, .participantReopen:
                    try await observe(opened, request: request, persist: persist)
                case .identity: break
                }
            }
        } catch {
            report?.errors.append(v01ErrorCode(error))
            report?.outcome = "Stage failed; no retry, fallback, replacement fixture or invitation replay."
        }
        heartbeat?.cancel()
        do { try await store?.close() }
        catch { report?.errors.append("Close: " + v01ErrorCode(error)) }
        report?.phase = "Ended; stores detached. Terminate process before the next stage."
        report?.finished = Date()
        trace?.record(.runFinished)
        report?.traceWriteFailures = trace?.counts.failures ?? 0
        report?.traceDroppedEntries = trace?.counts.dropped ?? 0
        report?.finalReportRetained = true
        do { try persist() }
        catch {
            report?.finalReportRetained = false
            report?.outcome = "Inconclusive: final report retention failed."
            didChange?("Final report retention failed; do not use an earlier Running checkpoint as completed evidence.")
        }
    }

    private func observe(_ store: V02StoreAccess, request: V02Request, persist: () throws -> Void) async throws {
        report?.phase = "Sampling entire run in both database scopes"
        let edited = request.role != .participantAccept
        let preparing = request.role == .ownerPrepare || request.role == .ownerInvite
        let holdFullWindow = preparing || request.role == .participantEdit
        let deadline = now().addingTimeInterval(TimeInterval(request.window))
        repeat {
            let members = try await store.snapshot(runID: request.runID)
            report?.members = members
            if preparing { report?.preparationObserved = V02Fixture.prepared(members, invited: request.role == .ownerInvite) }
            else { report?.exactObservation = V02Fixture.exact(members, owner: request.role.isOwner, edited: edited) }
            try persist()
            if (!holdFullWindow && report?.exactObservation == true) || now() >= deadline { break }
            try await sampleSleep()
        } while now() <= deadline
        if preparing {
            let prepared = report?.preparationObserved == true
            report?.outcome = prepared
                ? "Owner preparation/invitation metadata observed. Acceptance, cross-account import and edits require subsequent independent stages."
                : "Inconclusive: owner preparation/invitation metadata not fully observed within the sampling window."
            return
        }
        let exact = report?.exactObservation == true
        report?.outcome = exact
            ? "Exact scope, fixture, share and permission snapshot observed. Compare independent device reports; this stage alone is not V02 completion."
            : "Inconclusive: expected values, scope, share membership or permissions not fully observed within the sampling window."
    }
}

/// CLI-only presentation; sensitive inputs are read from files, never UI output or launch arguments.
final class V02ViewController: UIViewController {
    private let request: V02Request
    private var launched = false
    private let output = UITextView()
    init(request: V02Request) { self.request = request; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(request:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "V02 — Cross-account smoke"
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view = output
        V02Session.shared.didChange = { [weak self] in self?.output.text = $0 }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !launched else { return }
        launched = true
        let container = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String ?? ""
        Task { await V02Session.shared.run(request, container: container) }
    }
}
