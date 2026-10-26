import Foundation
import CloudKit
import UIKit

@MainActor
protocol V02RevocationStoreAccess: AnyObject {
    var inventory: [String: String] { get }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws
    func snapshot(runID: UUID) async throws -> [V02Row]
    func revokeParticipant(runID: UUID, recipient: V02PrivateID, checkpoint: () throws -> Void) async throws
    func captureWatchedObjects(runID: UUID) async throws -> [V02RevocationObject]
    func captureRevocationHistoryAnchor() async throws -> Bool
    func revocationHistory(since: Date, watchedURIs: [String]) async throws -> V02RevocationHistory
    func close() async throws
}

@MainActor
final class V02RevocationSession {
    static let shared = V02RevocationSession()
    private let root: URL
    private let originalRoot: URL
    private let permitSimulator: Bool
    private let account: @MainActor (String) async throws -> CKRecord.ID
    private let makeStore: @MainActor (CKRecord.ID, T6Trace) -> V02RevocationStoreAccess
    private let now: @MainActor () -> Date
    private let sleep: @MainActor () async throws -> Void
    private var started = false
    private(set) var report: V02RevocationReport?
    private(set) var reportURL: URL?
    var didChange: ((String) -> Void)?
    init(root: URL? = nil, originalRoot: URL? = nil, permitSimulatorForTests: Bool = false,
         account: @escaping @MainActor (String) async throws -> CKRecord.ID = { identifier in
             let cloud = CKContainer(identifier: identifier)
             guard try await cloud.accountStatus() == .available else { throw V01Error.accountUnavailable }
             return try await cloud.userRecordID()
         }, makeStore: @escaping @MainActor (CKRecord.ID, T6Trace) -> V02RevocationStoreAccess = { V02CloudStore(currentUser: $0, trace: $1) },
         now: @escaping @MainActor () -> Date = { Date() }, sleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("V02RevocationLaboratory")
        self.originalRoot = originalRoot ?? support.appendingPathComponent("V02Laboratory")
        permitSimulator = permitSimulatorForTests; self.account = account; self.makeStore = makeStore; self.now = now; self.sleep = sleep
    }

