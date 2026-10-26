import Foundation
import CloudKit
import UIKit

@MainActor
protocol V02MutationStoreAccess: AnyObject {
    var inventory: [String: String] { get }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws
    func snapshot(runID: UUID) async throws -> [V02Row]
    func mutate(_ role: V02MutationRole, runID: UUID) async throws
    func close() async throws
}

@MainActor
final class V02MutationSession {
    static let shared = V02MutationSession()
    private let root: URL
    private let originalRoot: URL
    private let permitSimulator: Bool
    private let account: @MainActor (String) async throws -> CKRecord.ID
    private let makeStore: @MainActor (CKRecord.ID, T6Trace) -> V02MutationStoreAccess
    private let now: @MainActor () -> Date
    private let sleep: @MainActor () async throws -> Void
    private var started = false
    private(set) var report: V02MutationReport?
    private(set) var reportURL: URL?
    var didChange: ((String) -> Void)?

    init(root: URL? = nil, originalRoot: URL? = nil, permitSimulatorForTests: Bool = false,
         account: @escaping @MainActor (String) async throws -> CKRecord.ID = { identifier in
             let cloud = CKContainer(identifier: identifier)
             guard try await cloud.accountStatus() == .available else { throw V01Error.accountUnavailable }
             return try await cloud.userRecordID()
         }, makeStore: @escaping @MainActor (CKRecord.ID, T6Trace) -> V02MutationStoreAccess = { V02CloudStore(currentUser: $0, trace: $1) },
         now: @escaping @MainActor () -> Date = { Date() },
         sleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("V02MutationLaboratory")
        self.originalRoot = originalRoot ?? support.appendingPathComponent("V02Laboratory")
        self.permitSimulator = permitSimulatorForTests
        self.account = account; self.makeStore = makeStore; self.now = now; self.sleep = sleep
    }

