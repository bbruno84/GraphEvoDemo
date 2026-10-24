import Foundation

/// T5 owns two distinct containers, each opening exactly one distinct store URL.
/// Validation stays inside each child owner; the T1 duplicate-destination guard is unchanged.
@MainActor
final class V01IndependentOwners: V01TopologyStoreAccess {
    private let makeOwner: @MainActor (String) -> V01TopologyStoreAccess
    private var owners: [String: V01TopologyStoreAccess] = [:]

    init(makeOwner: @escaping @MainActor (String) -> V01TopologyStoreAccess = { _ in V01CloudStore() }) {
        self.makeOwner = makeOwner
    }

    var loadResults: [V01StoreLoad] {
        owners.keys.sorted().flatMap { key in
            (owners[key]?.loadResults ?? []).map { result in
                var attributed = result
                attributed.ownerKey = "owner-\(key)"
                return attributed
            }
        }
    }

    func open(stores: [V01StoreLocation], containerIdentifier: String, event: @escaping (V01NativeEvent) -> Void) async throws {
        guard owners.isEmpty, stores.count == 2, Set(stores.map(\.key)) == ["A", "B"],
              Set(stores.map { $0.url.standardizedFileURL }).count == 2 else {
            throw V01IndependentOwnerError.invalidStorePlan
        }
        // Allocate and retain both owners before opening either. Never route both files to one owner.
        for location in stores {
            let owner = makeOwner(location.key)
            guard !owners.values.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(owner) }) else {
                throw V01IndependentOwnerError.reusedOwnerInstance
            }
            owners[location.key] = owner
        }
        for location in stores {
            guard let owner = owners[location.key] else { throw V01Error.notOpen }
            let ownerKey = "owner-\(location.key)"
            try await owner.open(stores: [location], containerIdentifier: containerIdentifier) { native in
                var attributed = native
                attributed.ownerKey = ownerKey
                event(attributed)
            }
        }
    }

    func insert(_ rows: [V01Row], into storeKey: String) async throws {
        guard let owner = owners[storeKey] else { throw V01Error.notOpen }
        try await owner.insert(rows, into: storeKey)
    }

    func snapshot(runID: UUID, in storeKey: String) async throws -> V01Snapshot {
        guard let owner = owners[storeKey] else { throw V01Error.notOpen }
        return try await owner.snapshot(runID: runID, in: storeKey)
    }

    func close() async throws {
        var firstError: Error?
        // A failed close must not prevent attempting to close the other owner.
        for key in owners.keys.sorted() {
            do { try await owners[key]?.close() }
            catch { if firstError == nil { firstError = error } }
        }
        owners.removeAll()
        if let firstError { throw firstError }
    }

    func open(at url: URL, containerIdentifier: String, event: @escaping (V01NativeEvent) -> Void) async throws {
        throw V01IndependentOwnerError.invalidStorePlan
    }
    func insert(_ rows: [V01Row]) async throws { throw V01IndependentOwnerError.invalidStorePlan }
    func snapshot(runID: UUID) async throws -> V01Snapshot { throw V01IndependentOwnerError.invalidStorePlan }
}

enum V01IndependentOwnerError: LocalizedError {
    case invalidStorePlan, reusedOwnerInstance
    var errorDescription: String? {
        switch self {
        case .invalidStorePlan: return "T5 requires distinct A/B URLs and explicit per-owner routing."
        case .reusedOwnerInstance: return "T5 requires two distinct owner instances; no fallback is permitted."
        }
    }
}
