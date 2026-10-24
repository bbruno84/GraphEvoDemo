import XCTest
@testable import GraphEvoDemo

@MainActor
final class V01Tests: XCTestCase {
    func testReaderRecoversExactFixtureWithoutInsertionAndUsesFreshPath() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let store = FakeV01Store(rows: V01Row.fixture(id))
        let session = makeSession(root, store: store)
        await session.run(role: "reader", runID: id, containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertTrue(store.inserted.isEmpty)
        XCTAssertTrue(store.closed)
        XCTAssertTrue(store.openedFreshPath)
        XCTAssertTrue(session.report?.exactFixtureRecovered == true)
        XCTAssertTrue(session.report?.localSaveCompleted == false)
        XCTAssertTrue(session.finalReportRetained)
        XCTAssertTrue(session.report?.outcome.contains("externally confirmed independent devices") == true)
        let firstPath = store.url
        let second = FakeV01Store(rows: V01Row.fixture(id))
        await makeSession(root, store: second).run(role: "reader", runID: id, containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertNotEqual(firstPath, second.url)
    }

    func testExportEventAndMappingAloneDoNotPassReader() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FakeV01Store(rows: [])
        store.emitExport = true
        let session = makeSession(root, store: store)
        await session.run(role: "reader", runID: UUID(), containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertTrue(session.report?.successfulExportEventObserved == true)
        XCTAssertFalse(session.report?.exactFixtureRecovered ?? true)
        XCTAssertTrue(session.report?.outcome.hasPrefix("Inconclusive:") == true)
        XCTAssertTrue(store.inserted.isEmpty)
    }

    func testWriterPersistsFixtureAndRequiresNewProcessForNextStage() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let store = FakeV01Store(rows: V01Row.fixture(id))
        let session = makeSession(root, store: store)
        await session.run(role: "writer", runID: id, containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertEqual(store.inserted, V01Row.fixture(id))
        XCTAssertTrue(store.closed)
        XCTAssertFalse(session.canStart)
        XCTAssertTrue(session.report?.localSaveCompleted == true)
        XCTAssertFalse(session.report?.exactFixtureRecovered ?? true)
        await session.run(role: "reader", runID: id, containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertEqual(session.report?.role, "writer")
        XCTAssertEqual(store.openCount, 1)
    }

    func testUnavailableAccountDoesNotOpenOrInsert() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FakeV01Store(rows: [])
        let session = V01Session(root: root, permitSimulatorForTests: true, makeStore: { store }, accountAvailable: { _ in false })
        await session.run(role: "writer", runID: UUID(), containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
        XCTAssertEqual(store.openCount, 0)
        XCTAssertTrue(store.inserted.isEmpty)
        XCTAssertTrue(session.report?.outcome.hasPrefix("Inconclusive:") == true)
    }

    func testDuplicateOrWrongValuesDoNotCountAsExactFixture() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let fixture = V01Row.fixture(id)
        let wrongValue = V01Row(runID: id.uuidString, logicalGraphID: "A", itemID: "A-001", value: "wrong")
        for rows in [fixture + [fixture[0]], Array(fixture.dropLast()), [wrongValue] + fixture.dropFirst()] {
            let session = makeSession(root, store: FakeV01Store(rows: rows))
            await session.run(role: "reader", runID: id, containerIdentifier: "test", developmentVerified: true, windowSeconds: 0)
            XCTAssertFalse(session.report?.exactFixtureRecovered ?? true)
        }
    }

    func testLaunchArgumentsRequireExplicitDevelopmentConfirmationAndValidRun() {
        let arguments = ["app", "--v01-role", "reader", "--v01-run-id", UUID().uuidString, "--v01-window", "10"]
        XCTAssertNil(V01LaunchRequest.parse(arguments))
        XCTAssertNotNil(V01LaunchRequest.parse(arguments + ["--v01-development-verified"]))
        XCTAssertNil(V01LaunchRequest.parse(["--v01-development-verified", "--v01-role", "reader", "--v01-run-id", "invalid"]))
        let model = V01CloudStore.makeModel()
        XCTAssertEqual(model.entities.count, 1)
        XCTAssertTrue(model.entities[0].properties.allSatisfy(\.isOptional))
        XCTAssertTrue(model.entities[0].uniquenessConstraints.isEmpty)
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func makeSession(_ root: URL, store: FakeV01Store) -> V01Session {
        V01Session(root: root, permitSimulatorForTests: true, makeStore: { store }, accountAvailable: { _ in true })
    }
}

@MainActor
private final class FakeV01Store: V01StoreAccess {
    let rows: [V01Row]
    var inserted: [V01Row] = []
    var closed = false
    var openedFreshPath = false
    var openCount = 0
    var emitExport = false
    var url: URL?
    init(rows: [V01Row]) { self.rows = rows }
    func open(at url: URL, containerIdentifier: String, event: @escaping (V01NativeEvent) -> Void) async throws {
        self.url = url
        openedFreshPath = !FileManager.default.fileExists(atPath: url.path)
        openCount += 1
        if emitExport {
            event(V01NativeEvent(identifier: UUID(), kind: "export", started: Date(), finished: Date(), succeeded: true, storeIdentifier: "fake", error: nil))
        }
    }
    func insert(_ rows: [V01Row]) async throws { inserted += rows }
    func snapshot(runID: UUID) async throws -> V01Snapshot {
        V01Snapshot(rows: rows, mappings: [V01Mapping(itemID: "A-001", recordName: "fake-record", zoneName: "fake-zone")], storeIdentifier: "fake")
    }
    func close() async throws { closed = true }
}
