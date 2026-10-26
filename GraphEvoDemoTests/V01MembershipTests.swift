import XCTest
import CoreData
import CloudKit
@testable import GraphEvoDemo

@MainActor
final class V01MembershipTests: XCTestCase {
    private let user = CKRecord.ID(recordName: "local-test-account")

    func testCLIRequiresExplicitReadPhaseAndRejectsContradictoryMutationPhase() {
        let common = ["--v01-membership-development-verified", "--v01-membership-run-id", UUID().uuidString]
        for role in V01MembershipRole.allCases {
            var args = common + ["--v01-membership-role", role.rawValue]
            if role == .reader || role == .reopen {
                XCTAssertNil(V01MembershipRequest.parse(args))
                args += ["--v01-membership-phase", "added"]
            }
            XCTAssertEqual(V01MembershipRequest.parse(args)?.role, role)
            XCTAssertNil(V01MembershipRequest.parse(args.filter { $0 != "--v01-membership-development-verified" }))
            XCTAssertNil(V02Request.parse(args))
        }
        XCTAssertNil(V01MembershipRequest.parse(common + ["--v01-membership-role", "writer-add", "--v01-membership-phase", "original"]))
        XCTAssertNil(V01MembershipRequest.parse(common + ["--v01-membership-role", "writer-delete", "--v01-membership-window", "0"]))
    }

    func testExpectedPhasesRejectStaleFiveRowsDuplicateMissingAndBrokenClosure() throws {
        for phase in V01MembershipPhase.allCases {
            let rows = fixture(phase)
            XCTAssertTrue(V01MembershipFixture.exact(rows, phase: phase))
            for other in V01MembershipPhase.allCases where other != phase {
                XCTAssertFalse(V01MembershipFixture.exact(rows, phase: other))
            }
            XCTAssertFalse(V01MembershipFixture.exact(rows + [rows[0]], phase: phase))
            XCTAssertFalse(V01MembershipFixture.exact(Array(rows.dropLast()), phase: phase))
            var malformed = rows
            malformed[0] = try changing(rows[0], path: ["validClosure"], value: false)
            XCTAssertFalse(V01MembershipFixture.exact(malformed, phase: phase))
        }
    }

    func testIdentityPinsRequireNewChildInOriginalAShareAndUnchangedB() throws {
        let original = fixture(.original)
        let added = fixture(.added)
        XCTAssertTrue(V01MembershipFixture.preserved(added, original: original, added: [], phase: .added))
        XCTAssertTrue(V01MembershipFixture.preserved(fixture(.deleted), original: original, added: added, phase: .deleted))
        var changedRecord = added
        changedRecord[0] = try changing(changedRecord[0], path: ["record", "recordName"], value: "replacement")
        XCTAssertFalse(V01MembershipFixture.preserved(changedRecord, original: original, added: added, phase: .added))
        var changedB = added
        let b = try XCTUnwrap(changedB.firstIndex { $0.graph == "B" })
        changedB[b] = try changing(changedB[b], path: ["share", "participants"], value: [])
        XCTAssertFalse(V01MembershipFixture.preserved(changedB, original: original, added: [], phase: .added))
        var changedNew = added
        let child = try XCTUnwrap(changedNew.firstIndex { $0.node == "A-003" })
        changedNew[child] = try changing(changedNew[child], path: ["record", "recordName"], value: "different-new-record")
        XCTAssertFalse(V01MembershipFixture.preserved(changedNew, original: original, added: added, phase: .added))
        var wrongZone = added
        wrongZone[child] = try changing(wrongZone[child], path: ["share", "id", "zoneName"], value: "zone-B")
        XCTAssertFalse(V01MembershipFixture.preserved(wrongZone, original: original, added: [], phase: .added))
    }

