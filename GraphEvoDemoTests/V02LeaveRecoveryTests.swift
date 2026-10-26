import XCTest
import CloudKit
@testable import GraphEvoDemo

@MainActor
final class V02LeaveRecoveryTests: XCTestCase {
    private let owner = CKRecord.ID(recordName: "recovery-owner")
    private let participant = CKRecord.ID(recordName: "recovery-participant")

    func testParserRequiresNewCaseAndPriorCaseAndKeepsExistingRoutesSeparate() {
        let run = UUID(), id = UUID(), prior = UUID()
        let common = ["--v02-development-verified", "--v02-run-id", run.uuidString, "--v02-case-id", id.uuidString, "--v02-prior-case-id", prior.uuidString]
        for role in V02LeaveRecoveryRole.allCases {
            let args = common + ["--v02-leave-recovery-role", role.rawValue]
            XCTAssertEqual(V02LeaveRecoveryRequest.parse(args)?.role, role)
            XCTAssertEqual(V02LeaveRecoveryRequest.parse(args)?.window, 180)
            XCTAssertNil(V02LifecycleRequest.parse(args))
            XCTAssertNil(V02Request.parse(args))
            XCTAssertNil(V02LeaveRecoveryRequest.parse(args + ["--v02-window", "0"]))
        }
        XCTAssertNil(V02LeaveRecoveryRequest.parse(["--v02-development-verified", "--v02-run-id", run.uuidString, "--v02-case-id", prior.uuidString, "--v02-prior-case-id", prior.uuidString, "--v02-leave-recovery-role", "participant-fresh"]))
    }

