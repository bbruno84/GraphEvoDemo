import Foundation
import CloudKit
import UIKit

@MainActor
protocol V02LifecycleStoreAccess: AnyObject {
    var inventory: [String: String] { get }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws
    func snapshot(runID: UUID) async throws -> [V02Row]
    func reinviteParticipant(runID: UUID, caseID: UUID, recipient: V02PrivateID, container: String, checkpoint: () throws -> Void) async throws -> V02Envelope
    func reacceptInvitation(_ invitation: V02Envelope, runID: UUID, caseID: UUID, container: String, checkpoint: () throws -> Void) async throws -> V02ReacceptResult
    func leaveSharedA(_ invitation: V02Envelope, runID: UUID, caseID: UUID, container: String, checkpoint: () throws -> Void) async throws -> V02RecordKey?
    func close() async throws
}

@MainActor
final class V02LifecycleSession {
    static let shared = V02LifecycleSession()
    private let root: URL
    private let originalRoot: URL
    private let permitSimulator: Bool
    private let account: @MainActor (String) async throws -> CKRecord.ID
    private let makeStore: @MainActor (CKRecord.ID, T6Trace) -> V02LifecycleStoreAccess
    private let now: @MainActor () -> Date
    private let sleep: @MainActor () async throws -> Void
    private var started = false
    private(set) var report: V02LifecycleReport?
    private(set) var reportURL: URL?
    var didChange: ((String) -> Void)?
    init(root: URL? = nil, originalRoot: URL? = nil, permitSimulatorForTests: Bool = false,
         account: @escaping @MainActor (String) async throws -> CKRecord.ID = { identifier in
             let cloud = CKContainer(identifier: identifier)
             guard try await cloud.accountStatus() == .available else { throw V01Error.accountUnavailable }
             return try await cloud.userRecordID()
         }, makeStore: @escaping @MainActor (CKRecord.ID, T6Trace) -> V02LifecycleStoreAccess = { V02CloudStore(currentUser: $0, trace: $1) },
         now: @escaping @MainActor () -> Date = { Date() }, sleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("V02LifecycleLaboratory")
        self.originalRoot = originalRoot ?? support.appendingPathComponent("V02Laboratory")
        permitSimulator = permitSimulatorForTests; self.account = account; self.makeStore = makeStore; self.now = now; self.sleep = sleep
    }

