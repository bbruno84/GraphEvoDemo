import Foundation
import CloudKit
import UIKit

/// This capability boundary deliberately exposes no fixture, save, invitation, acceptance, or purge operation.
@MainActor
protocol V02LeaveRecoveryStoreAccess: AnyObject {
    var inventory: [String: String] { get }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws
    func snapshot(runID: UUID) async throws -> [V02Row]
    func invitationMetadata(_ invitation: V02Envelope, runID: UUID, priorCaseID: UUID, container: String) async throws -> V02LeaveMetadata
    func close() async throws
}

@MainActor
final class V02LeaveRecoverySession {
    static let shared = V02LeaveRecoverySession()
    private let root: URL
    private let originalRoot: URL
    private let lifecycleRoot: URL
    private let permitSimulator: Bool
    private let account: @MainActor (String) async throws -> CKRecord.ID
    private let makeStore: @MainActor (CKRecord.ID, T6Trace) -> V02LeaveRecoveryStoreAccess
    private let now: @MainActor () -> Date
    private let sleep: @MainActor () async throws -> Void
    private var started = false
    private(set) var report: V02LeaveRecoveryReport?
    private(set) var reportURL: URL?
    var didChange: ((String) -> Void)?

    init(root: URL? = nil, originalRoot: URL? = nil, lifecycleRoot: URL? = nil, permitSimulatorForTests: Bool = false,
         account: @escaping @MainActor (String) async throws -> CKRecord.ID = { identifier in
             let cloud = CKContainer(identifier: identifier)
             guard try await cloud.accountStatus() == .available else { throw V01Error.accountUnavailable }
             return try await cloud.userRecordID()
         }, makeStore: @escaping @MainActor (CKRecord.ID, T6Trace) -> V02LeaveRecoveryStoreAccess = { V02CloudStore(currentUser: $0, trace: $1) },
         now: @escaping @MainActor () -> Date = { Date() },
         sleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("V02LeaveRecoveryLaboratory")
        self.originalRoot = originalRoot ?? support.appendingPathComponent("V02Laboratory")
        self.lifecycleRoot = lifecycleRoot ?? support.appendingPathComponent("V02LifecycleLaboratory")
        permitSimulator = permitSimulatorForTests
        self.account = account; self.makeStore = makeStore; self.now = now; self.sleep = sleep
    }

