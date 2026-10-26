import Foundation
import UIKit
import CloudKit
import CryptoKit

@MainActor
protocol V02PermissionStoreAccess: AnyObject {
    var inventory: [String: String] { get }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws
    func snapshot(runID: UUID) async throws -> [V02Row]
    func changeParticipantPermission(runID: UUID, recipient: V02PrivateID, from: CKShare.ParticipantPermission,
                                     to: CKShare.ParticipantPermission, checkpoint: () throws -> Void) async throws
    func attemptReadOnlySave(runID: UUID) async throws -> V02ReadOnlyAttempt
    func close() async throws
}

@MainActor
final class V02PermissionSession {
    static let shared = V02PermissionSession()
    private let root: URL
    private let originalRoot: URL
    private let permitSimulator: Bool
    private let account: @MainActor (String) async throws -> CKRecord.ID
    private let makeStore: @MainActor (CKRecord.ID, T6Trace) -> V02PermissionStoreAccess
    private let now: @MainActor () -> Date
    private let sleep: @MainActor () async throws -> Void
    private var started = false
    private(set) var report: V02PermissionReport?
    private(set) var reportURL: URL?
    var didChange: ((String) -> Void)?

    init(root: URL? = nil, originalRoot: URL? = nil, permitSimulatorForTests: Bool = false,
         account: @escaping @MainActor (String) async throws -> CKRecord.ID = { identifier in
             let cloud = CKContainer(identifier: identifier)
             guard try await cloud.accountStatus() == .available else { throw V01Error.accountUnavailable }
             return try await cloud.userRecordID()
         }, makeStore: @escaping @MainActor (CKRecord.ID, T6Trace) -> V02PermissionStoreAccess = { V02CloudStore(currentUser: $0, trace: $1) },
         now: @escaping @MainActor () -> Date = { Date() },
         sleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("V02PermissionLaboratory")
        self.originalRoot = originalRoot ?? support.appendingPathComponent("V02Laboratory")
        permitSimulator = permitSimulatorForTests; self.account = account; self.makeStore = makeStore
        self.now = now; self.sleep = sleep
    }

