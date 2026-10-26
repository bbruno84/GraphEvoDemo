import XCTest
import CoreData
import CloudKit
@testable import GraphEvoDemo

@MainActor
final class V02Tests: XCTestCase {
    private let user = CKRecord.ID(recordName: "sensitive-participant-identity")

    func testCLISeparatesInvitationAuthorizationAndRejectsSecretArgumentsOrTraversal() {
        let id = UUID().uuidString
        let common = ["--v02-development-verified", "--v02-run-id", id]
        for role in V02Role.allCases {
            var args = common + ["--v02-role", role.rawValue]
            if role == .ownerInvite || role == .participantAccept { args += ["--v02-input", "input.json"] }
            if role == .ownerInvite {
                XCTAssertNil(V02Request.parse(args))
                args += ["--v02-invitation-authorized"]
            }
            XCTAssertEqual(V02Request.parse(args)?.role, role)
            XCTAssertNil(V02Request.parse(args.filter { $0 != "--v02-development-verified" }))
            XCTAssertNil(V01LaunchRequest.parse(args))
        }
        for name in ["../secret.json", "/secret.json", "https://www.icloud.com/share/secret", "foo/secret.json", "..json"] {
            XCTAssertFalse(V02Request.validFilename(name))
        }
        XCTAssertNil(V02Request.parse(common + ["--v02-role", "identity", "--v02-window", "0"]))
        XCTAssertNil(V02Request.parse(common + ["--v02-role", "identity", "--v02-window", "601"]))
    }

    func testPrivateAndSharedDescriptionsUseOneResourceWithDifferentScopes() throws {
        let descriptions = V02CloudStore.descriptions(directory: URL(fileURLWithPath: "/unused"), container: "iCloud.example.test")
        XCTAssertEqual(descriptions.count, 2)
        XCTAssertNotEqual(descriptions[0].url, descriptions[1].url)
        XCTAssertEqual(descriptions.map { $0.cloudKitContainerOptions?.databaseScope }, [.private, .shared])
        XCTAssertTrue(descriptions.allSatisfy { $0.cloudKitContainerOptions?.containerIdentifier == "iCloud.example.test" && !$0.shouldMigrateStoreAutomatically })
        XCTAssertNoThrow(try V01CloudStore.validateCloudDestinations(descriptions))
    }

    func testCrossAccountShareIDResolvesDefaultOwnerAgainstOwnerRatherThanRecipient() {
        let owner = CKRecord.ID(recordName: "owner")
        let defaultID = CKRecord.ID(recordName: "cloudkit.zoneshare", zoneID: CKRecordZone.ID(zoneName: "A", ownerName: CKCurrentUserDefaultName))
        let namedID = CKRecord.ID(recordName: "cloudkit.zoneshare", zoneID: CKRecordZone.ID(zoneName: "A", ownerName: "owner"))
        let wrong = CKRecord.ID(recordName: "cloudkit.zoneshare", zoneID: CKRecordZone.ID(zoneName: "A", ownerName: "someone-else"))
        XCTAssertTrue(V02PrivateID(defaultID).matches(namedID, shareOwner: owner))
        XCTAssertFalse(V02PrivateID(defaultID).matches(namedID, shareOwner: user))
        XCTAssertFalse(V02PrivateID(defaultID).matches(wrong, shareOwner: owner))
        let run = UUID()
        XCTAssertEqual(V02RecordKey.make(defaultID, currentUser: owner, runID: run), V02RecordKey.make(namedID, currentUser: user, runID: run))
        XCTAssertNotEqual(V02RecordKey.make(wrong, currentUser: user, runID: run), V02RecordKey.make(namedID, currentUser: user, runID: run))
    }

    func testScopeValuesPermissionsAndCompleteMultisetAreRequired() {
        let participant = fixture(owner: false)
        XCTAssertTrue(V02Fixture.exact(participant, owner: false, edited: false))
        XCTAssertFalse(V02Fixture.exact(participant, owner: true, edited: false))
        XCTAssertFalse(V02Fixture.exact(participant, owner: false, edited: true))
        XCTAssertFalse(V02Fixture.exact(Array(participant.dropLast()), owner: false, edited: false))
        XCTAssertFalse(V02Fixture.exact(participant + [participant[0]], owner: false, edited: false))
        XCTAssertFalse(V02Fixture.exact(fixture(owner: false, forceScope: .privateStore), owner: false, edited: false))
        XCTAssertFalse(V02Fixture.exact(participant + fixture(owner: true).filter { $0.graph == "B" }, owner: false, edited: false))
        XCTAssertFalse(V02Fixture.exact(fixture(owner: false, accepted: false), owner: false, edited: false))
        XCTAssertFalse(V02Fixture.exact(fixture(owner: false, permission: .readOnly), owner: false, edited: false))
        XCTAssertTrue(V02Fixture.prepared(fixture(owner: true, invited: false), invited: false))
        XCTAssertFalse(V02Fixture.exact(fixture(owner: true, invited: false), owner: true, edited: false))
        XCTAssertTrue(V02Fixture.prepared(fixture(owner: true, accepted: false), invited: true))
    }

