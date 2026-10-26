import XCTest
@testable import GraphEvoDemo

@MainActor
final class V01IndependentOwnerTests: XCTestCase {
    func testBothDistinctOwnersStayAliveWithOneURLAndEventsAttributedUntilClose() async throws {
        let a = WeakT5Child()
        let b = WeakT5Child()
        var creations: [String] = []
        let pair = V01IndependentOwners { key in
            creations.append(key)
            let child = FakeT5Child()
            if key == "A" { a.value = child } else { b.value = child }
            return child
        }
        var events: [V01NativeEvent] = []
        try await pair.open(stores: locations(), containerIdentifier: "test") { events.append($0) }
        XCTAssertEqual(creations, ["A", "B"])
        XCTAssertNotNil(a.value)
        XCTAssertNotNil(b.value)
        XCTAssertFalse(a.value === b.value)
        XCTAssertEqual(a.value?.openedKeys, ["A"])
        XCTAssertEqual(b.value?.openedKeys, ["B"])
        XCTAssertNotEqual(a.value?.openedURL, b.value?.openedURL)
        XCTAssertEqual(a.value?.identifier, "test")
        XCTAssertEqual(b.value?.identifier, "test")
        XCTAssertEqual(events.map(\.ownerKey), ["owner-A", "owner-B"])
        XCTAssertEqual(pair.loadResults.map(\.ownerKey), ["owner-A", "owner-B"])
        let id = UUID()
        try await pair.insert(V01Row.fixture(id).filter { $0.logicalGraphID == "A" }, into: "A")
        try await pair.insert(V01Row.fixture(id).filter { $0.logicalGraphID == "B" }, into: "B")
        XCTAssertEqual(a.value?.rows.count, 2)
        XCTAssertEqual(b.value?.rows.count, 1)
        _ = try await pair.snapshot(runID: id, in: "A")
        XCTAssertNotNil(b.value, "Reading A must not release B's mirror owner")
        try await pair.close()
        XCTAssertNil(a.value)
        XCTAssertNil(b.value)
    }

    func testReusedOwnerOrURLIsRejectedBeforeAnyStoreOpen() async throws {
        let child = FakeT5Child()
        let pair = V01IndependentOwners { _ in child }
        do { try await pair.open(stores: locations(), containerIdentifier: "test", event: { _ in }); XCTFail("Owners must differ") }
        catch { XCTAssertTrue(error is V01IndependentOwnerError) }
        XCTAssertEqual(child.openCount, 0)
        try await pair.close()
        let sameURL = locations()[0].url
        var creations = 0
        let invalid = V01IndependentOwners { _ in creations += 1; return FakeT5Child() }
        do {
            try await invalid.open(stores: [V01StoreLocation(key: "A", url: sameURL), V01StoreLocation(key: "B", url: sameURL)], containerIdentifier: "test", event: { _ in })
            XCTFail("SQLite URLs must differ")
        } catch { XCTAssertTrue(error is V01IndependentOwnerError) }
        XCTAssertEqual(creations, 0)
    }

    func testCloseFailureStillClosesTheOtherOwner() async throws {
        let a = FakeT5Child()
        a.failClosing = true
        let b = FakeT5Child()
        let pair = V01IndependentOwners { $0 == "A" ? a : b }
        try await pair.open(stores: locations(), containerIdentifier: "test", event: { _ in })
        do { try await pair.close(); XCTFail("Close failure must propagate") }
        catch { XCTAssertTrue(error is CocoaError) }
        XCTAssertTrue(a.closeAttempted)
        XCTAssertTrue(b.closeAttempted)
    }

    func testT5WriterRoutesAndSamplesEachLiveOwnerSeparately() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = FakeT5Child()
        let b = FakeT5Child()
        a.appendOtherGraphOnSecondRead = true
        let pair = V01IndependentOwners { $0 == "A" ? a : b }
        let session = V01Session(root: root, permitSimulatorForTests: true,
                                 makeStore: { XCTFail("T5 writer cannot use one shared owner"); return FakeT5Child() },
                                 makeIndependentOwners: { pair }, accountAvailable: { _ in true })
        let id = UUID()
        await session.run(role: "t5-writer", runID: id, containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertEqual(a.rows, V01Row.fixture(id).filter { $0.logicalGraphID == "A" })
        XCTAssertEqual(b.rows, V01Row.fixture(id).filter { $0.logicalGraphID == "B" })
        XCTAssertEqual(session.report?.ownerStorePlan, ["owner-A": ["A"], "owner-B": ["B"]])
        XCTAssertEqual(session.report?.initialLocalObservation, .localStoresSeparated)
        XCTAssertEqual(session.report?.topologyObservation, .localMixtureObserved)
        XCTAssertEqual(session.report?.storeSnapshots?["A"]?.rows.count, 3)
        XCTAssertEqual(session.report?.nativeEvents.map(\.ownerKey), ["owner-A", "owner-B"])
        XCTAssertTrue(a.closeAttempted)
        XCTAssertTrue(b.closeAttempted)
    }

    func testT5ReaderUsesOneFreshPeerAndNeverInserts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let peer = FakeT5Child()
        peer.rows = V01Row.fixture(id)
        let session = V01Session(root: root, permitSimulatorForTests: true, makeStore: { peer },
                                 makeIndependentOwners: { XCTFail("A peer uses only one owner"); return V01IndependentOwners() },
                                 accountAvailable: { _ in true })
        await session.run(role: "t5-reader", runID: id, containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertEqual(peer.openedKeys, ["peer"])
        XCTAssertTrue(peer.openedFreshPath)
        XCTAssertEqual(peer.insertCount, 0)
        XCTAssertEqual(session.report?.topologyObservation, .unifiedPeerReplicaObserved)
        XCTAssertTrue(session.report?.exactFixtureRecovered == true)
        XCTAssertTrue(session.report?.localSaveCompleted == false)
        XCTAssertEqual(session.report?.nativeEvents.first?.ownerKey, "owner-peer")
        XCTAssertEqual(session.report?.storeLoadResults?.first?.ownerKey, "owner-peer")
    }

