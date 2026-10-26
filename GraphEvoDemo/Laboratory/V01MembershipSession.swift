import Foundation
import UIKit
import CloudKit

@MainActor
protocol V01MembershipStoreAccess: AnyObject {
    var inventory: [String: String] { get }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws
    func insertFixture(runID: UUID) async throws
    func createShare(graph: String, runID: UUID, checkpoint: () throws -> Void) async throws
    func addMembershipChild(runID: UUID) async throws
    func deleteMembershipChild(runID: UUID) async throws
    func snapshot(runID: UUID) async throws -> [V02Row]
    func close() async throws
}

@MainActor
final class V01MembershipSession {
    static let shared = V01MembershipSession()
    private let root: URL
    private let permitSimulator: Bool
    private let account: @MainActor (String) async throws -> CKRecord.ID
    private let makeStore: @MainActor (CKRecord.ID, T6Trace) -> V01MembershipStoreAccess
    private let now: @MainActor () -> Date
    private let sleep: @MainActor () async throws -> Void
    private var started = false
    private(set) var report: V01MembershipReport?
    private(set) var reportURL: URL?
    var didChange: ((String) -> Void)?

    init(root: URL? = nil, permitSimulatorForTests: Bool = false,
         account: @escaping @MainActor (String) async throws -> CKRecord.ID = { identifier in
             let cloud = CKContainer(identifier: identifier)
             guard try await cloud.accountStatus() == .available else { throw V01Error.accountUnavailable }
             return try await cloud.userRecordID()
         }, makeStore: @escaping @MainActor (CKRecord.ID, T6Trace) -> V01MembershipStoreAccess = {
             V02CloudStore(currentUser: $0, trace: $1, scopes: [.privateStore])
         }, now: @escaping @MainActor () -> Date = Date.init,
         sleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("V01MembershipLaboratory")
        permitSimulator = permitSimulatorForTests; self.account = account; self.makeStore = makeStore
        self.now = now; self.sleep = sleep
    }