    func run(_ request: V02MutationRequest, container: String) async {
        guard !started else { return }
        started = true
        let stageID = UUID()
        let side = request.role.isOwner ? "owner" : "participant"
        let url = root.appendingPathComponent("Reports/\(request.runID)-\(request.caseID)-\(request.role.rawValue)-\(stageID).json")
        reportURL = url
        var environment = Dictionary(uniqueKeysWithValues: ["LaboratoryDemoRevision", "LaboratoryGraphEvoRevision", "LaboratorySourceState", "LaboratoryToolchain"].map {
            ($0, Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "Unrecorded")
        })
        environment["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        environment["deviceClass"] = UIDevice.current.model
        report = V02MutationReport(role: request.role, runID: request.runID, caseID: request.caseID,
                                   stageID: stageID, started: Date(), windowSeconds: request.window, environment: environment)
        report?.priorCaseID = request.priorCaseID
        let stateURL = root.appendingPathComponent("State/\(request.runID)-\(request.caseID)-\(side).json")
        var store: V02MutationStoreAccess?
        var trace: T6Trace?
        func persist() throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report); try data.write(to: url, options: .atomic)
            didChange?(String(decoding: data, as: UTF8.self))
        }
        func saveState(_ state: V02MutationState) throws {
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
            let user = try await account(container)
            let binding = try V02SensitiveFiles.read(originalRoot.appendingPathComponent("Sensitive/\(request.runID)/\(side)-binding.json"))
            try binding.validate(runID: request.runID, container: container, purpose: "account-binding")
            guard binding.account.recordID == user else { throw V02Error.invalidAccount }
            var state: V02MutationState?
            if FileManager.default.fileExists(atPath: stateURL.path) {
                state = try JSONDecoder().decode(V02MutationState.self, from: Data(contentsOf: stateURL))
                guard state?.runID == request.runID, state?.caseID == request.caseID,
                      state?.owner == request.role.isOwner, state?.phase == request.role.before,
                      state?.reservedRole == nil else { throw V02Error.editNotReady }
            } else if let priorCaseID = request.priorCaseID {
                let priorURL = root.appendingPathComponent("State/\(request.runID)-\(priorCaseID)-\(side).json")
                let prior = try JSONDecoder().decode(V02MutationState.self, from: Data(contentsOf: priorURL))
                guard prior.runID == request.runID, prior.caseID == priorCaseID,
                      prior.owner == request.role.isOwner else { throw V02Error.editNotReady }
                if request.role == .participantConfirmOwnerAdd {
                    guard prior.phase == .original,
                          prior.reservedRole == .participantSeeOwnerAdd else { throw V02Error.editNotReady }
                } else {
                    guard prior.phase == request.role.before, prior.reservedRole == nil else { throw V02Error.editNotReady }
                }
                state = V02MutationState(runID: request.runID, caseID: request.caseID, priorCaseID: priorCaseID,
                                         owner: prior.owner, stores: prior.stores, original: prior.original,
                                         phase: request.role.before, reservedRole: nil,
                                         ownerAddedRecord: prior.ownerAddedRecord,
                                         participantAddedRecord: prior.participantAddedRecord)
            } else { guard request.role.before == .original else { throw V02Error.editNotReady } }
            let opened = makeStore(user, recorder); store = opened
            report?.phase = "Opening original \(side) private/shared stores"
            try persist()
            try await opened.open(directory: originalRoot.appendingPathComponent("Stores/\(request.runID)/\(side)"),
                                  container: container, fresh: false) { [weak self] event in
                guard let self, self.report?.finished == nil else { return }
                if self.report?.events.count ?? 0 < 128 { self.report?.events.append(event) }
                else { self.report?.droppedEvents += 1 }
            }
            let inventory = opened.inventory
            report?.stores = inventory
            guard inventory.count == 2 else { throw V02Error.missingStores }
            if let state { guard state.stores == inventory else { throw V02Error.missingStores } }
            let readinessDeadline = now().addingTimeInterval(TimeInterval(request.window))
            report?.phase = "Waiting for complete previous-phase data and public share metadata"
            try persist()
            var before: [V02Row] = []
            repeat {
                before = try await opened.snapshot(runID: request.runID)
                report?.before = before
                try persist()
                let match = V02MutationFixture.exact(before, phase: request.role.before, owner: request.role.isOwner) &&
                    (state == nil || V02MutationFixture.preserves(before, original: state!.original,
                        phase: request.role.before, owner: request.role.isOwner,
                        addedRecord: request.role.before == .ownerAdded ? state!.ownerAddedRecord : state!.participantAddedRecord))
                if match { break }
                guard now() < readinessDeadline else { throw V02Error.invalidFixture }
                try await sleep()
            } while true
            if state == nil {
                state = V02MutationState(runID: request.runID, caseID: request.caseID,
                                         owner: request.role.isOwner, stores: inventory, original: before)
            }
            state!.reservedRole = request.role
            try saveState(state!)
            let prior = state!.original
            let pinnedRecord = request.role.after == .ownerAdded ? state!.ownerAddedRecord : state!.participantAddedRecord
            if request.role.writes {
                report?.phase = request.role == .participantExplicitAdd
                    ? "Assigning one new object to the existing share using the public container API"
                    : "Applying exactly one supported Core Data mutation; no share API call"
                try persist()
                try await opened.mutate(request.role, runID: request.runID)
                report?.mutationSaved = true
            } else {
                report?.readyForWriter = request.role.before != request.role.after
                report?.phase = request.role == .participantConfirmOwnerAdd
                    ? "Read-only follow-up: checking imported A in the original participant stores"
                    : "READY: observe remote change in the already-open container"
                try persist()
            }
            let observationDeadline = now().addingTimeInterval(TimeInterval(request.window))
            repeat {
                guard opened.inventory == inventory else { throw V02Error.missingStores }
                let rows = try await opened.snapshot(runID: request.runID)
                report?.members = rows; report?.sampleCount += 1
                let exact = V02MutationFixture.preserves(rows, original: prior, phase: request.role.after,
                    owner: request.role.isOwner, addedRecord: pinnedRecord)
                if exact {
                    report?.targetObserved = true
                    if report?.firstTargetAt == nil { report?.firstTargetAt = now() }
                }
                try persist()
                if now() >= observationDeadline { break }
                try await sleep()
            } while true
            report?.fullWindowObserved = now() >= observationDeadline
            guard report?.targetObserved == true,
                  V02MutationFixture.preserves(report!.members, original: prior, phase: request.role.after,
                    owner: request.role.isOwner, addedRecord: pinnedRecord) else { throw V02Error.invalidFixture }
            if request.role.after == .ownerAdded {
                state!.ownerAddedRecord = report?.members.first(where: { $0.node == "A-003" })?.record
            }
            if request.role.after == .participantAdded || request.role.after == .participantExplicitAdded {
                state!.participantAddedRecord = report?.members.first(where: { $0.node == "A-004" })?.record
            }
            state!.phase = request.role.after; state!.reservedRole = nil
            try saveState(state!)
            report?.outcome = "Exact target graph and preserved identities observed through the full window; compare the other device's report separately."
        } catch {
            report?.errors.append(v01ErrorCode(error))
            report?.outcome = "Stage failed or remained inconclusive; no write, invitation or share-operation replay."
        }
        do { try await store?.close(); report?.storesDetached = true }
        catch { report?.errors.append("Close: " + v01ErrorCode(error)) }
        report?.finished = Date(); report?.phase = "Ended; retain final report and terminate process"
        trace?.record(.runFinished)
        report?.finalReportRetained = true
        do { try persist() }
        catch { report?.finalReportRetained = false; didChange?("Final report retention failed.") }
    }
}

final class V02MutationViewController: UIViewController {
    private let request: V02MutationRequest
    private let output = UITextView()
    private var launched = false
    init(request: V02MutationRequest) { self.request = request; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(request:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "V02 — Shared graph mutations"
        output.isEditable = false; output.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view = output
        V02MutationSession.shared.didChange = { [weak self] in self?.output.text = $0 }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); guard !launched else { return }; launched = true
        let container = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String ?? ""
        Task { await V02MutationSession.shared.run(request, container: container) }
    }
}