    func testTwoRealLocalOwnersKeepRunPredicateAndAffectedStoreReads() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = V01IndependentOwners { _ in V01CloudStore(localOnlyForTests: true) }
        let stores = locations(root: root)
        try await pair.open(stores: stores, containerIdentifier: "unused", event: { _ in XCTFail("No cloud owner in local test") })
        let id = UUID()
        let fixture = V01Row.fixture(id)
        try await pair.insert(Array(fixture.prefix(2)), into: "A")
        try await pair.insert([fixture[2]], into: "B")
        let a = try await pair.snapshot(runID: id, in: "A")
        let b = try await pair.snapshot(runID: id, in: "B")
        XCTAssertEqual(a.rows.count, 2)
        XCTAssertEqual(b.rows.count, 1)
        XCTAssertNotEqual(a.storeIdentifier, b.storeIdentifier)
        // This intentional cross-label assignment must remain visible: no graph-label filter.
        try await pair.insert([fixture[0]], into: "B")
        let crossLabel = try await pair.snapshot(runID: id, in: "B")
        XCTAssertEqual(crossLabel.rows.count, 2)
        let otherRun = try await pair.snapshot(runID: UUID(), in: "B")
        XCTAssertTrue(otherRun.rows.isEmpty)
        try await pair.close()
    }

    func testT5PartialOpenFailureIsRetainedAndBothOwnersClosedWithoutFallback() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = FakeT5Child()
        let b = FakeT5Child()
        b.failOpening = true
        let pair = V01IndependentOwners { $0 == "A" ? a : b }
        let session = V01Session(root: root, permitSimulatorForTests: true,
                                 makeIndependentOwners: { pair }, accountAvailable: { _ in true })
        await session.run(role: "t5-writer", runID: UUID(), containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertEqual(session.report?.topologyObservation, .openingFailed)
        XCTAssertEqual(session.report?.storeLoadResults?.map(\.ownerKey), ["owner-A", "owner-B"])
        XCTAssertEqual(a.insertCount + b.insertCount, 0)
        XCTAssertEqual(a.openCount, 1)
        XCTAssertEqual(b.openCount, 1)
        XCTAssertTrue(a.closeAttempted)
        XCTAssertTrue(b.closeAttempted)
        XCTAssertTrue(session.finalReportRetained)
    }

    func testDedicatedT5RolesParseWithoutReinterpretingT1T2() {
        for role in ["t5-writer", "t5-reader"] {
            let request = V01LaunchRequest.parse(["--v01-role", role, "--v01-run-id", UUID().uuidString, "--v01-development-verified"])
            XCTAssertEqual(request?.role, role)
        }
        XCTAssertTrue(V01Session.validRoles.contains("t1-writer"))
        XCTAssertTrue(V01Session.validRoles.contains("t2-reader"))
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func locations(root: URL? = nil) -> [V01StoreLocation] {
        let directory = root ?? temporaryRoot()
        return [V01StoreLocation(key: "A", url: directory.appendingPathComponent("A.sqlite")),
                V01StoreLocation(key: "B", url: directory.appendingPathComponent("B.sqlite"))]
    }
}

@MainActor
private final class WeakT5Child { weak var value: FakeT5Child? }

@MainActor
private final class FakeT5Child: V01TopologyStoreAccess {
    var loadResults: [V01StoreLoad] = []
    var rows: [V01Row] = []
    var openedKeys: [String] = []
    var openedURL: URL?
    var identifier: String?
    var openedFreshPath = false
    var openCount = 0
    var insertCount = 0
    var closeAttempted = false
    var failOpening = false
    var failClosing = false
    var appendOtherGraphOnSecondRead = false
    private var readCount = 0
    func open(stores: [V01StoreLocation], containerIdentifier: String, event: @escaping (V01NativeEvent) -> Void) async throws {
        openCount += 1
        openedKeys = stores.map(\.key)
        openedURL = stores.first?.url
        identifier = containerIdentifier
        openedFreshPath = stores.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) }
        loadResults = stores.map { V01StoreLoad(storeKey: $0.key, succeeded: !failOpening, error: failOpening ? "NSCocoaErrorDomain:134060" : nil) }
        if failOpening { throw NSError(domain: NSCocoaErrorDomain, code: 134060) }
        event(V01NativeEvent(identifier: UUID(), kind: "setup", started: Date(), finished: Date(), succeeded: true,
                             storeIdentifier: "store-\(stores.first?.key ?? "unknown")", error: nil))
    }
    func insert(_ rows: [V01Row], into storeKey: String) async throws { insertCount += 1; self.rows += rows }
    func snapshot(runID: UUID, in storeKey: String) async throws -> V01Snapshot {
        readCount += 1
        let result = appendOtherGraphOnSecondRead && readCount > 1 ? V01Row.fixture(runID) : rows
        return V01Snapshot(rows: result, mappings: [], storeIdentifier: "store-\(storeKey)")
    }
    func close() async throws { closeAttempted = true; if failClosing { throw CocoaError(.fileWriteUnknown) } }
    func open(at url: URL, containerIdentifier: String, event: @escaping (V01NativeEvent) -> Void) async throws { XCTFail("Explicit locations required") }
    func insert(_ rows: [V01Row]) async throws { XCTFail("Explicit owner routing required") }
    func snapshot(runID: UUID) async throws -> V01Snapshot { XCTFail("Explicit scoped fetch required"); throw V01Error.notOpen }
}
