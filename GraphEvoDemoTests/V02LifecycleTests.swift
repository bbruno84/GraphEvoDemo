import XCTest
import CloudKit
@testable import GraphEvoDemo

@MainActor
final class V02LifecycleTests: XCTestCase {
    private let owner = CKRecord.ID(recordName: "test-owner")
    private let participant = CKRecord.ID(recordName: "test-participant")

    func testCLIRequiresCaseAndSafeReacceptInputAndOldEnvelopesRemainReadable() throws {
        let common = ["--v02-development-verified", "--v02-run-id", UUID().uuidString, "--v02-case-id", UUID().uuidString]
        for role in V02LifecycleRole.allCases {
            var args = common + ["--v02-lifecycle-role", role.rawValue]
            if role == .reaccept {
                XCTAssertNil(V02LifecycleRequest.parse(args))
                XCTAssertNil(V02LifecycleRequest.parse(args + ["--v02-input", "../invitation.json"]))
                args += ["--v02-input", "invitation.json"]
            }
            XCTAssertEqual(V02LifecycleRequest.parse(args)?.role, role)
            XCTAssertNil(V02Request.parse(args))
            XCTAssertNil(V02LifecycleRequest.parse(args.filter { $0 != "--v02-development-verified" }))
        }
        let envelope = V02Envelope(purpose: "account-binding", runID: UUID(), containerIdentifier: "test", account: V02PrivateID(owner))
        let decoded = try JSONDecoder().decode(V02Envelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertNil(decoded.caseID)
    }

    func testLeaveRequiresExactKnownParticipantFixtureAndSharedScope() {
        let run = UUID(), rows = rows(run, ownerSide: false, invited: true)
        let key = rows[0].share!.id
        XCTAssertTrue(V02LifecycleFixture.permitsLeave(rows, scope: .sharedStore, role: .privateUser, expectedShare: key))
        XCTAssertFalse(V02LifecycleFixture.permitsLeave(rows, scope: .privateStore, role: .privateUser, expectedShare: key))
        XCTAssertFalse(V02LifecycleFixture.permitsLeave(rows, scope: .sharedStore, role: .owner, expectedShare: key))
        XCTAssertFalse(V02LifecycleFixture.permitsLeave([], scope: .sharedStore, role: .privateUser, expectedShare: key))
        XCTAssertFalse(V02LifecycleFixture.permitsLeave(Array(rows.dropLast()), scope: .sharedStore, role: .privateUser, expectedShare: key))
        let wrong = V02RecordKey(recordName: key.recordName, zoneName: "wrong-zone", zoneOwnerDigest: key.zoneOwnerDigest)
        XCTAssertFalse(V02LifecycleFixture.permitsLeave(rows, scope: .sharedStore, role: .privateUser, expectedShare: wrong))
        let original = self.rows(run, ownerSide: true, invited: false)
        XCTAssertTrue(V02LifecycleFixture.owner(original, invited: false, original: original))
        XCTAssertFalse(V02LifecycleFixture.owner(Array(original.dropLast()), invited: false, original: original))
    }

    func testOwnerReinvitesOnceKeepsOriginalSensitiveArtifactAndVerifiesWithoutAnotherMutation() async throws {
        let root = temporaryRoot(), original = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: original) }
        let run = UUID(), id = UUID()
        try binding(original, run: run, ownerSide: true)
        let oldURL = original.appendingPathComponent("Sensitive/\(run)/private-invitation.json")
        var old = invitation(run, id: nil); old = V02Envelope(purpose: "private-invitation", runID: run, containerIdentifier: "test", account: old.account, recipient: old.recipient, share: old.share, shareURL: old.shareURL)
        try V02SensitiveFiles.write(old, to: oldURL)
        let oldBytes = try Data(contentsOf: oldURL)
        let fake = FakeLifecycleStore(rows: rows(run, ownerSide: true, invited: false))
        fake.afterOperation = rows(run, ownerSide: true, invited: true)
        fake.invitation = invitation(run, id: id)
        fake.inspectOperation = { XCTAssertEqual(try self.state(root, run: run, id: id).progress, .inviting) }
        let session = session(root, original: original, fake: fake, ownerSide: true)
        await session.run(request(.reinvite, run: run, id: id), container: "test")
        XCTAssertTrue(session.report?.errors.isEmpty == true)
        XCTAssertEqual(fake.invites, 1)
        XCTAssertTrue(session.report?.invitationPersisted == true)
        XCTAssertTrue(session.report?.ownerPreserved == true)
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        let output = try V02SensitiveFiles.read(root.appendingPathComponent("Sensitive/\(run)/\(id)/private-invitation.json"))
        XCTAssertEqual(output.caseID, id)
        XCTAssertEqual(try state(root, run: run, id: id).progress, .invited)
        let verifyStore = FakeLifecycleStore(rows: rows(run, ownerSide: true, invited: false))
        let verify = self.session(root, original: original, fake: verifyStore, ownerSide: true)
        await verify.run(request(.verify, run: run, id: id), container: "test")
        XCTAssertTrue(verify.report?.ownerPreserved == true)
        XCTAssertEqual(verifyStore.invites + verifyStore.accepts + verifyStore.leaves, 0)
        let replay = FakeLifecycleStore(rows: [])
        await self.session(root, original: original, fake: replay, ownerSide: true).run(request(.reinvite, run: run, id: id), container: "test")
        XCTAssertEqual(replay.opens, 0)
    }

    func testReacceptRecordsPendingVersusAlreadyAcceptedAndLeaveReservesBeforeOneCall() async throws {
        for accepted in [false, true] {
            let root = temporaryRoot(), original = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: original) }
            let run = UUID(), id = UUID(), envelope = invitation(run, id: UUID())
            var matching = envelope; matching.caseID = id
            try binding(original, run: run, ownerSide: false)
            try V02SensitiveFiles.write(matching, to: root.appendingPathComponent("Inbox/invitation.json"))
            let recovered = rows(run, ownerSide: false, invited: true)
            let fake = FakeLifecycleStore(rows: accepted ? recovered : [])
            fake.afterOperation = recovered; fake.alreadyAccepted = accepted
            fake.inspectOperation = { XCTAssertEqual(try self.state(root, run: run, id: id).progress, .accepting) }
            let accept = session(root, original: original, fake: fake, ownerSide: false)
            await accept.run(request(.reaccept, run: run, id: id), container: "test")
            XCTAssertTrue(accept.report?.errors.isEmpty == true)
            XCTAssertTrue(accept.report?.exactRecovery == true)
            XCTAssertEqual(accept.report?.initiallyAbsent, !accepted)
            XCTAssertEqual(accept.report?.reaccept?.acceptanceAPICalled, !accepted)
            XCTAssertEqual(accept.report?.reaccept?.alreadyAccepted, accepted)
            XCTAssertEqual(fake.directory, original.appendingPathComponent("Stores/\(run)/participant"))
            XCTAssertFalse(fake.fresh ?? true)
            let leaveStore = FakeLifecycleStore(rows: recovered)
            leaveStore.inspectOperation = { XCTAssertEqual(try self.state(root, run: run, id: id).progress, .leaving) }
            let leave = session(root, original: original, fake: leaveStore, ownerSide: false)
            await leave.run(request(.leave, run: run, id: id), container: "test")
            XCTAssertTrue(leave.report?.errors.isEmpty == true)
            XCTAssertEqual(leaveStore.leaves, 1)
            XCTAssertEqual(leave.report?.before.count, 3)
            XCTAssertEqual(leave.report?.purgeScope, "shared")
            XCTAssertTrue(leave.report?.absenceAfterKnownFixture == true)
            XCTAssertTrue(leave.report?.leaveAPIReturned == true)
            XCTAssertTrue(leave.report?.storesDetached == true)
            XCTAssertEqual(try state(root, run: run, id: id).progress, .left)
            let replay = FakeLifecycleStore(rows: recovered)
            await session(root, original: original, fake: replay, ownerSide: false).run(request(.leave, run: run, id: id), container: "test")
            XCTAssertEqual(replay.opens, 0)
            XCTAssertEqual(replay.leaves, 0)
        }
    }

    func testWrongCaseOrOriginalInvitationCannotReachAcceptance() async throws {
        for wrongPurpose in [false, true] {
            let root = temporaryRoot(), original = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: original) }
            let run = UUID(), id = UUID()
            try binding(original, run: run, ownerSide: false)
            let invalid = V02Envelope(purpose: wrongPurpose ? "private-invitation" : "lifecycle-invitation", runID: run,
                containerIdentifier: "test", account: V02PrivateID(owner), recipient: V02PrivateID(participant), caseID: wrongPurpose ? id : UUID())
            try V02SensitiveFiles.write(invalid, to: root.appendingPathComponent("Inbox/invitation.json"))
            let fake = FakeLifecycleStore(rows: [])
            let session = session(root, original: original, fake: fake, ownerSide: false)
            await session.run(request(.reaccept, run: run, id: id), container: "test")
            XCTAssertFalse(session.report?.errors.isEmpty ?? true)
            XCTAssertEqual(fake.accepts, 0)
            XCTAssertEqual(fake.leaves, 0)
        }
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func request(_ role: V02LifecycleRole, run: UUID, id: UUID) -> V02LifecycleRequest {
        V02LifecycleRequest(role: role, runID: run, caseID: id, window: 0, input: role == .reaccept ? "invitation.json" : nil)
    }
    private func session(_ root: URL, original: URL, fake: FakeLifecycleStore, ownerSide: Bool) -> V02LifecycleSession {
        V02LifecycleSession(root: root, originalRoot: original, permitSimulatorForTests: true,
            account: { _ in ownerSide ? self.owner : self.participant }, makeStore: { _, _ in fake })
    }
    private func binding(_ root: URL, run: UUID, ownerSide: Bool) throws {
        try V02SensitiveFiles.write(V02Envelope(purpose: "account-binding", runID: run, containerIdentifier: "test", account: V02PrivateID(ownerSide ? owner : participant)),
            to: root.appendingPathComponent("Sensitive/\(run)/\(ownerSide ? "owner" : "participant")-binding.json"))
    }
    private func state(_ root: URL, run: UUID, id: UUID) throws -> V02LifecycleState {
        try JSONDecoder().decode(V02LifecycleState.self, from: Data(contentsOf: root.appendingPathComponent("State/\(run)-\(id).json")))
    }
    private func invitation(_ run: UUID, id: UUID?) -> V02Envelope {
        V02Envelope(purpose: "lifecycle-invitation", runID: run, containerIdentifier: "test", account: V02PrivateID(owner), recipient: V02PrivateID(participant),
            share: V02PrivateID(CKRecord.ID(recordName: "cloudkit.zoneshare", zoneID: CKRecordZone.ID(zoneName: "zone-A", ownerName: owner.recordName))),
            shareURL: URL(string: "https://www.icloud.com/share/test"), caseID: id)
    }
    private func rows(_ run: UUID, ownerSide: Bool, invited: Bool) -> [V02Row] {
        V02Fixture.rows.filter { ownerSide || $0.graph == "A" }.map { row in
            let key = V02RecordKey.make(CKRecord.ID(recordName: "cloudkit.zoneshare", zoneID: CKRecordZone.ID(zoneName: "zone-" + row.graph, ownerName: owner.recordName)), currentUser: owner, runID: run)
            var people = [V02Participant(role: CKShare.ParticipantRole.owner.rawValue, permission: CKShare.ParticipantPermission.readWrite.rawValue, acceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue)]
            if row.graph == "A" && invited { people.append(V02Participant(role: CKShare.ParticipantRole.privateUser.rawValue, permission: CKShare.ParticipantPermission.readWrite.rawValue, acceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue)) }
            let share = V02ShareInfo(id: key, publicPermission: CKShare.ParticipantPermission.none.rawValue,
                currentUserRole: (ownerSide ? CKShare.ParticipantRole.owner : .privateUser).rawValue,
                currentUserPermission: CKShare.ParticipantPermission.readWrite.rawValue,
                currentUserAcceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue, participants: people)
            return V02Row(scope: ownerSide ? .privateStore : .sharedStore, graph: row.graph, node: row.node, kind: row.kind,
                value: row.node == "A-001" ? V02Fixture.editedValue : row.value, parent: row.parent, children: row.children, validClosure: true,
                record: V02RecordKey(recordName: "record-" + row.node, zoneName: key.zoneName, zoneOwnerDigest: key.zoneOwnerDigest), share: share)
        }
    }
}

