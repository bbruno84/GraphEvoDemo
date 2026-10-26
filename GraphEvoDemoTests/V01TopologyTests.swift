import XCTest
import CoreData
@testable import GraphEvoDemo

@MainActor
final class V01TopologyTests: XCTestCase {
    func testRealLocalTwoStoreRoutingAndAffectedStoresDoNotFilterGraphLabels() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = V01CloudStore(localOnlyForTests: true)
        let locations = [V01StoreLocation(key: "B", url: root.appendingPathComponent("B.sqlite")),
                         V01StoreLocation(key: "A", url: root.appendingPathComponent("A.sqlite"))]
        try await owner.open(stores: locations, containerIdentifier: "unused-local-test", event: { _ in XCTFail("No cloud events in local-only test") })
        let id = UUID()
        let fixture = V01Row.fixture(id)
        try await owner.insert(fixture.filter { $0.logicalGraphID == "A" }, into: "A")
        try await owner.insert(fixture.filter { $0.logicalGraphID == "B" }, into: "B")
        let a = try await owner.snapshot(runID: id, in: "A")
        let b = try await owner.snapshot(runID: id, in: "B")
        XCTAssertEqual(a.rows, fixture.filter { $0.logicalGraphID == "A" })
        XCTAssertEqual(b.rows, fixture.filter { $0.logicalGraphID == "B" })
        XCTAssertNotEqual(a.storeIdentifier, b.storeIdentifier)
        XCTAssertEqual(owner.loadResults.count, 2)
        XCTAssertTrue(owner.loadResults.allSatisfy(\.succeeded))

        // A graph-A row assigned to store B must be visible in B's unfiltered snapshot.
        try await owner.insert([fixture[0]], into: "B")
        let mixedB = try await owner.snapshot(runID: id, in: "B")
        XCTAssertEqual(mixedB.rows.count, 2)
        XCTAssertEqual(V01TopologyObservation.local(["A": a, "B": mixedB], runID: id), .localMixtureObserved)
        let unrelated = try await owner.snapshot(runID: UUID(), in: "B")
        XCTAssertTrue(unrelated.rows.isEmpty)
        do { _ = try await owner.snapshot(runID: id, in: "unknown"); XCTFail("Unknown key must not select the first store") }
        catch { XCTAssertTrue(error is V01Error) }
        try await owner.close()
    }

    func testTwoCloudDescriptionsKeepTheSameModelConfigurationAndPrivateResource() {
        let root = temporaryRoot()
        let locations = [V01StoreLocation(key: "A", url: root.appendingPathComponent("A.sqlite")),
                         V01StoreLocation(key: "B", url: root.appendingPathComponent("B.sqlite"))]
        let descriptions = V01CloudStore.descriptions(stores: locations, containerIdentifier: "iCloud.example.test")
        XCTAssertEqual(descriptions.count, 2)
        XCTAssertNotEqual(descriptions[0].url, descriptions[1].url)
        for description in descriptions {
            XCTAssertNil(description.configuration)
            XCTAssertEqual(description.cloudKitContainerOptions?.containerIdentifier, "iCloud.example.test")
            XCTAssertEqual(description.cloudKitContainerOptions?.databaseScope, .private)
            XCTAssertTrue(description.shouldAddStoreAsynchronously)
        }
    }

    func testLoadTrackerWaitsForBothDescriptionsAndDoesNotCompleteTwice() {
        let tracker = V01StoreLoadTracker(keys: ["A", "B"])
        let error = NSError(domain: NSCocoaErrorDomain, code: 134060)
        XCTAssertFalse(tracker.record(key: "B", error: error))
        XCTAssertFalse(tracker.record(key: "B", error: nil))
        XCTAssertFalse(tracker.record(key: "unknown", error: nil))
        XCTAssertTrue(tracker.record(key: "A", error: nil))
        XCTAssertFalse(tracker.record(key: "A", error: nil))
        XCTAssertEqual(tracker.results.count, 2)
        XCTAssertEqual(tracker.results["B"]?.error, "NSCocoaErrorDomain:134060")
        XCTAssertNotNil(tracker.firstError)
    }

    func testT1RoutesFixtureAndRetainsInitialAndLaterMixtureSeparately() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let owner = FakeTopologyStore(runID: id)
        owner.mixAfterInitial = true
        let session = session(root, owner)
        await session.run(role: "t1-writer", runID: id, containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertEqual(owner.openedKeys, ["A", "B"])
        XCTAssertEqual(owner.inserts["A"], V01Row.fixture(id).filter { $0.logicalGraphID == "A" })
        XCTAssertEqual(owner.inserts["B"], V01Row.fixture(id).filter { $0.logicalGraphID == "B" })
        XCTAssertEqual(session.report?.initialLocalObservation, .localStoresSeparated)
        XCTAssertEqual(session.report?.topologyObservation, .localMixtureObserved)
        XCTAssertEqual(session.report?.initialStoreSnapshots?["A"]?.rows.count, 2)
        XCTAssertEqual(session.report?.storeSnapshots?["A"]?.rows.count, 3)
        XCTAssertTrue(owner.closed)
    }

    func testT2ReadsBothGraphsInOnePeerWithoutInsert() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let owner = FakeTopologyStore(runID: id)
        let session = session(root, owner)
        await session.run(role: "t2-reader", runID: id, containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertEqual(owner.openedKeys, ["peer"])
        XCTAssertTrue(owner.inserts.isEmpty)
        XCTAssertEqual(session.report?.topologyObservation, .unifiedPeerReplicaObserved)
        XCTAssertTrue(session.report?.exactFixtureRecovered == true)
        XCTAssertTrue(session.report?.localSaveCompleted == false)
        XCTAssertTrue(owner.closed)
    }

    func testOpeningFailureRetainsPartialLoadAndNeverInsertsOrFallsBack() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = FakeTopologyStore(runID: UUID())
        owner.failOpening = true
        let session = session(root, owner)
        await session.run(role: "t1-writer", runID: owner.runID, containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertEqual(session.report?.topologyObservation, .openingFailed)
        XCTAssertEqual(session.report?.storeLoadResults?.count, 2)
        XCTAssertTrue(session.report?.errors.contains("NSCocoaErrorDomain:134060") == true)
        XCTAssertTrue(owner.inserts.isEmpty)
        XCTAssertEqual(owner.openCount, 1)
        XCTAssertTrue(owner.closed)
        XCTAssertTrue(session.finalReportRetained)
    }

    func testPartialEmptyDuplicateOrUnexpectedPeerRowsRemainInconclusive() {
        let id = UUID()
        let fixture = V01Row.fixture(id)
        for rows in [[], Array(fixture.prefix(2)), [fixture[2]], fixture + [fixture[0]],
                     fixture + [V01Row(runID: id.uuidString, logicalGraphID: "C", itemID: "C-1", value: "unexpected")]] {
            let snapshot = V01Snapshot(rows: rows, mappings: [], storeIdentifier: "peer")
            XCTAssertEqual(V01TopologyObservation.peer(snapshot, runID: id), .inconclusive)
        }
        XCTAssertEqual(V01TopologyObservation.local([:], runID: id), .inconclusive)
        XCTAssertNotNil(V01LaunchRequest.parse(["--v01-role", "t1-writer", "--v01-run-id", id.uuidString, "--v01-development-verified"]))
        XCTAssertNotNil(V01LaunchRequest.parse(["--v01-role", "t2-reader", "--v01-run-id", id.uuidString, "--v01-development-verified"]))
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func session(_ root: URL, _ owner: FakeTopologyStore) -> V01Session {
        V01Session(root: root, permitSimulatorForTests: true, makeStore: { owner }, accountAvailable: { _ in true })
    }
}