    func run(_ request: V02RevocationRequest, container: String) async {
        guard !started else { return }; started = true
        let stage = UUID()
        let url = root.appendingPathComponent("Reports/\(request.runID)-\(request.caseID)-\(request.role.rawValue)-\(stage).json")
        reportURL = url
        var environment = Dictionary(uniqueKeysWithValues: ["LaboratoryDemoRevision", "LaboratoryGraphEvoRevision", "LaboratorySourceState", "LaboratoryToolchain"].map {
            ($0, Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "Unrecorded")
        })
        environment["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        environment["deviceClass"] = UIDevice.current.model
        environment["topology"] = "Original V02 stores; participant container retained through baseline and removal window"
        report = V02RevocationReport(runID: request.runID, caseID: request.caseID, role: request.role, stageID: stage,
            processID: UUID(), started: Date(), windowSeconds: request.window, environment: environment)
        let stateURL = root.appendingPathComponent("State/\(request.runID)-\(request.caseID).json")
        var store: V02RevocationStoreAccess?
        var trace: T6Trace?
        var heartbeat: Task<Void, Never>?
        func persist() throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report); try data.write(to: url, options: .atomic)
            didChange?(String(decoding: data, as: UTF8.self))
        }
        func saveState(_ state: V02RevocationState) throws {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        }
        do {
            try persist()
            guard !GraphProvider.wasInitialized, !container.isEmpty else { throw V01Error.missingConfiguration }
            #if targetEnvironment(simulator)
            guard permitSimulator else { throw V01Error.missingConfiguration }
            #endif
            let recorder = try T6Trace(url: url.deletingPathExtension().appendingPathExtension("trace.jsonl"))
            trace = recorder; recorder.record(.runStarted)
            heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                    recorder.record(.mainActorHeartbeat)
                    do { try persist() } catch { recorder.record(.checkpointFailed) }
                }
            }
            let user = try await account(container)
            let side = request.role == .watch ? "participant" : "owner"
            let binding = try V02SensitiveFiles.read(originalRoot.appendingPathComponent("Sensitive/\(request.runID)/\(side)-binding.json"))
            try binding.validate(runID: request.runID, container: container, purpose: "account-binding")
            guard binding.account.recordID == user else { throw V02Error.invalidAccount }
            var state: V02RevocationState?
            if request.role == .verify {
                state = try JSONDecoder().decode(V02RevocationState.self, from: Data(contentsOf: stateURL))
                guard state?.runID == request.runID, state?.caseID == request.caseID, state?.revokeCompleted == true else { throw V02Error.editNotReady }
            } else {
                guard !FileManager.default.fileExists(atPath: stateURL.path) else { throw V02Error.existingStores }
                if request.role == .watch {
                    // Never silently restart a live-watch case after interruption.
                    try saveState(V02RevocationState(runID: request.runID, caseID: request.caseID, originalOwner: [], ownerStores: [:]))
                }
            }
            let opened = makeStore(user, recorder); store = opened
            report?.phase = "Reopening original \(side) private/shared stores; no fresh replica or probe store"
            try persist()
            try await opened.open(directory: originalRoot.appendingPathComponent("Stores/\(request.runID)/\(side)"), container: container, fresh: false) { [weak self] event in
                guard let self, self.report?.finished == nil else { return }
                if self.report?.events.count ?? 0 < 128 { self.report?.events.append(event) }
                else { self.report?.droppedEvents += 1 }
            }
            let inventory = opened.inventory
            report?.stores = inventory
            guard inventory.count == 2 else { throw V02Error.missingStores }
            if let state { guard inventory == state.ownerStores else { throw V02Error.missingStores } }
            report?.openingSnapshot = try await opened.snapshot(runID: request.runID)
            report?.phase = "Waiting for exact original edited fixture and complete share metadata; reads only"
            try persist()
            let deadline = now().addingTimeInterval(TimeInterval(request.window))
            var before = report?.openingSnapshot ?? []
            func ready(_ rows: [V02Row]) -> Bool {
                if request.role == .watch { return V02RevocationFixture.participantBefore(rows) }
                if request.role == .revoke { return V02RevocationFixture.ownerBefore(rows) }
                return state.map { V02RevocationFixture.ownerAfter(rows, original: $0.originalOwner) } ?? false
            }
            while !ready(before) && now() < deadline {
                try await sleep(); before = try await opened.snapshot(runID: request.runID)
                report?.members = before; try persist()
            }
            guard ready(before) else { throw V02Error.invalidFixture }
            report?.before = before
            if request.role == .watch {
                let objects = try await opened.captureWatchedObjects(runID: request.runID)
                guard objects.count == 3, Set(objects.compactMap(\.node)) == Set(["A-root", "A-001", "A-002"]) else { throw V02Error.invalidFixture }
                report?.knownObjects = objects
                let historyStart = now()
                do { report?.historyAnchorAvailable = try await opened.captureRevocationHistoryAnchor() }
                catch { report?.historyAnchorError = v01ErrorCode(error) }
                report?.readyAt = now()
                report?.readyForOwnerAction = true
                report?.phase = "READY: owner may revoke this case now; same container remains open"
                try persist()
                let watchDeadline = now().addingTimeInterval(TimeInterval(request.window))
                repeat {
                    do {
                        let rows = try await opened.snapshot(runID: request.runID)
                        report?.members = rows
                        let sameStores = opened.inventory == inventory
                        guard sameStores else { throw V02Error.missingStores }
                        if V02RevocationFixture.removal(before: before, after: rows, sameStores: sameStores) {
                            report?.removalObserved = true
                            if report?.firstAbsenceAt == nil { report?.firstAbsenceAt = now() }
                        }
                        appendSample(rows)
                    } catch {
                        if report?.sampleErrors.count ?? 0 < 16 { report?.sampleErrors.append(v01ErrorCode(error)) }
                    }
                    try persist()
                    if now() >= watchDeadline { break }
                    try await sleep()
                } while now() <= watchDeadline
                do { report?.history = try await opened.revocationHistory(since: historyStart, watchedURIs: objects.map(\.objectURI)) }
                catch {
                    report?.history = V02RevocationHistory(available: false, transactions: 0, truncated: false,
                        watchedInserts: 0, watchedUpdates: 0, watchedDeletes: 0, watchedDeletedURIs: [], error: v01ErrorCode(error))
                }
                let observed = report?.removalObserved == true && report?.members.isEmpty == true && opened.inventory == inventory
                report?.outcome = observed
                    ? "Observed complete A then its absence in the same open original stores. Correlate with owner revocation; history is observational, not a causal barrier."
                    : "Inconclusive: complete-before to absent-after transition not retained through the same-container window. Initial/fresh absence alone is not revocation evidence."
            } else {
                let original: [V02Row]
                if request.role == .revoke {
                    original = before
                    state = V02RevocationState(runID: request.runID, caseID: request.caseID, originalOwner: before, ownerStores: inventory)
                    try saveState(state!) // Reserve before mutation; no removeParticipant replay after interruption.
                    let invitation = try V02SensitiveFiles.read(originalRoot.appendingPathComponent("Sensitive/\(request.runID)/private-invitation.json"))
                    try invitation.validate(runID: request.runID, container: container, purpose: "private-invitation")
                    guard invitation.account.recordID == user, let recipient = invitation.recipient else { throw V02Error.invalidEnvelope }
                    report?.phase = "Removing exactly the authorized XR participant from A and persisting share; no purge"
                    try persist()
                    try await opened.revokeParticipant(runID: request.runID, recipient: recipient) { try persist() }
                    report?.revokeAPIReturned = true
                } else { original = state!.originalOwner }
                let verifyDeadline = now().addingTimeInterval(TimeInterval(request.window))
                var rows: [V02Row] = []
                repeat {
                    rows = try await opened.snapshot(runID: request.runID)
                    report?.members = rows; try persist()
                    if V02RevocationFixture.ownerAfter(rows, original: original) || now() >= verifyDeadline { break }
                    try await sleep()
                } while now() <= verifyDeadline
                guard V02RevocationFixture.ownerAfter(rows, original: original) else { throw V02Error.invalidShare }
                report?.phase = "Observing owner A/B retained with A owner-only; no owner object deletion"
                let holdDeadline = now().addingTimeInterval(TimeInterval(request.window))
                var preserved = true
                repeat {
                    rows = try await opened.snapshot(runID: request.runID)
                    report?.members = rows
                    let matches = V02RevocationFixture.ownerAfter(rows, original: original) && opened.inventory == inventory
                    if !matches && report?.firstUnexpectedOwnerSnapshot.isEmpty == true { report?.firstUnexpectedOwnerSnapshot = rows }
                    preserved = preserved && matches
                    report?.ownerPreserved = preserved
                    appendSample(rows); try persist()
                    if now() >= holdDeadline { break }
                    try await sleep()
                } while now() <= holdDeadline
                if preserved {
                    state?.revokeCompleted = true; try saveState(state!)
                    report?.outcome = "Owner A/B retained with original values/record/share identities and A owner-only. Participant live removal requires the independent watch report."
                } else { report?.outcome = "Unexpected owner state; no silent correction, purge or replay." }
            }
        } catch {
            report?.errors.append(v01ErrorCode(error)); report?.outcome = "Stage failed; no purge, reinvitation, fresh replacement or mutation replay."
        }
        heartbeat?.cancel()
        do { try await store?.close(); report?.storesDetached = true } catch { report?.errors.append("Close: " + v01ErrorCode(error)) }
        report?.finished = Date(); report?.phase = "Ended; retain evidence and terminate process"
        trace?.record(.runFinished)
        report?.traceWriteFailures = trace?.counts.failures ?? 0; report?.traceDroppedEntries = trace?.counts.dropped ?? 0
        report?.finalReportRetained = true
        do { try persist() } catch {
            report?.finalReportRetained = false; report?.outcome = "Inconclusive: final report retention failed."
            didChange?("Final report retention failed; an earlier checkpoint is not final evidence.")
        }
    }

    private func appendSample(_ rows: [V02Row]) {
        if report?.samples.count ?? 0 < 64 { report?.samples.append(V02RevocationSample(timestamp: now(), members: rows)) }
        else { report?.droppedSamples += 1 }
    }
}

final class V02RevocationViewController: UIViewController {
    private let request: V02RevocationRequest
    private var launched = false
    private let output = UITextView()
    init(request: V02RevocationRequest) { self.request = request; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(request:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "V02 — Live revocation"
        output.isEditable = false; output.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view = output
        V02RevocationSession.shared.didChange = { [weak self] in self?.output.text = $0 }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); guard !launched else { return }; launched = true
        let container = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String ?? ""
        Task { await V02RevocationSession.shared.run(request, container: container) }
    }
}