    func testRealSQLiteRoutingReopenAndParticipantEditWithoutReplay() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("owner")
        let run = UUID()
        let store = V02CloudStore(currentUser: user, localOnly: true)
        try await store.open(directory: directory, container: "test", fresh: true, event: { _ in })
        try await store.insertFixture(runID: run)
        let first = try await store.snapshot(runID: run)
        XCTAssertTrue(V02Fixture.exact(first, owner: true, edited: false, requireShares: false))
        XCTAssertTrue(first.allSatisfy { $0.scope == .privateStore })
        let identifiers = store.inventory
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertNotEqual(identifiers["private"], identifiers["shared"])
        let unrelated = try await store.snapshot(runID: UUID())
        XCTAssertTrue(unrelated.isEmpty)
        do { try await store.insertFixture(runID: run); XCTFail("Must not duplicate a run") } catch {}
        do { try await store.edit(runID: run); XCTFail("An owner-private copy is not a participant edit target") } catch {}
        try await store.close()
        let reopened = V02CloudStore(currentUser: user, localOnly: true)
        try await reopened.open(directory: directory, container: "test", fresh: false, event: { _ in })
        XCTAssertEqual(reopened.inventory, identifiers)
        let after = try await reopened.snapshot(runID: run)
        XCTAssertEqual(first, after)
        try await reopened.close()