    func run(_ request: V01MembershipRequest, container: String) async {
        guard !started else { return }
        started = true
        let stage = UUID()
        let basename = "\(request.runID)-\(request.role.rawValue)-\(request.phase.rawValue)-\(stage)"
        let reportURL = root.appendingPathComponent("Reports/" + basename + ".json")
        self.reportURL = reportURL
        var environment = Dictionary(uniqueKeysWithValues: ["LaboratoryDemoRevision", "LaboratoryGraphEvoRevision", "LaboratorySourceState", "LaboratoryToolchain"].map {
            ($0, Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "Unrecorded")
        })
        environment["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        environment["deviceClass"] = UIDevice.current.model
        environment["membershipMode"] = "Relationship plus save only; no explicit sharing of A-003"
        report = V01MembershipReport(runID: request.runID, stageID: stage, processID: UUID(), role: request.role,
            expectedPhase: request.phase, windowSeconds: request.window, started: Date(), environment: environment)
        let ledgerURL = root.appendingPathComponent("State/\(request.runID).json")
        var store: V01MembershipStoreAccess?
        var trace: T6Trace?
        var heartbeat: Task<Void, Never>?
        func persist() throws {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(report)
            try data.write(to: reportURL, options: .atomic)
            didChange?(String(decoding: data, as: UTF8.self))
        }
        func saveLedger(_ ledger: V01MembershipLedger) throws {
            try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
        }
        do {
            try persist()
            guard !GraphProvider.wasInitialized, !container.isEmpty else { throw V01Error.missingConfiguration }
            #if targetEnvironment(simulator)
            guard permitSimulator else { throw V01Error.missingConfiguration }
            #endif
            let recorder = try T6Trace(url: reportURL.deletingPathExtension().appendingPathExtension("trace.jsonl"))
            trace = recorder; recorder.record(.runStarted)
            heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                    recorder.record(.mainActorHeartbeat)
                    do { try persist() } catch { recorder.record(.checkpointFailed) }
                }
            }
            let user = try await account(container)
            let bindingURL = root.appendingPathComponent("Sensitive/\(request.runID)/owner-binding.json")
            var ledger: V01MembershipLedger
            if request.role == .prepare {
                guard !FileManager.default.fileExists(atPath: ledgerURL.path) else { throw V02Error.existingStores }
                try V02SensitiveFiles.write(V02Envelope(purpose: "membership-binding", runID: request.runID, containerIdentifier: container, account: V02PrivateID(user)), to: bindingURL)
                ledger = V01MembershipLedger(runID: request.runID)
                try saveLedger(ledger)
            } else {
                let binding = try V02SensitiveFiles.read(bindingURL)
                try binding.validate(runID: request.runID, container: container, purpose: "membership-binding")
                guard binding.account.recordID == user else { throw V02Error.invalidAccount }
                ledger = try JSONDecoder().decode(V01MembershipLedger.self, from: Data(contentsOf: ledgerURL))
                guard ledger.runID == request.runID else { throw V02Error.invalidEnvelope }
                let expected: V01MembershipPhase = request.role == .add ? .original : request.role == .delete ? .added : request.phase
                guard ledger.phaseIsReady(expected) else { throw V02Error.editNotReady }
            }
            report?.original = ledger.original
            let opened = makeStore(user, recorder)
            store = opened
            let fresh = request.role == .prepare || request.role == .reader
            let directory = request.role == .reader
                ? root.appendingPathComponent("Stores/\(request.runID)/readers/\(request.phase.rawValue)/\(stage)")
                : root.appendingPathComponent("Stores/\(request.runID)/writer")
            report?.phase = fresh ? "Opening fresh private SQLite" : "Reopening the original writer private SQLite"
            try persist()
            try await opened.open(directory: directory, container: container, fresh: fresh) { [weak self] event in
                guard let self, self.report?.finished == nil else { return }
                if self.report?.events.count ?? 0 < 128 { self.report?.events.append(event) }
                else { self.report?.droppedEvents += 1 }
            }
            report?.stores = opened.inventory
            guard opened.inventory.count == 1, opened.inventory["private"] != nil else { throw V02Error.missingStores }
            if !fresh { guard opened.inventory == ledger.writerStores else { throw V02Error.missingStores } }
            if request.role == .reader { guard opened.inventory != ledger.writerStores else { throw V02Error.existingStores } }
            let before = try await opened.snapshot(runID: request.runID)
            report?.baseline = before
            if request.role == .prepare {
                guard before.isEmpty else { throw V02Error.invalidFixture }
                ledger.writerStores = opened.inventory
                try saveLedger(ledger)
                report?.phase = "Saving original five-member fixture"
                try persist()
                try await opened.insertFixture(runID: request.runID)
                report?.fixtureSaved = true
                for graph in ["A", "B"] {
                    report?.phase = "Creating initial owner-only share " + graph
                    report?.initialShareCreationCalls += 1
                    try persist()
                    try await opened.createShare(graph: graph, runID: request.runID) { try persist() }
                }
            } else if request.role == .add || request.role == .delete {
                let prior: V01MembershipPhase = request.role == .add ? .original : .added
                guard V01MembershipFixture.preserved(before, original: ledger.original, added: ledger.added, phase: prior) else { throw V02Error.invalidFixture }
                ledger.progress = request.role == .add ? .adding : .deleting
                try saveLedger(ledger) // A crash after this reservation must not silently replay a mutation.
                report?.phase = request.role == .add ? "Adding A-003 and updating A-001 using relationship plus save only" : "Deleting A-003 using context.delete plus save only"
                try persist()
                if request.role == .add { try await opened.addMembershipChild(runID: request.runID) }
                else { try await opened.deleteMembershipChild(runID: request.runID) }
                report?.localMutationSaved = true
            }
            report?.phase = "Sampling entire run; no explicit existing-share call or fallback"
            let deadline = now().addingTimeInterval(TimeInterval(request.window))
            repeat {
                let rows = try await opened.snapshot(runID: request.runID)
                report?.members = rows
                report?.exactFixture = V01MembershipFixture.exact(rows, phase: request.phase)
                let preserved = request.role == .prepare ? report?.exactFixture == true
                    : V01MembershipFixture.preserved(rows, original: ledger.original, added: ledger.added, phase: request.phase)
                report?.preservedIdentities = preserved
                try persist()
                if (!request.role.mutates && preserved) || now() >= deadline { break }
                try await sleep()
            } while now() <= deadline
            if report?.preservedIdentities == true {
                let rows = report?.members ?? []
                switch request.role {
                case .prepare: ledger.original = rows; ledger.progress = .ready; report?.original = rows
                case .add: ledger.added = rows; ledger.progress = .added
                case .delete: ledger.deleted = rows; ledger.progress = .deleted
                case .reopen, .reader: break
                }
                if request.role.mutates { try saveLedger(ledger) }
                report?.outcome = "Expected fixture and pinned cloud identities observed. A fresh reader on the same iPad remains preliminary; compare stage reports independently."
            } else {
                report?.outcome = "Inconclusive: expected fixture, membership or pinned identities not fully observed. No explicit share fallback or replay performed."
            }
        } catch {
            report?.errors.append(v01ErrorCode(error))
            report?.outcome = "Stage failed; no mutation replay, explicit share fallback or replacement store."
        }
        heartbeat?.cancel()
        do { try await store?.close() } catch { report?.errors.append("Close: " + v01ErrorCode(error)) }
        report?.finished = Date()
        report?.phase = "Ended; terminate process before the next stage"
        trace?.record(.runFinished)
        report?.traceWriteFailures = trace?.counts.failures ?? 0
        report?.traceDroppedEntries = trace?.counts.dropped ?? 0
        report?.finalReportRetained = true
        do { try persist() } catch {
            report?.finalReportRetained = false
            report?.outcome = "Inconclusive: final report retention failed; an earlier Running checkpoint is not final evidence."
            didChange?("Final report retention failed; do not treat an earlier checkpoint as completed evidence.")
        }
    }
}

final class V01MembershipViewController: UIViewController {
    private let request: V01MembershipRequest
    private var launched = false
    private let output = UITextView()
    init(request: V01MembershipRequest) { self.request = request; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(request:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "V01 — Incremental membership"
        output.isEditable = false; output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view = output
        V01MembershipSession.shared.didChange = { [weak self] in self?.output.text = $0 }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !launched else { return }; launched = true
        let container = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String ?? ""
        Task { await V01MembershipSession.shared.run(request, container: container) }
    }
}
