import XCTest
import CoreData
import CloudKit
@testable import GraphEvoDemo

@MainActor
final class V02RevocationTests: XCTestCase {
    private let user = CKRecord.ID(recordName: "test-user")

    func testCaseCLIAndTransitionRejectFreshAbsenceOrAReplacementStore() {
        let common = ["--v02-development-verified", "--v02-run-id", UUID().uuidString, "--v02-case-id", UUID().uuidString]
        for role in V02RevocationRole.allCases {
            let args = common + ["--v02-revocation-role", role.rawValue]
            XCTAssertEqual(V02RevocationRequest.parse(args)?.role, role)
            XCTAssertNil(V02Request.parse(args))
            XCTAssertNil(V02RevocationRequest.parse(args.filter { $0 != "--v02-development-verified" }))
        }
        XCTAssertFalse(V02RevocationFixture.removal(before: [], after: [], sameStores: true))
        XCTAssertFalse(V02RevocationFixture.removal(before: rows(owner: false), after: [], sameStores: false))
        XCTAssertTrue(V02RevocationFixture.removal(before: rows(owner: false), after: [], sameStores: true))
        XCTAssertFalse(V02RevocationFixture.removal(before: rows(owner: false), after: rows(owner: false), sameStores: true))
        XCTAssertTrue(V02RevocationFixture.ownerAfter(rows(owner: true, revoked: true), original: rows(owner: true)))
        XCTAssertFalse(V02RevocationFixture.ownerAfter(Array(rows(owner: true, revoked: true).dropLast()), original: rows(owner: true)))
    }

