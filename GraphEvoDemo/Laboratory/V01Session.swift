import Foundation
import CloudKit
import UIKit

struct V01Report: Codable {
    let procedure: String
    let runID: UUID
    let stageID: UUID
    let role: String
    let processID: UUID
    let started: Date
    var finished: Date?
    let environment: [String: String]
    let configuration: [String: String]
    let expected: [V01Row]
    var observed: V01Snapshot?
    var storeLoadResults: [V01StoreLoad]?
    var initialStoreSnapshots: [String: V01Snapshot]?
    var storeSnapshots: [String: V01Snapshot]?
    var localSavesByStore: [String: Bool]?
    var initialLocalObservation: V01TopologyObservation?
    var topologyObservation: V01TopologyObservation?
    var nativeEvents: [V01NativeEvent] = []
    var droppedEventCount = 0
    var localSaveCompleted = false
    var successfulExportEventObserved = false
    var exactFixtureRecovered = false
    var outcome = "Running; not completed evidence"
    var lifecycle = "Stage has not opened a store"
    var errors: [String] = []
}

/// T0 instrumentation, also usable as an explicitly separate same-device preliminary check.
/// Device/account independence and signed environment are verified externally, not inferred here.
@MainActor
final class V01Session {
    static let shared = V01Session()
    static let processID = UUID()
    static let validRoles = ["writer", "reader", "t1-writer", "t2-reader"]
    private let root: URL
    private let makeStore: @MainActor () -> V01StoreAccess
    private let accountAvailable: (String) async throws -> Bool
    private let permitSimulatorForTests: Bool
    private var stageStarted = false
    private(set) var isRunning = false
    private(set) var report: V01Report?
    private(set) var reportURL: URL?
    private(set) var finalReportRetained = false
    private var observers: [UUID: () -> Void] = [:]
    func observeChanges(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }
    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }
    private func notifyObservers() { for observer in Array(observers.values) { observer() } }

    init(root: URL? = nil, permitSimulatorForTests: Bool = false,
         makeStore: @escaping @MainActor () -> V01StoreAccess = { V01CloudStore() },
         accountAvailable: @escaping (String) async throws -> Bool = { identifier in
             try await CKContainer(identifier: identifier).accountStatus() == .available
         }) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("V01Laboratory", isDirectory: true)
        self.makeStore = makeStore
        self.accountAvailable = accountAvailable
        self.permitSimulatorForTests = permitSimulatorForTests
    }

    var canStart: Bool { !stageStarted }
    var readableReport: String {
        guard let report, let data = try? Self.encoder.encode(report) else {
            return "T0 requires two devices on the same account. Same-device recovery is preliminary only. T1/T2 require the reviewed T0 control; T3–T5 are not implemented."
        }
        return String(decoding: data, as: UTF8.self)
    }

    func run(role: String, runID: UUID, containerIdentifier: String, developmentVerified: Bool, windowSeconds: Int = 120) async {
        guard !stageStarted else { return }
        stageStarted = true
        isRunning = true
        finalReportRetained = false
        let stageID = UUID()
        let directory = root.appendingPathComponent("Stores/\(runID.uuidString)/\(role)-\(stageID.uuidString)")
        let url = directory.appendingPathComponent("probe.sqlite")
        let topologyTrial = role == "t1-writer" || role == "t2-reader"
        let locations = role == "t1-writer"
            ? [V01StoreLocation(key: "A", url: directory.appendingPathComponent("A.sqlite")),
               V01StoreLocation(key: "B", url: directory.appendingPathComponent("B.sqlite"))]
            : [V01StoreLocation(key: role == "t2-reader" ? "peer" : "main", url: url)]
        reportURL = root.appendingPathComponent("Reports/\(runID.uuidString)-\(role)-\(stageID.uuidString).json")
        let window = min(max(windowSeconds, 0), 600)
        report = V01Report(procedure: topologyTrial ? "V01-T1-T2-v1 (reviewed T0 prerequisite; no topology decision)" : "V01-T0-control-v1 (external device/account verification required)",
                           runID: runID, stageID: stageID, role: role, processID: Self.processID, started: Date(),
                           environment: ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                                         "deviceClass": UIDevice.current.model,
                                         "demoRevision": Self.buildValue("LaboratoryDemoRevision"),
                                         "graphEvoRevision": Self.buildValue("LaboratoryGraphEvoRevision"),
                                         "sourceState": Self.buildValue("LaboratorySourceState"),
                                         "toolchain": Self.buildValue("LaboratoryToolchain")],
                           configuration: ["boundary": "Direct NSPersistentCloudKitContainer; private database; no GraphProvider",
                                           "model": "V01ProbeItem-v1: optional runID/logicalGraphID/itemID/value strings; no constraints",
                                           "resource": "Locally configured dedicated Development resource; signature verified externally",
                                           "localStore": locations.map { "\($0.key)=Stores/\(runID.uuidString)/\(role)-\(stageID.uuidString)/\($0.url.lastPathComponent)" }.joined(separator: "; "),
                                           "observationWindowSeconds": String(window),
                                           "remoteCleanup": "Not performed; synthetic fixtures remain remotely",
                                           "controlLimit": topologyTrial
                                               ? "T1: A/B assigned to two stores of one container; T2: one fresh peer, runID predicate only; T3–T5 excluded"
                                               : "No topology comparison; labels A/B are markers within one store"],
                           expected: V01Row.fixture(runID))
        notifyObservers()
        var owner: V01StoreAccess?
        var opening = false
        do {
            guard developmentVerified, !GraphProvider.wasInitialized, Self.validRoles.contains(role), !containerIdentifier.isEmpty else { throw V01Error.missingConfiguration }
            #if targetEnvironment(simulator)
            guard permitSimulatorForTests else { throw V01Error.missingConfiguration }
            #endif
            guard try await accountAvailable(containerIdentifier) else { throw V01Error.accountUnavailable }
            guard locations.allSatisfy({ !FileManager.default.fileExists(atPath: $0.url.path) }) else { throw V01Error.freshPathRequired }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try persist()
            let store = makeStore()
            owner = store
            let receiveEvent: (V01NativeEvent) -> Void = { [weak self] event in
                guard let self, self.isRunning else { return }
                if self.report?.nativeEvents.count ?? 0 < 128 { self.report?.nativeEvents.append(event) }
                else { self.report?.droppedEventCount += 1 }
                if event.kind == "export", event.finished != nil, event.succeeded {
                    self.report?.successfulExportEventObserved = true
                }
                self.notifyObservers()
            }
            opening = true
            if topologyTrial {
                guard let topology = store as? V01TopologyStoreAccess else { throw V01Error.notOpen }
                try await topology.open(stores: locations, containerIdentifier: containerIdentifier, event: receiveEvent)
                report?.storeLoadResults = topology.loadResults
            } else {
                try await store.open(at: url, containerIdentifier: containerIdentifier, event: receiveEvent)
            }
            opening = false
            report?.lifecycle = "All configured fresh local stores opened"
            if role == "t1-writer" {
                guard let topology = store as? V01TopologyStoreAccess else { throw V01Error.notOpen }
                report?.localSavesByStore = [:]
                for key in ["A", "B"] {
                    try await topology.insert(V01Row.fixture(runID).filter { $0.logicalGraphID == key }, into: key)
                    report?.localSavesByStore?[key] = true
                    try persist()
                }
                report?.localSaveCompleted = true
                let initial = try await topologySnapshots(topology, locations: locations, runID: runID)
                report?.initialStoreSnapshots = initial
                report?.initialLocalObservation = .local(initial, runID: runID)
            } else if role == "writer" {
                try await store.insert(V01Row.fixture(runID))
                report?.localSaveCompleted = true
            }
            // Only fresh LOCAL reads are sampled. Neither CloudKit polling nor forced synchronization.
            let deadline = Date().addingTimeInterval(TimeInterval(window))
            repeat {
                if topologyTrial {
                    guard let topology = store as? V01TopologyStoreAccess else { throw V01Error.notOpen }
                    let snapshots = try await topologySnapshots(topology, locations: locations, runID: runID)
                    report?.storeSnapshots = snapshots
                    if role == "t1-writer" {
                        report?.topologyObservation = .local(snapshots, runID: runID)
                    } else if let peer = snapshots["peer"] {
                        report?.observed = peer
                        report?.topologyObservation = .peer(peer, runID: runID)
                        if report?.topologyObservation == .unifiedPeerReplicaObserved {
                            report?.exactFixtureRecovered = true
                            break
                        }
                    }
                } else {
                    let snapshot = try await store.snapshot(runID: runID)
                    report?.observed = snapshot
                    if role == "reader", V01TopologyObservation.exact(snapshot.rows, V01Row.fixture(runID)) {
                        report?.exactFixtureRecovered = true
                        break
                    }
                }
                try persist()
                notifyObservers()
                if Date() >= deadline { break }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } while Date() < deadline
            let observation = report?.topologyObservation?.rawValue ?? "inconclusive"
            let exactFixture = report?.exactFixtureRecovered == true
            if role == "t1-writer" {
                report?.outcome = "Observed local stores: \(observation). Local assignment and affectedStores are not cloud separation; inspect each store's rows, mappings and native events, then compare the independent peer."
            } else if role == "t2-reader" {
                report?.outcome = exactFixture
                    ? "Observed unified peer replica for this run: exact A and B fixture recovered in one fresh store without inserts. This is not a universal topology or isolation guarantee."
                    : "Inconclusive: peer fixture absent, partial or different within the observation window. Missing rows do not prove separation."
            } else if role == "writer", !V01TopologyObservation.exact(report?.observed?.rows ?? [], V01Row.fixture(runID)) {
                report?.outcome = "Inconclusive: the writer's local fixture differs from the expected exact rows."
            } else if role == "writer" {
                report?.outcome = "Local save observed. Export event and mappings are separate diagnostics, not fixture-level server acknowledgement. Restart before reader."
            } else if report?.exactFixtureRecovered == true {
                report?.outcome = "Observed exact fixture recovery into a fresh reader. T0 requires externally confirmed independent devices and same account; same-device evidence is preliminary."
            } else {
                report?.outcome = "Inconclusive: expected fixture not recovered within the observation window. Missing rows do not prove isolation."
            }
        } catch {
            report?.errors.append(v01ErrorCode(error))
            if let preflight = error as? V01ConfigurationError {
                report?.topologyObservation = .preflightRejected
                report?.outcome = "Preflight rejected (not a new native trial): \(preflight.localizedDescription)"
            } else if topologyTrial, opening {
                report?.topologyObservation = .openingFailed
                report?.outcome = "Opening failed: native configured-store error. Partial-open results retained; no fallback, replacement zone or retry."
            } else {
                report?.outcome = "Inconclusive: stage failed; inspect error domain/code. No local fallback."
            }
        }
        if topologyTrial, let topology = owner as? V01TopologyStoreAccess {
            report?.storeLoadResults = topology.loadResults
        }
        do {
            try await owner?.close()
            owner = nil
            let preflightRejected = report?.topologyObservation == .preflightRejected
            report?.lifecycle = preflightRejected
                ? "Application preflight rejected before mirror-owner construction, store loading or fixture insertion. No native trial was repeated."
                : "Contexts reset, stores detached, owner reference released. Restart before another stage; no shutdown acknowledgement is inferred."
        } catch {
            report?.errors.append("Close: \(v01ErrorCode(error))")
            report?.outcome = "Inconclusive: store detachment failed; terminate the app before further work."
        }
        report?.finished = Date()
        do { try persist(); finalReportRetained = true }
        catch {
            report?.outcome = "Inconclusive: final report retention failed"
            report?.errors.append("Retention: \(v01ErrorCode(error))")
        }
        isRunning = false
        notifyObservers()
        print("V01 stage ended; runID=\(runID.uuidString); role=\(role); retained=\(finalReportRetained)")
    }

    private func topologySnapshots(_ owner: V01TopologyStoreAccess, locations: [V01StoreLocation], runID: UUID) async throws -> [String: V01Snapshot] {
        var snapshots: [String: V01Snapshot] = [:]
        for location in locations {
            snapshots[location.key] = try await owner.snapshot(runID: runID, in: location.key)
        }
        return snapshots
    }

    private func persist() throws {
        guard let report, let reportURL else { return }
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(report).write(to: reportURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func buildValue(_ key: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        return value.isEmpty ? "Unrecorded" : value
    }
}