    func run(_ request: V02PermissionRequest, container: String) async {
        guard !started else { return }; started = true
        let stage = UUID()
        let url = root.appendingPathComponent("Reports/\(request.runID)-\(request.probeID)-\(request.role.rawValue)-\(stage).json")
        reportURL = url
        var environment = Dictionary(uniqueKeysWithValues: ["LaboratoryDemoRevision", "LaboratoryGraphEvoRevision", "LaboratorySourceState", "LaboratoryToolchain"].map {
            ($0, Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "Unrecorded")
        })
        environment["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        environment["deviceClass"] = UIDevice.current.model
        environment["topology"] = request.role == .probe ? "New isolated private/shared probe stores; no invitation or acceptance" : "Existing V02 owner private/shared stores"
        report = V02PermissionReport(runID: request.runID, probeID: request.probeID, stageID: stage, processID: UUID(), role: request.role,
            started: Date(), windowSeconds: request.window, environment: environment)
        var store: V02PermissionStoreAccess?
        var trace: T6Trace?
        var heartbeat: Task<Void, Never>?
        let stateURL = root.appendingPathComponent("State/\(request.runID)-\(request.probeID).json")
        func persist() throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: url, options: .atomic)
            didChange?(String(decoding: data, as: UTF8.self))
        }
        func saveState(_ state: V02PermissionState) throws {
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
            var state: V02PermissionState?
            if request.role == .probe {
                // Reserve permanently before open; this namespace has no reopen or retry route.
                let consumed = root.appendingPathComponent("ConsumedProbes/\(request.runID)-\(request.probeID).json")
                guard !FileManager.default.fileExists(atPath: consumed.path) else { throw V02Error.existingStores }
                try FileManager.default.createDirectory(at: consumed.deletingLastPathComponent(), withIntermediateDirectories: true)
                let marker = ["runID": request.runID.uuidString, "probeID": request.probeID.uuidString, "policy": "Consumed permanently; never reopen this probe store"]
                try JSONEncoder().encode(marker).write(to: consumed, options: .atomic)
                report?.probePathPermanentlyConsumed = true
            } else if request.role != .ownerReadOnly {
                state = try JSONDecoder().decode(V02PermissionState.self, from: Data(contentsOf: stateURL))
                guard state?.runID == request.runID, state?.probeID == request.probeID else { throw V02Error.invalidEnvelope }
                if request.role == .ownerObserve { guard state?.progress == .readOnlyReady else { throw V02Error.editNotReady } }
                if request.role == .restore { guard state?.progress == .ownerUnchanged else { throw V02Error.editNotReady } }
            } else { guard !FileManager.default.fileExists(atPath: stateURL.path) else { throw V02Error.existingStores } }
            let opened = makeStore(user, recorder); store = opened
            let directory = request.role == .probe
                ? root.appendingPathComponent("Stores/\(request.runID)/\(request.probeID)/participant-probe")
                : originalRoot.appendingPathComponent("Stores/\(request.runID)/owner")
            report?.phase = request.role == .probe ? "Opening fresh isolated probe stores; no acceptance API" : "Reopening existing owner stores"
            try persist()
            try await opened.open(directory: directory, container: container, fresh: request.role == .probe) { [weak self] event in
                guard let self, self.report?.finished == nil else { return }
                if self.report?.events.count ?? 0 < 128 { self.report?.events.append(event) }
                else { self.report?.droppedEvents += 1 }
            }
            report?.stores = opened.inventory
            guard opened.inventory.count == 2 else { throw V02Error.missingStores }
            if let state { guard opened.inventory == state.ownerStores else { throw V02Error.missingStores } }
            report?.openingSnapshot = try await opened.snapshot(runID: request.runID)
            let expectedPermission: CKShare.ParticipantPermission = request.role == .ownerReadOnly ? .readWrite : .readOnly
            report?.phase = "Waiting for complete values, share identities and current permission; reads only"
            try persist()
            let baseline = try await ready(opened, request: request, permission: expectedPermission, reference: state?.originalOwner, persist: persist)
            report?.baseline = baseline
            guard V02PermissionFixture.exact(baseline, owner: request.role.isOwner, permission: expectedPermission) else { throw V02Error.invalidFixture }
            if request.role == .probe {
                report?.readOnlyImportObserved = true
                report?.phase = "Attempting exactly one real shared-store save regardless of canUpdateRecord"
                try persist()
                report?.attempt = try await opened.attemptReadOnlySave(runID: request.runID)
                try persist()
                try await observe(opened, request: request, reference: [], permission: .readOnly, persist: persist)
                let classification = report?.attempt?.classification ?? "Inconclusive: no retained save-attempt result."
                report?.outcome = classification
            } else if request.role == .ownerObserve {
                try await observe(opened, request: request, reference: state!.originalOwner, permission: .readOnly, persist: persist)
                if report?.ownerUnchangedForWindow == true {
                    state?.progress = .ownerUnchanged
                    try saveState(state!)
                    report?.outcome = "Owner original A/B and read-only permission unchanged for the bounded observation window. This is not a live-import or latency guarantee."
                } else { report?.outcome = "Inconclusive or unexpected owner state; inspect snapshots. Read-write restoration is blocked." }
            } else {
                let original: [V02Row]
                if request.role == .ownerReadOnly {
                    original = baseline
                    state = V02PermissionState(runID: request.runID, probeID: request.probeID, originalOwner: baseline, ownerStores: opened.inventory)
                    try saveState(state!) // Prevent replay after a potentially completed share mutation.
                } else {
                    original = state!.originalOwner
                    guard request.stoppedAndQuarantined, let filename = request.probeReport, V02Request.validFilename(filename) else { throw V02Error.unauthorizedInvitation }
                    let proofURL = root.appendingPathComponent("Inbox/" + filename)
                    let attributes = try proofURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) < 1_048_576 else { throw V02Error.invalidEnvelope }
                    let bytes = try Data(contentsOf: proofURL)
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    let proof = try decoder.decode(V02PermissionReport.self, from: bytes)
                    try V02ProbeRestoreGate.validate(proof, request: request, ownerBaseline: original)
                    report?.externalStopAndQuarantineAsserted = true
                    report?.participantReportSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    state?.progress = .restoring
                    try saveState(state!)
                }
                let invitation = try V02SensitiveFiles.read(originalRoot.appendingPathComponent("Sensitive/\(request.runID)/private-invitation.json"))
                try invitation.validate(runID: request.runID, container: container, purpose: "private-invitation")
                guard invitation.account.recordID == user, let recipient = invitation.recipient else { throw V02Error.invalidEnvelope }
                report?.phase = request.role == .ownerReadOnly ? "Persisting A participant read-only permission; no participant addition/removal" : "Restoring A read-write after supplied stop/quarantine evidence"
                try persist()
                let desired: CKShare.ParticipantPermission = request.role == .ownerReadOnly ? .readOnly : .readWrite
                try await opened.changeParticipantPermission(runID: request.runID, recipient: recipient, from: expectedPermission, to: desired) { try persist() }
                report?.permissionUpdatePersisted = true
                // A completed update does not make the local fetchShares cache a readiness barrier.
                let updated = try await ready(opened, request: request, permission: desired, reference: original, persist: persist)
                guard V02PermissionFixture.unchanged(updated, ownerBaseline: original, owner: true, permission: desired) else { throw V02Error.invalidShare }
                try await observe(opened, request: request, reference: original, permission: desired, persist: persist)
                if report?.ownerUnchangedForWindow == true {
                    state?.progress = request.role == .ownerReadOnly ? .readOnlyReady : .restored
                    try saveState(state!)
                    report?.outcome = request.role == .ownerReadOnly
                        ? "Read-only participant metadata persisted and owner fixture retained; fresh participant probe is a separate stage."
                        : "Read-write restored after operator stop/quarantine assertion and retained probe report; owner unchanged in bounded observations. No cloud-quiescence acknowledgement inferred."
                } else { report?.outcome = "Inconclusive: expected owner values/identities/permissions not continuously observed; no fallback or value restoration." }
            }
        } catch {
            report?.errors.append(v01ErrorCode(error))
            report?.outcome = "Stage failed; no replay, cleanup or silent restoration."
        }
        heartbeat?.cancel()
        do { try await store?.close(); report?.storesDetached = true }
        catch { report?.errors.append("Close: " + v01ErrorCode(error)) }
        report?.finished = Date(); report?.phase = "Ended; retain evidence, terminate process and never reopen consumed probe paths"
        trace?.record(.runFinished)
        report?.traceWriteFailures = trace?.counts.failures ?? 0
        report?.traceDroppedEntries = trace?.counts.dropped ?? 0
        let exportErrors = report?.events.filter { $0.kind == "export" && $0.finished != nil && !$0.succeeded }.map { $0.error ?? "Export failed without error code" } ?? []
        report?.exportErrors = exportErrors
        report?.finalReportRetained = true
        do { try persist() } catch {
            report?.finalReportRetained = false
            report?.outcome = "Inconclusive: final report retention failed; restore must not use a Running checkpoint."
            didChange?("Final report retention failed.")
        }
    }

    private func ready(_ store: V02PermissionStoreAccess, request: V02PermissionRequest, permission: CKShare.ParticipantPermission,
                       reference: [V02Row]?, persist: () throws -> Void) async throws -> [V02Row] {
        let deadline = now().addingTimeInterval(TimeInterval(request.window))
        var rows: [V02Row] = []
        repeat {
            rows = try await store.snapshot(runID: request.runID)
            report?.members = rows; try persist()
            let exact = reference.map { V02PermissionFixture.unchanged(rows, ownerBaseline: $0, owner: request.role.isOwner, permission: permission) }
                ?? V02PermissionFixture.exact(rows, owner: request.role.isOwner, permission: permission)
            if exact || now() >= deadline { break }
            try await sleep()
        } while now() <= deadline
        return rows
    }

    private func observe(_ store: V02PermissionStoreAccess, request: V02PermissionRequest, reference: [V02Row],
                         permission: CKShare.ParticipantPermission, persist: () throws -> Void) async throws {
        report?.phase = "Holding full observation window; no retries or value restoration"
        let deadline = now().addingTimeInterval(TimeInterval(request.window))
        var unchanged = true
        repeat {
            let rows = try await store.snapshot(runID: request.runID)
            report?.members = rows
            if request.role.isOwner {
                let matches = V02PermissionFixture.unchanged(rows, ownerBaseline: reference, owner: true, permission: permission)
                if !matches && report?.firstUnexpectedOwnerSnapshot.isEmpty == true { report?.firstUnexpectedOwnerSnapshot = rows }
                unchanged = unchanged && matches
            }
            report?.ownerUnchangedForWindow = request.role.isOwner && unchanged
            try persist()
            if now() >= deadline { break }
            try await sleep()
        } while now() <= deadline
    }
}

final class V02PermissionViewController: UIViewController {
    private let request: V02PermissionRequest
    private var launched = false
    private let output = UITextView()
    init(request: V02PermissionRequest) { self.request = request; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(request:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "V02 — Read-only probe"
        output.isEditable = false; output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view = output; V02PermissionSession.shared.didChange = { [weak self] in self?.output.text = $0 }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); guard !launched else { return }; launched = true
        let container = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String ?? ""
        Task { await V02PermissionSession.shared.run(request, container: container) }
    }
}