    func testLiveWatchCapturesBaselineAndHistoryBeforeReadyAndStaysOnOriginalOpenStores() async throws {
        let root = temporaryRoot(), originalRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: originalRoot) }
        let run = UUID(), id = UUID()
        try binding(originalRoot, run: run, owner: false)
        let fake = FakeRevocationStore(rows: rows(owner: false))
        fake.historyUnavailable = true
        var time = Date(timeIntervalSince1970: 10), sleeps = 0
        var session: V02RevocationSession!
        session = makeSession(root, originalRoot: originalRoot, fake: fake, now: { time }, sleep: {
            XCTAssertTrue(session.report?.readyForOwnerAction == true)
            XCTAssertEqual(session.report?.knownObjects.count, 3)
            XCTAssertEqual(fake.historyAnchors, 1)
            XCTAssertFalse(fake.closed)
            sleeps += 1; fake.rows = []; time.addTimeInterval(2)
        })
        await session.run(request(.watch, run: run, id: id, window: 6), container: "test")
        XCTAssertEqual(sleeps, 3)
        XCTAssertEqual(fake.opens, 1)
        XCTAssertFalse(fake.fresh ?? true)
        XCTAssertEqual(fake.directory, originalRoot.appendingPathComponent("Stores/\(run)/participant"))
        XCTAssertEqual(fake.revokes, 0)
        XCTAssertTrue(session.report?.removalObserved == true)
        XCTAssertEqual(session.report?.before.count, 3)
        XCTAssertTrue(session.report?.members.isEmpty == true)
        XCTAssertNotNil(session.report?.firstAbsenceAt)
        XCTAssertFalse(session.report?.history?.available ?? true)
        XCTAssertTrue(session.report?.outcome.hasPrefix("Observed complete A") == true)
        XCTAssertTrue(fake.closed)
        let repeatWatch = FakeRevocationStore(rows: rows(owner: false))
        await makeSession(root, originalRoot: originalRoot, fake: repeatWatch).run(request(.watch, run: run, id: id), container: "test")
        XCTAssertEqual(repeatWatch.opens, 0)
    }

    func testInitiallyAbsentParticipantCannotPublishReadyOrClaimLiveRevocation() async throws {
        let root = temporaryRoot(), originalRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: originalRoot) }
        let run = UUID()
        try binding(originalRoot, run: run, owner: false)
        let fake = FakeRevocationStore(rows: [])
        var time = Date(timeIntervalSince1970: 10)
        let session = makeSession(root, originalRoot: originalRoot, fake: fake, now: { time }, sleep: { time.addTimeInterval(2) })
        await session.run(request(.watch, run: run, id: UUID(), window: 4), container: "test")
        XCTAssertFalse(session.report?.readyForOwnerAction ?? true)
        XCTAssertFalse(session.report?.removalObserved ?? true)
        XCTAssertEqual(fake.historyAnchors, 0)
        XCTAssertEqual(fake.revokes, 0)
    }

    func testOwnerRemovesOncePreservesObjectsAndVerificationDoesNotRepeatRemoval() async throws {
        let root = temporaryRoot(), originalRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: originalRoot) }
        let run = UUID(), id = UUID()
        try binding(originalRoot, run: run, owner: true)
        try V02SensitiveFiles.write(V02Envelope(purpose: "private-invitation", runID: run, containerIdentifier: "test", account: V02PrivateID(user),
            recipient: V02PrivateID(CKRecord.ID(recordName: "participant"))), to: originalRoot.appendingPathComponent("Sensitive/\(run)/private-invitation.json"))
        let fake = FakeRevocationStore(rows: rows(owner: true))
        fake.afterRevoke = rows(owner: true, revoked: true)
        fake.inspectRevoke = {
            let url = root.appendingPathComponent("State/\(run)-\(id).json")
            let state = try JSONDecoder().decode(V02RevocationState.self, from: Data(contentsOf: url))
            XCTAssertFalse(state.revokeCompleted)
            XCTAssertEqual(state.originalOwner.count, 5)
        }
        let session = makeSession(root, originalRoot: originalRoot, fake: fake)
        await session.run(request(.revoke, run: run, id: id), container: "test")
        XCTAssertEqual(fake.revokes, 1)
        XCTAssertTrue(session.report?.revokeAPIReturned == true)
        XCTAssertTrue(session.report?.ownerPreserved == true)
        XCTAssertEqual(session.report?.members.count, 5)
        let verify = FakeRevocationStore(rows: fake.afterRevoke)
        let second = makeSession(root, originalRoot: originalRoot, fake: verify)
        await second.run(request(.verify, run: run, id: id), container: "test")
        XCTAssertEqual(verify.revokes, 0)
        XCTAssertTrue(second.report?.ownerPreserved == true)
        let replay = FakeRevocationStore(rows: rows(owner: true))
        await makeSession(root, originalRoot: originalRoot, fake: replay).run(request(.revoke, run: run, id: id), container: "test")
        XCTAssertEqual(replay.opens, 0)
        XCTAssertEqual(replay.revokes, 0)
    }

    func testLocalHistoryRetainsBaselineTokenAndReportsWatchedDeletionWithoutCloudClaim() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        try localSharedWrite(root, run: run, deleting: false)
        let stack = V02CloudStore(currentUser: user, localOnly: true)
        try await stack.open(directory: root, container: "test", fresh: false, event: { _ in })
        let objects = try await stack.captureWatchedObjects(runID: run)
        XCTAssertEqual(objects.count, 3)
        let anchored = try await stack.captureRevocationHistoryAnchor()
        XCTAssertTrue(anchored)
        try localSharedWrite(root, run: run, deleting: true)
        let history = try await stack.revocationHistory(since: Date.distantPast, watchedURIs: objects.map(\.objectURI))
        XCTAssertTrue(history.available)
        XCTAssertEqual(history.watchedDeletes, 3)
        XCTAssertEqual(Set(history.watchedDeletedURIs), Set(objects.map(\.objectURI)))
        XCTAssertFalse(history.truncated)
        try await stack.close()
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func request(_ role: V02RevocationRole, run: UUID, id: UUID, window: Int = 0) -> V02RevocationRequest {
        V02RevocationRequest(role: role, runID: run, caseID: id, window: window)
    }
    private func makeSession(_ root: URL, originalRoot: URL, fake: FakeRevocationStore,
                             now: @escaping @MainActor @Sendable () -> Date = { Date() },
                             sleep: @escaping @MainActor @Sendable () async throws -> Void = {}) -> V02RevocationSession {
        V02RevocationSession(root: root, originalRoot: originalRoot, permitSimulatorForTests: true, account: { _ in self.user }, makeStore: { _, _ in fake }, now: now, sleep: sleep)
    }
    private func binding(_ root: URL, run: UUID, owner: Bool) throws {
        try V02SensitiveFiles.write(V02Envelope(purpose: "account-binding", runID: run, containerIdentifier: "test", account: V02PrivateID(user)),
            to: root.appendingPathComponent("Sensitive/\(run)/\(owner ? "owner" : "participant")-binding.json"))
    }
    private func rows(owner: Bool, revoked: Bool = false) -> [V02Row] {
        V02Fixture.rows.filter { owner || $0.graph == "A" }.map { row in
            let key = V02RecordKey(recordName: "cloudkit.zoneshare", zoneName: "zone-" + row.graph, zoneOwnerDigest: "opaque-owner")
            var people = [V02Participant(role: CKShare.ParticipantRole.owner.rawValue, permission: CKShare.ParticipantPermission.readWrite.rawValue, acceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue)]
            if row.graph == "A" && !revoked { people.append(V02Participant(role: CKShare.ParticipantRole.privateUser.rawValue, permission: CKShare.ParticipantPermission.readOnly.rawValue, acceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue)) }
            let share = V02ShareInfo(id: key, publicPermission: CKShare.ParticipantPermission.none.rawValue,
                currentUserRole: (owner ? CKShare.ParticipantRole.owner : .privateUser).rawValue,
                currentUserPermission: (owner ? CKShare.ParticipantPermission.readWrite : .readOnly).rawValue,
                currentUserAcceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue, participants: people)
            return V02Row(scope: owner ? .privateStore : .sharedStore, graph: row.graph, node: row.node, kind: row.kind,
                value: row.node == "A-001" ? V02Fixture.editedValue : row.value, parent: row.parent, children: row.children, validClosure: true,
                record: V02RecordKey(recordName: "record-" + row.node, zoneName: key.zoneName, zoneOwnerDigest: key.zoneOwnerDigest), share: share)
        }
    }
    private func localSharedWrite(_ directory: URL, run: UUID, deleting: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: V01OwnerOnlyShareTrial.model())
        let options: [AnyHashable: Any] = [NSPersistentHistoryTrackingKey: true, NSPersistentStoreRemoteChangeNotificationPostOptionKey: true]
        let privateStore = try coordinator.addPersistentStore(type: .sqlite, at: directory.appendingPathComponent("private.sqlite"), options: options)
        let shared = try coordinator.addPersistentStore(type: .sqlite, at: directory.appendingPathComponent("shared.sqlite"), options: options)
        defer { try? coordinator.remove(shared); try? coordinator.remove(privateStore) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        if deleting {
            let request = NSFetchRequest<NSManagedObject>(entityName: "V01T6Member")
            request.predicate = NSPredicate(format: "runID == %@", run.uuidString); request.affectedStores = [shared]
            try context.fetch(request).forEach(context.delete)
        } else {
            for row in V02Fixture.rows where row.graph == "A" {
                let object = NSEntityDescription.insertNewObject(forEntityName: "V01T6Member", into: context)
                context.assign(object, to: shared)
                object.setValue(run.uuidString, forKey: "runID"); object.setValue(row.node, forKey: "node")
            }
        }
        try context.save(); context.reset()
    }
}