        // Seed only the test shared store through a local coordinator, never through a cloud owner.
        let participantDirectory = root.appendingPathComponent("participant")
        try seedSharedFixture(directory: participantDirectory, runID: run)
        let participant = V02CloudStore(currentUser: user, localOnly: true)
        try await participant.open(directory: participantDirectory, container: "test", fresh: false, event: { _ in })
        try await participant.edit(runID: run)
        let edited = try await participant.snapshot(runID: run)
        XCTAssertTrue(V02Fixture.exact(edited, owner: false, edited: true, requireShares: false))
        do { try await participant.edit(runID: run); XCTFail("An edit must not be replayed") } catch {}
        try await participant.close()
        let participantReopen = V02CloudStore(currentUser: user, localOnly: true)
        try await participantReopen.open(directory: participantDirectory, container: "test", fresh: false, event: { _ in })
        let retained = try await participantReopen.snapshot(runID: run)
        XCTAssertEqual(retained, edited)
        try await participantReopen.close()
    }

    func testIdentityExportDoesNotOpenStoresAndNeverLeaksToReport() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        var madeStore = false
        let session = V02Session(root: root, permitSimulatorForTests: true, account: { _ in self.user }, makeStore: { _, _ in
            madeStore = true
            return FakeV02Store()
        })
        await session.run(request(.identity, run: run), container: "test")
        XCTAssertFalse(madeStore)
        XCTAssertTrue(session.report?.finalReportRetained == true)
        let data = try Data(contentsOf: XCTUnwrap(session.reportURL))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(user.recordName))
        let secret = root.appendingPathComponent("Sensitive/\(run)/participant-identity.json")
        let identity = try V02SensitiveFiles.read(secret)
        XCTAssertEqual(identity.account.recordID, user)
        XCTAssertThrowsError(try identity.validate(runID: UUID(), container: "test", purpose: "participant-identity"))
        XCTAssertThrowsError(try identity.validate(runID: run, container: "other", purpose: "participant-identity"))
        XCTAssertThrowsError(try identity.validate(runID: run, container: "test", purpose: "private-invitation"))
        let retainedBytes = try Data(contentsOf: secret)
        XCTAssertThrowsError(try V02SensitiveFiles.write(identity, to: secret))
        XCTAssertEqual(try Data(contentsOf: secret), retainedBytes)
    }

    func testParticipantAcceptanceHasEmptyBaselineNoInsertsAndConservativeIncompleteResult() async throws {
        for complete in [true, false] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let run = UUID()
            let fake = FakeV02Store()
            fake.afterAccept = complete ? fixture(owner: false) : Array(fixture(owner: false).dropLast())
            try input(root, run: run)
            let session = session(root, fake: fake)
            await session.run(request(.participantAccept, run: run, input: "input.json"), container: "test")
            XCTAssertEqual(fake.accepts, 1)
            XCTAssertEqual(fake.inserts, 0)
            XCTAssertTrue(fake.shares.isEmpty)
            XCTAssertTrue(fake.fresh == true)
            XCTAssertTrue(fake.closed)
            XCTAssertTrue(session.report?.baseline.isEmpty == true)
            XCTAssertEqual(session.report?.exactObservation, complete)
        }
    }

    func testParticipantEditKeepsOwnerAliveForFullWindowDespiteExactLocalSnapshot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        let fake = FakeV02Store()
        fake.rows = fixture(owner: false)
        fake.afterEdit = fixture(owner: false, edited: true)
        try binding(root, run: run, owner: false)
        var clock = Date(timeIntervalSince1970: 100)
        var sleeps = 0
        let session = V02Session(root: root, permitSimulatorForTests: true, account: { _ in self.user }, makeStore: { _, _ in fake },
            now: { clock }, sampleSleep: {
                XCTAssertFalse(fake.closed)
                sleeps += 1; clock.addTimeInterval(2)
            })
        await session.run(request(.participantEdit, run: run, window: 6), container: "test")
        XCTAssertEqual(sleeps, 3)
        XCTAssertEqual(fake.edits, 1)
        XCTAssertFalse(fake.fresh ?? true)
        XCTAssertTrue(fake.closed)
        XCTAssertTrue(session.report?.participantEditSaved == true)
        XCTAssertTrue(session.report?.exactObservation == true)
        await session.run(request(.participantEdit, run: run), container: "test")
        XCTAssertEqual(fake.edits, 1)
    }

    func testOwnerPreparationGatesShareBOnShareAFailureAndRetainsCheckpoint() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        let fake = FakeV02Store()
        fake.afterInsert = fixture(owner: true, invited: false)
        fake.failShareA = true
        let session = session(root, fake: fake)
        fake.inspectCheckpoint = {
            let data = try Data(contentsOf: XCTUnwrap(session.reportURL))
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Creating owner-only share for A"))
        }
        await session.run(request(.ownerPrepare, run: run), container: "test")
        XCTAssertEqual(fake.shares, ["A"])
        XCTAssertEqual(fake.inserts, 1)
        XCTAssertFalse(session.report?.errors.isEmpty ?? true)
        XCTAssertTrue(fake.closed)
    }

    func testReopenNeverCreatesMissingStoresOrRepeatsFixtureInvitationOrAcceptance() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        let fake = FakeV02Store()
        fake.rows = fixture(owner: true, edited: true)
        try binding(root, run: run, owner: true)
        let session = session(root, fake: fake)
        await session.run(request(.ownerReopen, run: run), container: "test")
        XCTAssertFalse(fake.fresh ?? true)
        XCTAssertEqual(fake.inserts + fake.accepts + fake.invites + fake.edits, 0)
        XCTAssertTrue(fake.shares.isEmpty)
        XCTAssertTrue(session.report?.exactObservation == true)
        let concrete = V02CloudStore(currentUser: user, localOnly: true)
        do { try await concrete.open(directory: root.appendingPathComponent("missing"), container: "test", fresh: false, event: { _ in }); XCTFail("Do not allocate a fresh replacement") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path)) }
    }

    func testUnauthorizedInviteAndAccountMismatchNeverReachInvitationAPI() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        try binding(root, run: run, owner: true)
        let fake = FakeV02Store()
        let session = session(root, fake: fake)
        await session.run(request(.ownerInvite, run: run, input: "input.json"), container: "test")
        XCTAssertEqual(fake.invites, 0)
        XCTAssertFalse(session.report?.errors.isEmpty ?? true)
        let other = V02Session(root: root, permitSimulatorForTests: true, account: { _ in CKRecord.ID(recordName: "another-account") }, makeStore: { _, _ in XCTFail("Must reject binding before opening"); return fake })
        await other.run(request(.ownerReopen, run: run), container: "test")
        XCTAssertFalse(other.report?.errors.isEmpty ?? true)
    }

    private func request(_ role: V02Role, run: UUID, input: String? = nil, window: Int = 0) -> V02Request {
        V02Request(role: role, runID: run, window: window, input: input, invitationAuthorized: false)
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func session(_ root: URL, fake: FakeV02Store) -> V02Session {
        V02Session(root: root, permitSimulatorForTests: true, account: { _ in self.user }, makeStore: { _, _ in fake })
    }
    private func binding(_ root: URL, run: UUID, owner: Bool) throws {
        try V02SensitiveFiles.write(V02Envelope(purpose: "account-binding", runID: run, containerIdentifier: "test", account: V02PrivateID(user)),
            to: root.appendingPathComponent("Sensitive/\(run)/\(owner ? "owner" : "participant")-binding.json"))
    }
    private func input(_ root: URL, run: UUID) throws {
        try V02SensitiveFiles.write(V02Envelope(purpose: "private-invitation", runID: run, containerIdentifier: "test", account: V02PrivateID(user)),
            to: root.appendingPathComponent("Inbox/input.json"))
    }
    private func seedSharedFixture(directory: URL, runID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: V01OwnerOnlyShareTrial.model())
        let privateStore = try coordinator.addPersistentStore(type: .sqlite, at: directory.appendingPathComponent("private.sqlite"))
        let sharedStore = try coordinator.addPersistentStore(type: .sqlite, at: directory.appendingPathComponent("shared.sqlite"))
        defer { try? coordinator.remove(privateStore); try? coordinator.remove(sharedStore) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var objects: [String: NSManagedObject] = [:]
        for row in V02Fixture.rows where row.graph == "A" {
            let object = NSEntityDescription.insertNewObject(forEntityName: "V01T6Member", into: context)
            context.assign(object, to: sharedStore)
            for (key, value) in ["runID": runID.uuidString, "graph": row.graph, "node": row.node, "kind": row.kind, "value": row.value] { object.setValue(value, forKey: key) }
            objects[row.node] = object
        }
        objects["A-001"]?.setValue(objects["A-root"], forKey: "parent")
        objects["A-002"]?.setValue(objects["A-root"], forKey: "parent")
        try context.save(); context.reset()
    }

    private func fixture(owner: Bool, edited: Bool = false, invited: Bool = true, accepted: Bool = true,
                         permission: CKShare.ParticipantPermission = .readWrite, forceScope: V02Scope? = nil) -> [V02Row] {
        V02Fixture.rows.filter { owner || $0.graph == "A" }.map { row in
            let id = V02RecordKey(recordName: "cloudkit.zoneshare", zoneName: "zone-" + row.graph, zoneOwnerDigest: "opaque-owner")
            var participants = [V02Participant(role: CKShare.ParticipantRole.owner.rawValue, permission: CKShare.ParticipantPermission.readWrite.rawValue, acceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue)]
            if row.graph == "A" && invited { participants.append(V02Participant(role: CKShare.ParticipantRole.privateUser.rawValue, permission: permission.rawValue,
                acceptance: accepted ? CKShare.ParticipantAcceptanceStatus.accepted.rawValue : CKShare.ParticipantAcceptanceStatus.pending.rawValue)) }
            let share = V02ShareInfo(id: id, publicPermission: CKShare.ParticipantPermission.none.rawValue,
                currentUserRole: (owner ? CKShare.ParticipantRole.owner : .privateUser).rawValue, currentUserPermission: permission.rawValue,
                currentUserAcceptance: (accepted ? CKShare.ParticipantAcceptanceStatus.accepted : .pending).rawValue, participants: participants)
            return V02Row(scope: forceScope ?? (owner ? .privateStore : .sharedStore), graph: row.graph, node: row.node, kind: row.kind,
                value: edited && row.node == "A-001" ? V02Fixture.editedValue : row.value, parent: row.parent, children: row.children,
                validClosure: true, record: V02RecordKey(recordName: "record-" + row.node, zoneName: id.zoneName, zoneOwnerDigest: id.zoneOwnerDigest), share: share)
        }
    }
}

