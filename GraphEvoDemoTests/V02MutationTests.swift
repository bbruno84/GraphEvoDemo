import XCTest
import CloudKit
@testable import GraphEvoDemo

@MainActor
final class V02MutationTests: XCTestCase {
    private let owner = CKRecord.ID(recordName: "test-owner")
    private let participant = CKRecord.ID(recordName: "test-participant")

    func testRolesAndCLIRequireAnExplicitCase() {
        for role in V02MutationRole.allCases {
            var arguments = ["--v02-mutation-role", role.rawValue, "--v02-run-id", UUID().uuidString,
                             "--v02-case-id", UUID().uuidString, "--v02-development-verified", "--v02-window", "30"]
            if role == .participantConfirmOwnerAdd {
                XCTAssertNil(V02MutationRequest.parse(arguments))
                arguments += ["--v02-prior-case-id", UUID().uuidString]
            }
            XCTAssertEqual(V02MutationRequest.parse(arguments)?.role, role)
            XCTAssertNil(V02MutationRequest.parse(arguments.filter { $0 != "--v02-development-verified" }))
            XCTAssertNil(V02MutationRequest.parse(arguments.filter { $0 != "--v02-case-id" }))
        }
    }

    func testExactPhasesPreserveGraphIdentityAndRejectMixedScopes() {
        let run = UUID()
        let original = rows(run: run, ownerSide: true, phase: .original)
        for phase in [V02MutationPhase.original, .ownerAdded, .ownerDeleted, .participantAdded,
                      .participantDeleted, .participantExplicitAdded, .participantExplicitDeleted] {
            let ownerRows = rows(run: run, ownerSide: true, phase: phase)
            let participantRows = rows(run: run, ownerSide: false, phase: phase)
            XCTAssertTrue(V02MutationFixture.preserves(ownerRows, original: original, phase: phase, owner: true, addedRecord: nil))
            XCTAssertTrue(V02MutationFixture.exact(participantRows, phase: phase, owner: false))
            XCTAssertFalse(V02MutationFixture.exact(ownerRows, phase: phase, owner: false))
            XCTAssertFalse(V02MutationFixture.exact(participantRows + [original[0]], phase: phase, owner: false))
        }
        var mixed = rows(run: run, ownerSide: true, phase: .ownerAdded)
        mixed[0] = V02Row(scope: .privateStore, graph: mixed[0].graph, node: mixed[0].node,
                          kind: mixed[0].kind, value: mixed[0].value, parent: mixed[0].parent,
                          children: mixed[0].children, validClosure: mixed[0].validClosure,
                          record: mixed[0].record, share: original.first(where: { $0.graph == "B" })?.share)
        XCTAssertFalse(V02MutationFixture.preserves(mixed, original: original, phase: .ownerAdded, owner: true, addedRecord: nil))
    }

