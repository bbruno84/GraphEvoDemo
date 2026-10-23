import Foundation

struct V01StoreLocation {
    let key: String
    let url: URL
}

struct V01StoreLoad: Codable {
    let storeKey: String
    let succeeded: Bool
    let error: String?
    var storeIdentifier: String? = nil
    var localFile: String? = nil
}

/// Serial callback bookkeeping, independent of callback order. No continuation is resumed twice.
@MainActor
final class V01StoreLoadTracker {
    private let keys: Set<String>
    private(set) var results: [String: V01StoreLoad] = [:]
    private(set) var firstError: Error?

    init(keys: [String]) { self.keys = Set(keys) }

    func record(key: String, error: Error?, storeIdentifier: String? = nil, localFile: String? = nil) -> Bool {
        guard keys.contains(key), results[key] == nil else { return false }
        results[key] = V01StoreLoad(storeKey: key, succeeded: error == nil, error: error.map(v01ErrorCode), storeIdentifier: storeIdentifier, localFile: localFile)
        if firstError == nil { firstError = error }
        return results.count == keys.count
    }
}

@MainActor
protocol V01TopologyStoreAccess: V01StoreAccess {
    var loadResults: [V01StoreLoad] { get }
    func open(stores: [V01StoreLocation], containerIdentifier: String, event: @escaping (V01NativeEvent) -> Void) async throws
    func insert(_ rows: [V01Row], into storeKey: String) async throws
    func snapshot(runID: UUID, in storeKey: String) async throws -> V01Snapshot
}

enum V01TopologyObservation: String, Codable {
    case openingFailed
    case preflightRejected
    case localStoresSeparated
    case localMixtureObserved
    case unifiedPeerReplicaObserved
    case inconclusive

    static func local(_ snapshots: [String: V01Snapshot], runID: UUID) -> V01TopologyObservation {
        guard let a = snapshots["A"], let b = snapshots["B"] else { return .inconclusive }
        let expected = V01Row.fixture(runID)
        if exact(a.rows, expected.filter { $0.logicalGraphID == "A" }),
           exact(b.rows, expected.filter { $0.logicalGraphID == "B" }) { return .localStoresSeparated }
        // Cross-store membership is positive evidence of a mixture, not an inference from absence.
        if a.rows.contains(where: { expected.contains($0) && $0.logicalGraphID == "B" }) ||
            b.rows.contains(where: { expected.contains($0) && $0.logicalGraphID == "A" }) { return .localMixtureObserved }
        return .inconclusive
    }

    static func peer(_ snapshot: V01Snapshot, runID: UUID) -> V01TopologyObservation {
        exact(snapshot.rows, V01Row.fixture(runID)) ? .unifiedPeerReplicaObserved : .inconclusive
    }

    static func exact(_ actual: [V01Row], _ expected: [V01Row]) -> Bool {
        actual.sorted { $0.sortKey < $1.sortKey } == expected.sorted { $0.sortKey < $1.sortKey }
    }
}

/// Prevents repeating the native T1 NSInvalidArgumentException already retained in evidence.
/// This is an application preflight, not another Apple framework experiment.
enum V01ConfigurationError: LocalizedError {
    case duplicateCloudDestination

    var errorDescription: String? {
        "Known unsupported T1 configuration: the same CloudKit container and database scope are assigned to multiple stores. Preflight rejected before mirror-owner creation; see the recorded T1 native exception."
    }
}