@MainActor
private final class FakeRevocationStore: V02RevocationStoreAccess {
    var rows: [V02Row]
    var afterRevoke: [V02Row] = []
    var opens = 0, revokes = 0, historyAnchors = 0
    var fresh: Bool?
    var directory: URL?
    var closed = false
    var historyUnavailable = false
    var inspectRevoke: (() throws -> Void)?
    init(rows: [V02Row]) { self.rows = rows }
    var inventory: [String: String] { ["private": "original-private", "shared": "original-shared"] }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws {
        opens += 1; self.fresh = fresh; self.directory = directory
    }
    func snapshot(runID: UUID) async throws -> [V02Row] { rows }
    func revokeParticipant(runID: UUID, recipient: V02PrivateID, checkpoint: () throws -> Void) async throws {
        revokes += 1; try inspectRevoke?(); try checkpoint(); rows = afterRevoke
    }
    func captureWatchedObjects(runID: UUID) async throws -> [V02RevocationObject] {
        rows.map { V02RevocationObject(node: $0.node, objectURI: "test-uri-" + ($0.node ?? "")) }
    }
    func captureRevocationHistoryAnchor() async throws -> Bool { historyAnchors += 1; return !historyUnavailable }
    func revocationHistory(since: Date, watchedURIs: [String]) async throws -> V02RevocationHistory {
        V02RevocationHistory(available: !historyUnavailable, transactions: 0, truncated: false, watchedInserts: 0,
            watchedUpdates: 0, watchedDeletes: 0, watchedDeletedURIs: [], error: historyUnavailable ? "Unavailable" : nil)
    }
    func close() async throws { closed = true }
}