    func run(_ request: V02LifecycleRequest, container: String) async {
        guard !started else { return }; started = true
        let stage = UUID()
        let url = root.appendingPathComponent("Reports/\(request.runID)-\(request.caseID)-\(request.role.rawValue)-\(stage).json")
        reportURL = url
        var environment = Dictionary(uniqueKeysWithValues: ["LaboratoryDemoRevision", "LaboratoryGraphEvoRevision", "LaboratorySourceState", "LaboratoryToolchain"].map {
            ($0, Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "Unrecorded")
        })
        environment["os"] = ProcessInfo.processInfo.operatingSystemVersionString; environment["deviceClass"] = UIDevice.current.model
        report = V02LifecycleReport(runID: request.runID, caseID: request.caseID, role: request.role, stageID: stage, processID: UUID(),
            started: Date(), windowSeconds: request.window, environment: environment)
        let stateURL = root.appendingPathComponent("State/\(request.runID)-\(request.caseID).json")
        let sensitive = root.appendingPathComponent("Sensitive/\(request.runID)/\(request.caseID)")
        var store: V02LifecycleStoreAccess?
        var trace: T6Trace?
        var heartbeat: Task<Void, Never>?
        func persist() throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report); try data.write(to: url, options: .atomic)
            didChange?(String(decoding: data, as: UTF8.self))
        }
        func saveState(_ state: V02LifecycleState) throws {
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
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
            let user = try await account(container)
            let side = request.role.isOwner ? "owner" : "participant"
            let binding = try V02SensitiveFiles.read(originalRoot.appendingPathComponent("Sensitive/\(request.runID)/\(side)-binding.json"))
            try binding.validate(runID: request.runID, container: container, purpose: "account-binding")
            guard binding.account.recordID == user else { throw V02Error.invalidAccount }
            var state: V02LifecycleState?
            if request.role == .leave || request.role == .verify {
                state = try JSONDecoder().decode(V02LifecycleState.self, from: Data(contentsOf: stateURL))
                guard state?.runID == request.runID, state?.caseID == request.caseID,
                      state?.progress == (request.role == .leave ? .recovered : .invited) else { throw V02Error.editNotReady }
            } else { guard !FileManager.default.fileExists(atPath: stateURL.path) else { throw V02Error.existingStores } }
            let opened = makeStore(user, recorder); store = opened
            report?.phase = "Opening original \(side) private/shared stores; no new replica or consumed probe"
            try persist()
            try await opened.open(directory: originalRoot.appendingPathComponent("Stores/\(request.runID)/\(side)"), container: container, fresh: false) { [weak self] event in
                guard let self, self.report?.finished == nil else { return }
                if self.report?.events.count ?? 0 < 128 { self.report?.events.append(event) }
                else { self.report?.droppedEvents += 1 }
            }
            let inventory = opened.inventory
            report?.stores = inventory
            guard inventory.count == 2 else { throw V02Error.missingStores }
            if let state { guard state.stores == inventory else { throw V02Error.missingStores } }
            let initial = try await opened.snapshot(runID: request.runID)
            report?.openingSnapshot = initial
            if request.role == .reinvite || request.role == .verify {
                let original = state?.originalOwner
                report?.phase = "Waiting for intact owner-only A/B before reinvitation or post-leave verification"
                let before = try await readUntil(opened, request: request, persist: persist) { V02LifecycleFixture.owner($0, invited: false, original: original) }
                report?.before = before
                guard V02LifecycleFixture.owner(before, invited: false, original: original) else { throw V02Error.invalidFixture }
                if request.role == .reinvite {
                    state = V02LifecycleState(runID: request.runID, caseID: request.caseID, progress: .inviting, stores: inventory, originalOwner: before)
                    try saveState(state!)
                    let old = try V02SensitiveFiles.read(originalRoot.appendingPathComponent("Sensitive/\(request.runID)/private-invitation.json"))
                    try old.validate(runID: request.runID, container: container, purpose: "private-invitation")
                    guard old.account.recordID == user, let recipient = old.recipient else { throw V02Error.invalidEnvelope }
                    report?.phase = "Reinviting only the original authorized participant to existing A as private read-write"
                    try persist()
                    let envelope = try await opened.reinviteParticipant(runID: request.runID, caseID: request.caseID, recipient: recipient, container: container) { try persist() }
                    report?.invitationPersisted = true
                    let output = sensitive.appendingPathComponent("private-invitation.json")
                    try V02SensitiveFiles.write(envelope, to: output)
                    report?.sensitiveArtifact = output.lastPathComponent
                    let rows = try await readUntil(opened, request: request, persist: persist) { V02LifecycleFixture.owner($0, invited: true, original: before) }
                    guard V02LifecycleFixture.owner(rows, invited: true, original: before) else { throw V02Error.invalidShare }
                    state?.progress = .invited; try saveState(state!)
                    try await holdOwner(opened, request: request, original: before, invited: true, persist: persist)
                    report?.outcome = "Private reinvitation persisted for the same A/share and account; participant metadata/acceptance and recovery require their own report."
                } else {
                    try await holdOwner(opened, request: request, original: state!.originalOwner, invited: false, persist: persist)
                    let preserved = report?.ownerPreserved == true
                    report?.outcome = preserved ? "Owner A/B and original identities retained, A owner-only after participant leave. Compare participant before/after evidence." : "Unexpected owner state; no correction performed."
                }
            } else {
                let envelope: V02Envelope
                if request.role == .reaccept {
                    guard let name = request.input, V02Request.validFilename(name) else { throw V02Error.invalidEnvelope }
                    envelope = try V02SensitiveFiles.read(root.appendingPathComponent("Inbox/" + name))
                } else { envelope = try V02SensitiveFiles.read(sensitive.appendingPathComponent("received-invitation.json")) }
                try envelope.validate(runID: request.runID, container: container, purpose: "lifecycle-invitation")
                guard envelope.caseID == request.caseID, envelope.recipient?.recordID == user, envelope.account.recordID != user,
                      let share = envelope.share else { throw V02Error.invalidEnvelope }
                let expectedShare = V02RecordKey.make(share.recordID, currentUser: envelope.account.recordID, runID: request.runID)
                if request.role == .reaccept {
                    // An already-active server membership may import before this stage opens.
                    // Retain that observation instead of inventing a second acceptance or a fallback.
                    guard initial.isEmpty || V02Fixture.exact(initial, owner: false, edited: true, requireShares: false) else { throw V02Error.invalidFixture }
                    report?.before = initial; report?.initiallyAbsent = initial.isEmpty
                    state = V02LifecycleState(runID: request.runID, caseID: request.caseID, progress: .accepting, stores: inventory, originalOwner: [])
                    try saveState(state!)
                    try V02SensitiveFiles.write(envelope, to: sensitive.appendingPathComponent("received-invitation.json"))
                    report?.phase = "Validating case-scoped metadata; accept only pending membership, record accepted membership without another call"
                    try persist()
                    let acceptance = try await opened.reacceptInvitation(envelope, runID: request.runID, caseID: request.caseID, container: container) { try persist() }
                    report?.reaccept = acceptance
                    let rows = try await readUntil(opened, request: request, persist: persist) { V02LifecycleFixture.participant($0, expectedShare: expectedShare) }
                    guard V02LifecycleFixture.participant(rows, expectedShare: expectedShare) else { throw V02Error.invalidFixture }
                    report?.exactRecovery = true
                    state?.recoveredParticipant = rows; state?.progress = .recovered; try saveState(state!)
                    let active = report?.reaccept?.alreadyAccepted == true
                    report?.outcome = active ? "Metadata already accepted; no acceptance API replay. Exact A recovery observed on original stores; inspect initial absence separately." : "Pending invitation accepted and exact original A identities/values recovered; owner-only B absent."
                } else {
                    let rows = try await readUntil(opened, request: request, persist: persist) {
                        V02LifecycleFixture.permitsLeave($0, scope: .sharedStore, role: .privateUser, expectedShare: expectedShare)
                    }
                    guard V02LifecycleFixture.permitsLeave(rows, scope: .sharedStore, role: .privateUser, expectedShare: expectedShare),
                          rows.allSatisfy({ row in state?.recoveredParticipant.first(where: { $0.node == row.node })?.record == row.record }) else { throw V02Error.invalidFixture }
                    report?.before = rows
                    state?.progress = .leaving; try saveState(state!)
                    report?.phase = "Leaving only A through Core Data purge in the explicit shared store; private owner scope forbidden"
                    report?.leaveRequested = true; report?.purgeScope = V02Scope.sharedStore.rawValue
                    try persist()
                    let purgedZone = try await opened.leaveSharedA(envelope, runID: request.runID, caseID: request.caseID, container: container) { try persist() }
                    report?.returnedPurgeZone = purgedZone
                    report?.leaveAPIReturned = true
                    let deadline = now().addingTimeInterval(TimeInterval(request.window))
                    repeat {
                        let after = try await opened.snapshot(runID: request.runID); report?.members = after
                        guard opened.inventory == inventory else { throw V02Error.missingStores }
                        if after.isEmpty { report?.absenceAfterKnownFixture = true }
                        try persist()
                        if now() >= deadline { break }; try await sleep()
                    } while now() <= deadline
                    if report?.absenceAfterKnownFixture == true && report?.members.isEmpty == true {
                        state?.progress = .left; try saveState(state!)
                        report?.outcome = "Shared A absent after the complete pre-leave fixture and shared-store API completion. Owner A/B retention is a separate verification."
                    } else { report?.outcome = "Inconclusive: participant absence not fully observed; no repeated purge or owner deletion." }
                }
            }
        } catch { report?.errors.append(v01ErrorCode(error)); report?.outcome = "Stage failed; no fallback invitation, acceptance/purge replay, replacement store or owner deletion." }
        heartbeat?.cancel()
        do { try await store?.close(); report?.storesDetached = true } catch { report?.errors.append("Close: " + v01ErrorCode(error)) }
        report?.finished = Date(); report?.phase = "Ended; retain final report and terminate process"
        trace?.record(.runFinished); report?.traceWriteFailures = trace?.counts.failures ?? 0; report?.traceDroppedEntries = trace?.counts.dropped ?? 0
        report?.finalReportRetained = true
        do { try persist() } catch { report?.finalReportRetained = false; report?.outcome = "Inconclusive: final report retention failed."; didChange?("Final report retention failed.") }
    }

    private func readUntil(_ store: V02LifecycleStoreAccess, request: V02LifecycleRequest, persist: () throws -> Void,
                           matches: ([V02Row]) -> Bool) async throws -> [V02Row] {
        let deadline = now().addingTimeInterval(TimeInterval(request.window)); var rows: [V02Row] = []
        repeat {
            rows = try await store.snapshot(runID: request.runID); report?.members = rows; try persist()
            if matches(rows) || now() >= deadline { break }; try await sleep()
        } while now() <= deadline
        return rows
    }
    private func holdOwner(_ store: V02LifecycleStoreAccess, request: V02LifecycleRequest, original: [V02Row], invited: Bool, persist: () throws -> Void) async throws {
        let deadline = now().addingTimeInterval(TimeInterval(request.window)); var preserved = true
        repeat {
            let rows = try await store.snapshot(runID: request.runID); report?.members = rows
            guard store.inventory == report?.stores else { throw V02Error.missingStores }
            preserved = preserved && V02LifecycleFixture.owner(rows, invited: invited, original: original)
            report?.ownerPreserved = preserved; try persist()
            if now() >= deadline { break }; try await sleep()
        } while now() <= deadline
    }
}

final class V02LifecycleViewController: UIViewController {
    private let request: V02LifecycleRequest
    private let output = UITextView()
    private var launched = false
    init(request: V02LifecycleRequest) { self.request = request; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(request:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "V02 — Reinvite and leave"; output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view = output
        V02LifecycleSession.shared.didChange = { [weak self] in self?.output.text = $0 }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); guard !launched else { return }; launched = true
        let container = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String ?? ""
        Task { await V02LifecycleSession.shared.run(request, container: container) }
    }
}