    func run(_ request: V02LeaveRecoveryRequest, container: String) async {
        guard !started else { return }
        started = true
        let stageID = UUID()
        let url = root.appendingPathComponent("Reports/\(request.runID)-\(request.caseID)-\(request.role.rawValue)-\(stageID).json")
        reportURL = url
        var environment = Dictionary(uniqueKeysWithValues: ["LaboratoryDemoRevision", "LaboratoryGraphEvoRevision", "LaboratorySourceState", "LaboratoryToolchain"].map {
            ($0, Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "Unrecorded")
        })
        environment["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        environment["deviceClass"] = UIDevice.current.model
        report = V02LeaveRecoveryReport(role: request.role, runID: request.runID, caseID: request.caseID,
            priorCaseID: request.priorCaseID, stageID: stageID, processID: UUID(), started: Date(), windowSeconds: request.window, environment: environment)
        var store: V02LeaveRecoveryStoreAccess?
        var trace: T6Trace?
        var heartbeat: Task<Void, Never>?
        func persist() throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: url, options: .atomic)
            didChange?(String(decoding: data, as: UTF8.self))
        }
        do {
            try persist()
            guard request.caseID != request.priorCaseID, !GraphProvider.wasInitialized, !container.isEmpty else { throw V02Error.invalidEnvelope }
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
            let participant = request.role == .participant
            let side = participant ? "participant" : "owner"
            let user = try await account(container)
            let binding = try V02SensitiveFiles.read(originalRoot.appendingPathComponent("Sensitive/\(request.runID)/\(side)-binding.json"))
            try binding.validate(runID: request.runID, container: container, purpose: "account-binding")
            guard binding.account.recordID == user else { throw V02Error.invalidAccount }
            let priorStateURL = lifecycleRoot.appendingPathComponent("State/\(request.runID)-\(request.priorCaseID).json")
            let prior = try JSONDecoder().decode(V02LifecycleState.self, from: Data(contentsOf: priorStateURL))
            guard prior.runID == request.runID, prior.caseID == request.priorCaseID,
                  prior.progress == (participant ? .left : .invited),
                  participant ? prior.recoveredParticipant.count == 3 : prior.originalOwner.count == 5 else { throw V02Error.editNotReady }
            report?.priorStores = prior.stores
            let invitationName = participant ? "received-invitation.json" : "private-invitation.json"
            let envelope = try V02SensitiveFiles.read(lifecycleRoot.appendingPathComponent("Sensitive/\(request.runID)/\(request.priorCaseID)/\(invitationName)"))
            try envelope.validate(runID: request.runID, container: container, purpose: "lifecycle-invitation")
            guard envelope.caseID == request.priorCaseID, envelope.share != nil, envelope.shareURL != nil,
                  participant ? envelope.recipient?.recordID == user && envelope.account.recordID != user : envelope.account.recordID == user else { throw V02Error.invalidEnvelope }
            // Reserve this read-only stage before opening: a fresh probe path is never reused, even after failure.
            let reservation = root.appendingPathComponent("State/\(request.runID)-\(request.caseID)-\(request.role.rawValue).json")
            try FileManager.default.createDirectory(at: reservation.deletingLastPathComponent(), withIntermediateDirectories: true)
            let reservationData = try JSONEncoder().encode(["runID": request.runID.uuidString, "caseID": request.caseID.uuidString, "priorCaseID": request.priorCaseID.uuidString, "role": request.role.rawValue])
            try reservationData.write(to: reservation, options: .withoutOverwriting)
            report?.freshReplicaRequested = participant
            report?.probePathPermanentlyConsumed = participant
            let opened = makeStore(user, recorder); store = opened
            report?.phase = "Reading prior invitation metadata without acceptance; an error is retained independently from recovery"
            try persist()
            let beforeMetadata = try await opened.invitationMetadata(envelope, runID: request.runID, priorCaseID: request.priorCaseID, container: container)
            report?.metadataBefore = beforeMetadata
            let directory = participant
                ? root.appendingPathComponent("Stores/\(request.runID)/\(request.caseID)/participant-fresh")
                : originalRoot.appendingPathComponent("Stores/\(request.runID)/owner")
            report?.phase = participant ? "Opening new isolated private/shared stores; no seed, save, invitation or acceptance" : "Reopening original owner stores for public share snapshots; no owner-only timing requirement"
            try persist()
            try await opened.open(directory: directory, container: container, fresh: participant) { [weak self] event in
                guard let self, self.report?.finished == nil else { return }
                if self.report?.events.count ?? 0 < 128 { self.report?.events.append(event) }
                else { self.report?.droppedEvents += 1 }
            }
            let inventory = opened.inventory
            report?.stores = inventory
            guard inventory.count == 2 else { throw V02Error.missingStores }
            if participant {
                guard Set(inventory.values).isDisjoint(with: Set(prior.stores.values)) else { throw V02Error.existingStores }
            } else { guard inventory == prior.stores else { throw V02Error.missingStores } }
            let begin = now(), deadline = begin.addingTimeInterval(TimeInterval(request.window))
            report?.observationStarted = begin
            repeat {
                guard opened.inventory == inventory else { throw V02Error.missingStores }
                do {
                    let rows = try await opened.snapshot(runID: request.runID)
                    if report?.sampleCount == 0 { report?.openingSnapshot = rows }
                    report?.sampleCount += 1; report?.members = rows
                    if rows.isEmpty { report?.emptySampleCount += 1 }
                    if rows.contains(where: { $0.graph == "B" }) { report?.observedB = true }
                    if participant && rows.contains(where: { $0.scope == .privateStore }) { report?.observedPrivateCopy = true }
                    if participant && report?.firstRecoveryAt == nil && V02LeaveRecoveryFixture.exactA(rows, original: prior.recoveredParticipant) {
                        report?.firstRecoveryAt = now(); report?.firstRecoveredRows = rows
                    }
                    if !participant { report?.ownerDataMatches = V02LeaveRecoveryFixture.ownerData(rows, original: prior.originalOwner) }
                } catch {
                    let captured = V02PublicReadError.capture(error)
                    let combined = (report?.snapshotErrors ?? []) + captured
                    report?.snapshotErrors = Array(combined.prefix(64))
                }
                try persist()
                if now() >= deadline { break }
                try await sleep()
            } while true
            report?.observationFinished = now(); report?.fullWindowObserved = now() >= deadline
            report?.phase = "Reading the same prior URL again without acceptance; snapshots do not certify server completion"
            try persist()
            let afterMetadata = try await opened.invitationMetadata(envelope, runID: request.runID, priorCaseID: request.priorCaseID, container: container)
            report?.metadataAfter = afterMetadata
            if participant {
                let recovered = report?.firstRecoveryAt != nil
                report?.outcome = recovered
                    ? "Exact prior A3 recovered in new stores without another invitation or acceptance. Inspect metadata, final rows and unexpected scopes separately."
                    : "No exact A3 recovery observed in the bounded fresh-store window. This does not establish permanent access denial or server membership."
            } else {
                report?.outcome = "Owner data and public share participant role/permission/acceptance snapshots retained. Inspect ownerDataMatches and raw statuses; no owner-only timing guarantee is inferred."
            }
        } catch {
            report?.errors = V02PublicReadError.capture(error)
            report?.outcome = "Read-only stage failed; retain metadata, snapshots and codes. No invitation, acceptance, purge or replacement-path retry performed."
        }
        heartbeat?.cancel()
        do { try await store?.close(); report?.storesDetached = true }
        catch {
            let combined = (report?.errors ?? []) + V02PublicReadError.capture(error)
            report?.errors = Array(combined.prefix(64))
        }
        report?.finished = Date(); report?.phase = "Ended; retain final report and terminate process"
        trace?.record(.runFinished)
        report?.traceWriteFailures = trace?.counts.failures ?? 0; report?.traceDroppedEntries = trace?.counts.dropped ?? 0
        report?.finalReportRetained = true
        do { try persist() }
        catch { report?.finalReportRetained = false; didChange?("Final report retention failed.") }
    }
}

final class V02LeaveRecoveryViewController: UIViewController {
    private let request: V02LeaveRecoveryRequest
    private let output = UITextView()
    private var launched = false
    init(request: V02LeaveRecoveryRequest) { self.request = request; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(request:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "V02 — Read-only post-leave recovery"; output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view = output
        V02LeaveRecoverySession.shared.didChange = { [weak self] in self?.output.text = $0 }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); guard !launched else { return }; launched = true
        let container = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String ?? ""
        Task { await V02LeaveRecoverySession.shared.run(request, container: container) }
    }
}