    func testSinglePrivateSQLitePersistsAddUpdateDeleteAndRejectsReplayAcrossReopen() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        let store = V02CloudStore(currentUser: user, localOnly: true, scopes: [.privateStore])
        try await store.open(directory: root, container: "test", fresh: true, event: { _ in })
        XCTAssertEqual(store.inventory.count, 1)
        XCTAssertNil(store.inventory["shared"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("shared.sqlite").path))
        try await store.insertFixture(runID: run)
        let original = try await store.snapshot(runID: run)
        XCTAssertTrue(V01MembershipFixture.exact(original, phase: .original, requireShares: false))
        try await store.addMembershipChild(runID: run)
        let added = try await store.snapshot(runID: run)
        XCTAssertTrue(V01MembershipFixture.exact(added, phase: .added, requireShares: false))
        XCTAssertEqual(original.filter { $0.graph == "B" }, added.filter { $0.graph == "B" })
        do { try await store.addMembershipChild(runID: run); XCTFail("Do not replay the add") } catch {}
        let identifiers = store.inventory
        try await store.close()
        let reopened = V02CloudStore(currentUser: user, localOnly: true, scopes: [.privateStore])
        try await reopened.open(directory: root, container: "test", fresh: false, event: { _ in })
        XCTAssertEqual(reopened.inventory, identifiers)
        try await reopened.deleteMembershipChild(runID: run)
        let deleted = try await reopened.snapshot(runID: run)
        XCTAssertTrue(V01MembershipFixture.exact(deleted, phase: .deleted, requireShares: false))
        XCTAssertEqual(original.filter { $0.graph == "B" }, deleted.filter { $0.graph == "B" })
        do { try await reopened.deleteMembershipChild(runID: run); XCTFail("Do not replay the delete") } catch {}
        try await reopened.close()
        let final = V02CloudStore(currentUser: user, localOnly: true, scopes: [.privateStore])
        try await final.open(directory: root, container: "test", fresh: false, event: { _ in })
        let finalRows = try await final.snapshot(runID: run)
        XCTAssertEqual(finalRows, deleted)
        let otherRun = try await final.snapshot(runID: UUID())
        XCTAssertTrue(otherRun.isEmpty)
        try await final.close()
    }

    func testWriterReservesBeforeAddHoldsFullWindowAndNeverExplicitlySharesNewChild() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        try setupLedger(root, run: run, progress: .ready)
        let store = FakeMembershipStore(rows: fixture(.original))
        store.afterAdd = fixture(.added)
        store.inspectMutation = {
            let ledger = try self.readLedger(root, run: run)
            XCTAssertEqual(ledger.progress, .adding)
        }
        var clock = Date(timeIntervalSince1970: 10)
        var sleeps = 0
        let session = makeSession(root, store: store, now: { clock }, sleep: {
            XCTAssertFalse(store.closed)
            sleeps += 1; clock.addTimeInterval(2)
        })
        await session.run(request(.add, .added, run: run, window: 6), container: "test")
        XCTAssertEqual(store.adds, 1)
        XCTAssertEqual(sleeps, 3)
        XCTAssertTrue(store.createdShares.isEmpty)
        XCTAssertTrue(session.report?.localMutationSaved == true)
        XCTAssertTrue(session.report?.preservedIdentities == true)
        XCTAssertEqual(session.report?.explicitExistingShareCalls, 0)
        XCTAssertEqual(try readLedger(root, run: run).progress, .added)
        XCTAssertTrue(store.closed)
    }

    func testInterruptedAddReservationBlocksReplayAndDoesNotAdvanceToDelete() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        try setupLedger(root, run: run, progress: .ready)
        let failing = FakeMembershipStore(rows: fixture(.original))
        failing.failAdd = true
        let first = makeSession(root, store: failing)
        await first.run(request(.add, .added, run: run), container: "test")
        XCTAssertEqual(try readLedger(root, run: run).progress, .adding)
        for role in [V01MembershipRole.add, .delete] {
            let store = FakeMembershipStore(rows: fixture(.added))
            let next = makeSession(root, store: store)
            await next.run(request(role, role == .add ? .added : .deleted, run: run), container: "test")
            XCTAssertEqual(store.opens, 0)
            XCTAssertEqual(store.adds + store.deletes, 0)
            XCTAssertFalse(next.report?.errors.isEmpty ?? true)
        }
    }

    func testFreshReaderUsesDistinctPathAndDoesNotWriteOrShare() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        try setupLedger(root, run: run, progress: .added)
        var paths: [URL] = []
        for _ in 0..<2 {
            let store = FakeMembershipStore(rows: fixture(.added), identifier: "fresh-reader-" + UUID().uuidString)
            let session = makeSession(root, store: store)
            await session.run(request(.reader, .added, run: run), container: "test")
            XCTAssertTrue(store.fresh == true)
            XCTAssertEqual(store.inserts + store.adds + store.deletes, 0)
            XCTAssertTrue(store.createdShares.isEmpty)
            XCTAssertTrue(session.report?.preservedIdentities == true)
            XCTAssertTrue(session.report?.topology.contains("same device") == true)
            paths.append(try XCTUnwrap(store.directory))
        }
        XCTAssertNotEqual(paths[0], paths[1])
    }

    func testMissingMembershipRemainsInconclusiveWithoutFallbackAndReopenPinsStore() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        try setupLedger(root, run: run, progress: .ready)
        let store = FakeMembershipStore(rows: fixture(.original))
        var incomplete = fixture(.added)
        let child = try XCTUnwrap(incomplete.firstIndex { $0.node == "A-003" })
        incomplete[child] = try changing(incomplete[child], path: ["share"], value: NSNull())
        store.afterAdd = incomplete
        let session = makeSession(root, store: store)
        await session.run(request(.add, .added, run: run), container: "test")
        XCTAssertTrue(session.report?.outcome.hasPrefix("Inconclusive:") == true)
        XCTAssertTrue(store.createdShares.isEmpty)
        XCTAssertEqual(try readLedger(root, run: run).progress, .adding)
        try setupLedger(root, run: run, progress: .deleted, replace: true)
        let wrongStore = FakeMembershipStore(rows: fixture(.deleted), identifier: "replacement-writer")
        let reopen = makeSession(root, store: wrongStore)
        await reopen.run(request(.reopen, .deleted, run: run), container: "test")
        XCTAssertFalse(reopen.report?.errors.isEmpty ?? true)
        XCTAssertFalse(wrongStore.fresh ?? true)
        XCTAssertTrue(wrongStore.closed)
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func request(_ role: V01MembershipRole, _ phase: V01MembershipPhase, run: UUID, window: Int = 0) -> V01MembershipRequest {
        V01MembershipRequest(role: role, runID: run, phase: phase, window: window)
    }
    private func makeSession(_ root: URL, store: FakeMembershipStore, now: @escaping @MainActor @Sendable () -> Date = { Date() },
                             sleep: @escaping @MainActor @Sendable () async throws -> Void = {}) -> V01MembershipSession {
        V01MembershipSession(root: root, permitSimulatorForTests: true, account: { _ in self.user }, makeStore: { _, _ in store }, now: now, sleep: sleep)
    }
    private func setupLedger(_ root: URL, run: UUID, progress: V01MembershipProgress, replace: Bool = false) throws {
        let binding = root.appendingPathComponent("Sensitive/\(run)/owner-binding.json")
        if !replace {
            try V02SensitiveFiles.write(V02Envelope(purpose: "membership-binding", runID: run, containerIdentifier: "test", account: V02PrivateID(user)), to: binding)
        }
        var ledger = V01MembershipLedger(runID: run)
        ledger.progress = progress; ledger.writerStores = ["private": "writer-store"]
        ledger.original = fixture(.original)
        ledger.added = fixture(.added)
        ledger.deleted = fixture(.deleted)
        let url = root.appendingPathComponent("State/\(run).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
    }
    private func readLedger(_ root: URL, run: UUID) throws -> V01MembershipLedger {
        try JSONDecoder().decode(V01MembershipLedger.self, from: Data(contentsOf: root.appendingPathComponent("State/\(run).json")))
    }
    private func changing(_ row: V02Row, path: [String], value: Any) throws -> V02Row {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        func update(_ json: inout [String: Any], _ path: ArraySlice<String>) {
            guard let key = path.first else { return }
            if path.count == 1 { json[key] = value }
            else { var child = json[key] as? [String: Any] ?? [:]; update(&child, path.dropFirst()); json[key] = child }
        }
        update(&json, path[...])
        return try JSONDecoder().decode(V02Row.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func fixture(_ phase: V01MembershipPhase) -> [V02Row] {
        var rows = V02Fixture.rows
        if phase == .added { rows.append(("A", "A-003", "item", "delta", "A-root", [])) }
        return rows.map { row in
            let key = V02RecordKey(recordName: "cloudkit.zoneshare", zoneName: "zone-" + row.graph, zoneOwnerDigest: "opaque-owner")
            let share = V02ShareInfo(id: key, publicPermission: CKShare.ParticipantPermission.none.rawValue,
                currentUserRole: CKShare.ParticipantRole.owner.rawValue, currentUserPermission: CKShare.ParticipantPermission.readWrite.rawValue,
                currentUserAcceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue,
                participants: [V02Participant(role: CKShare.ParticipantRole.owner.rawValue, permission: CKShare.ParticipantPermission.readWrite.rawValue,
                    acceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue)])
            return V02Row(scope: .privateStore, graph: row.graph, node: row.node, kind: row.kind,
                value: phase != .original && row.node == "A-001" ? V01MembershipFixture.updatedValue : row.value,
                parent: row.parent, children: row.children + (phase == .added && row.node == "A-root" ? ["A-003"] : []),
                validClosure: true, record: V02RecordKey(recordName: "record-" + row.node, zoneName: key.zoneName, zoneOwnerDigest: key.zoneOwnerDigest), share: share)
        }.sorted { ($0.node ?? "") < ($1.node ?? "") }
    }
}

@MainActor
private final class FakeMembershipStore: V01MembershipStoreAccess {
    var rows: [V02Row]
    var afterAdd: [V02Row] = []
    var failAdd = false
    var inspectMutation: (() throws -> Void)?
    var opens = 0, inserts = 0, adds = 0, deletes = 0
    var createdShares: [String] = []
    var closed = false
    var directory: URL?
    var fresh: Bool?
    private let identifier: String
    init(rows: [V02Row], identifier: String = "writer-store") { self.rows = rows; self.identifier = identifier }
    var inventory: [String: String] { ["private": identifier] }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws {
        opens += 1; self.directory = directory; self.fresh = fresh
    }
    func insertFixture(runID: UUID) async throws { inserts += 1 }
    func createShare(graph: String, runID: UUID, checkpoint: () throws -> Void) async throws { createdShares.append(graph); try checkpoint() }
    func addMembershipChild(runID: UUID) async throws {
        adds += 1; try inspectMutation?()
        if failAdd { throw V02Error.invalidFixture }
        rows = afterAdd
    }
    func deleteMembershipChild(runID: UUID) async throws { deletes += 1 }
    func snapshot(runID: UUID) async throws -> [V02Row] { rows }
    func close() async throws { closed = true }
}