@MainActor
private final class FakeTopologyStore: V01TopologyStoreAccess {
    let runID: UUID
    var loadResults: [V01StoreLoad] = []
    var openedKeys: [String] = []
    var inserts: [String: [V01Row]] = [:]
    var failOpening = false
    var mixAfterInitial = false
    var closed = false
    var openCount = 0
    private var reads: [String: Int] = [:]
    init(runID: UUID) { self.runID = runID }
    func open(stores: [V01StoreLocation], containerIdentifier: String, event: @escaping (V01NativeEvent) -> Void) async throws {
        openCount += 1
        openedKeys = stores.map(\.key)
        loadResults = stores.map { V01StoreLoad(storeKey: $0.key, succeeded: !(failOpening && $0.key == "B"), error: failOpening && $0.key == "B" ? "NSCocoaErrorDomain:134060" : nil) }
        if failOpening { throw NSError(domain: NSCocoaErrorDomain, code: 134060) }
    }
    func insert(_ rows: [V01Row], into storeKey: String) async throws { inserts[storeKey, default: []] += rows }
    func snapshot(runID: UUID, in storeKey: String) async throws -> V01Snapshot {
        reads[storeKey, default: 0] += 1
        let rows: [V01Row]
        if storeKey == "peer" || (mixAfterInitial && reads[storeKey, default: 0] > 1) { rows = V01Row.fixture(runID) }
        else { rows = inserts[storeKey] ?? [] }
        return V01Snapshot(rows: rows, mappings: [], storeIdentifier: "store-\(storeKey)")
    }
    func open(at url: URL, containerIdentifier: String, event: @escaping (V01NativeEvent) -> Void) async throws { XCTFail("No fallback to one store") }
    func insert(_ rows: [V01Row]) async throws { XCTFail("Unrouted inserts are forbidden") }
    func snapshot(runID: UUID) async throws -> V01Snapshot { XCTFail("Unscoped fetch is forbidden"); throw V01Error.notOpen }
    func close() async throws { closed = true }
}