    func testOneShotOwnerMutationAndLiveParticipantObservation() async throws {
        let run = UUID(), caseID = UUID()
        for role in [V02MutationRole.ownerAdd, .participantSeeOwnerAdd] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: original) }
            let account = role.isOwner ? owner : participant
            let side = role.isOwner ? "owner" : "participant"
            try V02SensitiveFiles.write(V02Envelope(purpose: "account-binding", runID: run,
                containerIdentifier: "test", account: V02PrivateID(account)),
                to: original.appendingPathComponent("Sensitive/\(run)/\(side)-binding.json"))
            let fake = FakeMutationStore(rows: rows(run: run, ownerSide: role.isOwner, phase: .original),
                                         target: rows(run: run, ownerSide: role.isOwner, phase: .ownerAdded))
            fake.advanceOnSleep = !role.writes
            var tick = 0
            let session = V02MutationSession(root: root, originalRoot: original, permitSimulatorForTests: true,
                account: { _ in account }, makeStore: { _, _ in fake },
                now: { Date(timeIntervalSince1970: TimeInterval(tick)) },
                sleep: { tick += 1; if fake.advanceOnSleep { fake.rows = fake.target } })
            let request = V02MutationRequest(role: role, runID: run, caseID: caseID, window: 1)
            await session.run(request, container: "test")
            XCTAssertTrue(session.report?.errors.isEmpty == true)
            XCTAssertTrue(session.report?.targetObserved == true)
            XCTAssertTrue(session.report?.fullWindowObserved == true)
            XCTAssertEqual(fake.mutationCount, role.writes ? 1 : 0)
            XCTAssertEqual(session.report?.readyForWriter, !role.writes)
            let stateURL = root.appendingPathComponent("State/\(run)-\(caseID)-\(side).json")
            let state = try JSONDecoder().decode(V02MutationState.self, from: Data(contentsOf: stateURL))
            XCTAssertEqual(state.phase, .ownerAdded)
            let replay = FakeMutationStore(rows: [], target: [])
            let second = V02MutationSession(root: root, originalRoot: original, permitSimulatorForTests: true,
                account: { _ in account }, makeStore: { _, _ in replay })
            await second.run(request, container: "test")
            XCTAssertEqual(replay.opens, 0)
            XCTAssertEqual(replay.mutationCount, 0)
        }
    }

    func testReadOnlyResumeAfterBoundedObserverMissesRemoteImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: original) }
        let run = UUID(), priorCase = UUID(), newCase = UUID()
        let base = rows(run: run, ownerSide: false, phase: .original)
        let target = rows(run: run, ownerSide: false, phase: .ownerAdded)
        try V02SensitiveFiles.write(V02Envelope(purpose: "account-binding", runID: run,
            containerIdentifier: "test", account: V02PrivateID(participant)),
            to: original.appendingPathComponent("Sensitive/\(run)/participant-binding.json"))
        var prior = V02MutationState(runID: run, caseID: priorCase, owner: false,
                                     stores: ["private": "original-private", "shared": "original-shared"], original: base)
        prior.reservedRole = .participantSeeOwnerAdd
        let priorURL = root.appendingPathComponent("State/\(run)-\(priorCase)-participant.json")
        try FileManager.default.createDirectory(at: priorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(prior).write(to: priorURL)
        let fake = FakeMutationStore(rows: target, target: target)
        var tick = 0
        let session = V02MutationSession(root: root, originalRoot: original, permitSimulatorForTests: true,
            account: { _ in self.participant }, makeStore: { _, _ in fake },
            now: { Date(timeIntervalSince1970: TimeInterval(tick)) }, sleep: { tick += 1 })
        await session.run(V02MutationRequest(role: .participantConfirmOwnerAdd, runID: run, caseID: newCase,
                                             window: 1, priorCaseID: priorCase), container: "test")
        XCTAssertTrue(session.report?.errors.isEmpty == true)
        XCTAssertTrue(session.report?.targetObserved == true)
        XCTAssertFalse(session.report?.readyForWriter ?? true)
        XCTAssertEqual(fake.mutationCount, 0)
        let newURL = root.appendingPathComponent("State/\(run)-\(newCase)-participant.json")
        let resumed = try JSONDecoder().decode(V02MutationState.self, from: Data(contentsOf: newURL))
        XCTAssertEqual(resumed.phase, .ownerAdded)
        XCTAssertEqual(resumed.priorCaseID, priorCase)
    }

    private func rows(run: UUID, ownerSide: Bool, phase: V02MutationPhase) -> [V02Row] {
        var fixture = V02Fixture.rows.filter { ownerSide || $0.graph == "A" }
        if phase == .ownerAdded { fixture.append(("A", "A-003", "item", "owner-delta", "A-root", [])) }
        if phase == .participantAdded || phase == .participantExplicitAdded {
            fixture.append(("A", "A-004", "item", "participant-delta", "A-root", []))
        }
        return fixture.map { row in
            let shareID = V02RecordKey.make(CKRecord.ID(recordName: "cloudkit.zoneshare",
                zoneID: CKRecordZone.ID(zoneName: "zone-" + row.graph, ownerName: owner.recordName)), currentUser: owner, runID: run)
            var people = [V02Participant(role: CKShare.ParticipantRole.owner.rawValue,
                permission: CKShare.ParticipantPermission.readWrite.rawValue,
                acceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue)]
            if row.graph == "A" {
                people.append(V02Participant(role: CKShare.ParticipantRole.privateUser.rawValue,
                    permission: CKShare.ParticipantPermission.readWrite.rawValue,
                    acceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue))
            }
            let share = V02ShareInfo(id: shareID, publicPermission: CKShare.ParticipantPermission.none.rawValue,
                currentUserRole: (ownerSide ? CKShare.ParticipantRole.owner : .privateUser).rawValue,
                currentUserPermission: CKShare.ParticipantPermission.readWrite.rawValue,
                currentUserAcceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue, participants: people)
            var children = row.children
            if row.node == "A-root" {
                if phase == .ownerAdded { children.append("A-003") }
                if phase == .participantAdded || phase == .participantExplicitAdded { children.append("A-004") }
            }
            let value = row.node == "A-001" && phase != .original &&
                phase != .participantExplicitAdded && phase != .participantExplicitDeleted ? V02MutationFixture.ownerValue :
                row.node == "A-002" && [.participantAdded, .participantDeleted].contains(phase) ? V02MutationFixture.participantValue : row.value
            return V02Row(scope: ownerSide ? .privateStore : .sharedStore, graph: row.graph, node: row.node,
                kind: row.kind, value: value, parent: row.parent, children: children.sorted(), validClosure: true,
                record: V02RecordKey(recordName: "record-" + row.node, zoneName: shareID.zoneName,
                                     zoneOwnerDigest: shareID.zoneOwnerDigest), share: share)
        }.sorted { ($0.node ?? "") < ($1.node ?? "") }
    }
}

@MainActor
private final class FakeMutationStore: V02MutationStoreAccess {
    var rows: [V02Row]
    let target: [V02Row]
    var advanceOnSleep = false
    var opens = 0
    var mutationCount = 0
    var inventory: [String: String] { ["private": "original-private", "shared": "original-shared"] }
    init(rows: [V02Row], target: [V02Row]) { self.rows = rows; self.target = target }
    func open(directory: URL, container: String, fresh: Bool,
              event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws { opens += 1 }
    func snapshot(runID: UUID) async throws -> [V02Row] { rows }
    func mutate(_ role: V02MutationRole, runID: UUID) async throws { mutationCount += 1; rows = target }
    func close() async throws {}
}