    func testEmptyFreshReplicaHoldsFullWindowRetainsPendingMetadataAndRejectsProbeReuse() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID(), id = UUID(), prior = UUID()
        try prerequisites(root, run: run, prior: prior, ownerSide: false)
        let fake = FakeLeaveRecoveryStore(rows: [])
        var time = Date(timeIntervalSince1970: 100), sleeps = 0
        let session = session(root, fake: fake, now: { time }, sleep: { time.addTimeInterval(2); sleeps += 1 })
        await session.run(request(.participant, run: run, id: id, prior: prior, window: 6), container: "test")
        XCTAssertTrue(session.report?.errors.isEmpty == true)
        XCTAssertEqual(sleeps, 3)
        XCTAssertEqual(fake.opens, 1)
        XCTAssertTrue(fake.fresh == true)
        XCTAssertEqual(fake.directory, root.appendingPathComponent("probe/Stores/\(run)/\(id)/participant-fresh"))
        XCTAssertEqual(fake.metadataReads, 2)
        XCTAssertTrue(session.report?.fullWindowObserved == true)
        XCTAssertNil(session.report?.firstRecoveryAt)
        XCTAssertEqual(session.report?.metadataBefore?.participantStatus, CKShare.ParticipantAcceptanceStatus.pending.rawValue)
        XCTAssertEqual(session.report?.sampleCount, 4)
        XCTAssertEqual(session.report?.emptySampleCount, 4)
        XCTAssertTrue(session.report?.outcome.hasPrefix("No exact A3") == true)
        XCTAssertTrue(session.report?.probePathPermanentlyConsumed == true)
        XCTAssertTrue(fake.closed)
        let repeated = FakeLeaveRecoveryStore(rows: [])
        await self.session(root, fake: repeated).run(request(.participant, run: run, id: id, prior: prior), container: "test")
        XCTAssertEqual(repeated.opens, 0)
        XCTAssertEqual(repeated.metadataReads, 0)
    }

    func testExactARecoveryDoesNotEndWindowAndMetadataErrorDoesNotMeanAccessDenial() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID(), id = UUID(), prior = UUID()
        try prerequisites(root, run: run, prior: prior, ownerSide: false)
        let fake = FakeLeaveRecoveryStore(rows: [])
        fake.metadataFailure = true
        var time = Date(timeIntervalSince1970: 100), sleeps = 0
        let recovered = rows(run, ownerSide: false)
        let session = session(root, fake: fake, now: { time }, sleep: {
            XCTAssertFalse(fake.closed)
            time.addTimeInterval(2); sleeps += 1; fake.rows = recovered
        })
        await session.run(request(.participant, run: run, id: id, prior: prior, window: 6), container: "test")
        XCTAssertEqual(sleeps, 3)
        XCTAssertTrue(session.report?.errors.isEmpty == true)
        XCTAssertEqual(session.report?.firstRecoveredRows, recovered)
        XCTAssertEqual(session.report?.firstRecoveryAt, Date(timeIntervalSince1970: 102))
        XCTAssertEqual(session.report?.metadataBefore?.errors.first?.code, CKError.Code.unknownItem.rawValue)
        XCTAssertFalse(session.report?.metadataBefore?.returnedMetadata ?? true)
        XCTAssertTrue(session.report?.outcome.hasPrefix("Exact prior A3 recovered") == true)
        XCTAssertFalse(session.report?.observedB ?? true)
        XCTAssertFalse(session.report?.observedPrivateCopy ?? true)
    }

    func testOwnerSnapshotRetainsPendingParticipantWithoutOwnerOnlyFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID(), id = UUID(), prior = UUID()
        try prerequisites(root, run: run, prior: prior, ownerSide: true)
        let fake = FakeLeaveRecoveryStore(rows: rows(run, ownerSide: true, pending: true))
        fake.storeIDs = ["private": "prior-private", "shared": "prior-shared"]
        let session = session(root, fake: fake, ownerSide: true)
        await session.run(request(.owner, run: run, id: id, prior: prior), container: "test")
        XCTAssertTrue(session.report?.errors.isEmpty == true)
        XCTAssertTrue(session.report?.ownerDataMatches == true)
        XCTAssertFalse(fake.fresh ?? true)
        XCTAssertEqual(fake.directory, root.appendingPathComponent("original/Stores/\(run)/owner"))
        let people = session.report?.members.first(where: { $0.graph == "A" })?.share?.participants
        XCTAssertEqual(people?.count, 2)
        XCTAssertEqual(people?.first(where: { $0.role == CKShare.ParticipantRole.privateUser.rawValue })?.acceptance, CKShare.ParticipantAcceptanceStatus.pending.rawValue)
        XCTAssertFalse(session.report?.probePathPermanentlyConsumed ?? true)
    }

    func testMissingCompletedLeaveCannotReadMetadataOrOpenFreshStoresAndErrorPayloadStaysPrivate() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID(), id = UUID(), prior = UUID()
        try prerequisites(root, run: run, prior: prior, ownerSide: false, progress: .recovered)
        let fake = FakeLeaveRecoveryStore(rows: [])
        let session = session(root, fake: fake)
        await session.run(request(.participant, run: run, id: id, prior: prior), container: "test")
        XCTAssertFalse(session.report?.errors.isEmpty ?? true)
        XCTAssertEqual(fake.opens, 0)
        XCTAssertEqual(fake.metadataReads, 0)
        let secret = "private-record-or-url"
        let error = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
            userInfo: [NSLocalizedDescriptionKey: secret, CKPartialErrorsByItemIDKey: [secret: NSError(domain: CKErrorDomain, code: CKError.Code.permissionFailure.rawValue)]])
        let codes = V02PublicReadError.capture(error)
        XCTAssertEqual(codes.count, 2)
        XCTAssertEqual(codes.last?.code, CKError.Code.permissionFailure.rawValue)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(codes), as: UTF8.self).contains(secret))
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func request(_ role: V02LeaveRecoveryRole, run: UUID, id: UUID, prior: UUID, window: Int = 0) -> V02LeaveRecoveryRequest {
        V02LeaveRecoveryRequest(role: role, runID: run, caseID: id, priorCaseID: prior, window: window)
    }
    private func session(_ root: URL, fake: FakeLeaveRecoveryStore, ownerSide: Bool = false,
                         now: @escaping @MainActor @Sendable () -> Date = { Date() }, sleep: @escaping @MainActor @Sendable () async throws -> Void = {}) -> V02LeaveRecoverySession {
        V02LeaveRecoverySession(root: root.appendingPathComponent("probe"), originalRoot: root.appendingPathComponent("original"),
            lifecycleRoot: root.appendingPathComponent("lifecycle"), permitSimulatorForTests: true,
            account: { _ in ownerSide ? self.owner : self.participant }, makeStore: { _, _ in fake }, now: now, sleep: sleep)
    }
    private func prerequisites(_ root: URL, run: UUID, prior: UUID, ownerSide: Bool, progress: V02LifecycleProgress? = nil) throws {
        let side = ownerSide ? "owner" : "participant"
        try V02SensitiveFiles.write(V02Envelope(purpose: "account-binding", runID: run, containerIdentifier: "test", account: V02PrivateID(ownerSide ? owner : participant)),
            to: root.appendingPathComponent("original/Sensitive/\(run)/\(side)-binding.json"))
        let state = V02LifecycleState(runID: run, caseID: prior, progress: progress ?? (ownerSide ? .invited : .left),
            stores: ["private": "prior-private", "shared": "prior-shared"], originalOwner: ownerSide ? rows(run, ownerSide: true) : [],
            recoveredParticipant: ownerSide ? [] : rows(run, ownerSide: false))
        let url = root.appendingPathComponent("lifecycle/State/\(run)-\(prior).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url)
        let invitation = V02Envelope(purpose: "lifecycle-invitation", runID: run, containerIdentifier: "test", account: V02PrivateID(owner), recipient: V02PrivateID(participant),
            share: V02PrivateID(CKRecord.ID(recordName: "cloudkit.zoneshare", zoneID: CKRecordZone.ID(zoneName: "zone-A", ownerName: owner.recordName))),
            shareURL: URL(string: "https://www.icloud.com/share/test"), caseID: prior)
        try V02SensitiveFiles.write(invitation, to: root.appendingPathComponent("lifecycle/Sensitive/\(run)/\(prior)/\(ownerSide ? "private-invitation.json" : "received-invitation.json")"))
    }
    private func rows(_ run: UUID, ownerSide: Bool, pending: Bool = false) -> [V02Row] {
        V02Fixture.rows.filter { ownerSide || $0.graph == "A" }.map { row in
            let key = V02RecordKey.make(CKRecord.ID(recordName: "cloudkit.zoneshare", zoneID: CKRecordZone.ID(zoneName: "zone-" + row.graph, ownerName: owner.recordName)), currentUser: owner, runID: run)
            var people = [V02Participant(role: CKShare.ParticipantRole.owner.rawValue, permission: CKShare.ParticipantPermission.readWrite.rawValue, acceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue)]
            if row.graph == "A" { people.append(V02Participant(role: CKShare.ParticipantRole.privateUser.rawValue, permission: CKShare.ParticipantPermission.readWrite.rawValue, acceptance: (pending ? CKShare.ParticipantAcceptanceStatus.pending : .accepted).rawValue)) }
            let share = V02ShareInfo(id: key, publicPermission: CKShare.ParticipantPermission.none.rawValue, currentUserRole: (ownerSide ? CKShare.ParticipantRole.owner : .privateUser).rawValue,
                currentUserPermission: CKShare.ParticipantPermission.readWrite.rawValue, currentUserAcceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue, participants: people)
            return V02Row(scope: ownerSide ? .privateStore : .sharedStore, graph: row.graph, node: row.node, kind: row.kind,
                value: row.node == "A-001" ? V02Fixture.editedValue : row.value, parent: row.parent, children: row.children, validClosure: true,
                record: V02RecordKey(recordName: "record-" + row.node, zoneName: key.zoneName, zoneOwnerDigest: key.zoneOwnerDigest), share: share)
        }
    }
}

@MainActor
private final class FakeLeaveRecoveryStore: V02LeaveRecoveryStoreAccess {
    var rows: [V02Row]
    var storeIDs = ["private": "fresh-private", "shared": "fresh-shared"]
    var metadataFailure = false
    var opens = 0, metadataReads = 0
    var fresh: Bool?
    var directory: URL?
    var closed = false
    init(rows: [V02Row]) { self.rows = rows }
    var inventory: [String: String] { storeIDs }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws {
        opens += 1; self.directory = directory; self.fresh = fresh
    }
    func snapshot(runID: UUID) async throws -> [V02Row] { rows }
    func invitationMetadata(_ invitation: V02Envelope, runID: UUID, priorCaseID: UUID, container: String) async throws -> V02LeaveMetadata {
        metadataReads += 1
        var result = V02LeaveMetadata(requestedAt: Date())
        result.completedAt = Date()
        if metadataFailure { result.errors = V02PublicReadError.capture(NSError(domain: CKErrorDomain, code: CKError.Code.unknownItem.rawValue)) }
        else { result.returnedMetadata = true; result.participantStatus = CKShare.ParticipantAcceptanceStatus.pending.rawValue }
        return result
    }
    func close() async throws { closed = true }
}