@MainActor
private final class FakeLifecycleStore: V02LifecycleStoreAccess {
    var rows: [V02Row]
    var afterOperation: [V02Row] = []
    var invitation: V02Envelope?
    var alreadyAccepted = false
    var opens = 0, invites = 0, accepts = 0, leaves = 0
    var directory: URL?
    var fresh: Bool?
    var inspectOperation: (() throws -> Void)?
    init(rows: [V02Row]) { self.rows = rows }
    var inventory: [String: String] { ["private": "original-private", "shared": "original-shared"] }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws {
        opens += 1; self.directory = directory; self.fresh = fresh
    }
    func snapshot(runID: UUID) async throws -> [V02Row] { rows }
    func reinviteParticipant(runID: UUID, caseID: UUID, recipient: V02PrivateID, container: String, checkpoint: () throws -> Void) async throws -> V02Envelope {
        invites += 1; try inspectOperation?(); try checkpoint(); rows = afterOperation
        return invitation!
    }
    func reacceptInvitation(_ invitation: V02Envelope, runID: UUID, caseID: UUID, container: String, checkpoint: () throws -> Void) async throws -> V02ReacceptResult {
        accepts += 1; try inspectOperation?(); try checkpoint(); rows = afterOperation
        return V02ReacceptResult(metadataStatus: (alreadyAccepted ? CKShare.ParticipantAcceptanceStatus.accepted : .pending).rawValue,
            acceptanceAPICalled: !alreadyAccepted, alreadyAccepted: alreadyAccepted)
    }
    func leaveSharedA(_ invitation: V02Envelope, runID: UUID, caseID: UUID, container: String, checkpoint: () throws -> Void) async throws -> V02RecordKey? {
        leaves += 1; try inspectOperation?(); try checkpoint(); rows = afterOperation; return nil
    }
    func close() async throws {}
}