@MainActor
private final class FakeV02Store: V02StoreAccess {
    var rows: [V02Row] = []
    var afterInsert: [V02Row] = []
    var afterAccept: [V02Row] = []
    var afterEdit: [V02Row] = []
    var fresh: Bool?
    var closed = false
    var inserts = 0, accepts = 0, invites = 0, edits = 0
    var shares: [String] = []
    var failShareA = false
    var inspectCheckpoint: (() throws -> Void)?
    var inventory: [String: String] { ["private": "test-private", "shared": "test-shared"] }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws { self.fresh = fresh }
    func insertFixture(runID: UUID) async throws { inserts += 1; rows = afterInsert }
    func createShare(graph: String, runID: UUID, checkpoint: () throws -> Void) async throws {
        shares.append(graph); try checkpoint(); try inspectCheckpoint?()
        if failShareA { throw V02Error.invalidShare }
    }
    func invite(_ identity: V02Envelope, runID: UUID, container: String, checkpoint: () throws -> Void) async throws -> V02Envelope {
        invites += 1; try checkpoint(); return identity
    }
    func accept(_ invitation: V02Envelope, runID: UUID, container: String, checkpoint: () throws -> Void) async throws { accepts += 1; try checkpoint(); rows = afterAccept }
    func snapshot(runID: UUID) async throws -> [V02Row] { rows }
    func edit(runID: UUID) async throws { edits += 1; rows = afterEdit }
    func close() async throws { closed = true }
}
