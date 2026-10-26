import XCTest
import CoreData
import CloudKit
@testable import GraphEvoDemo

@MainActor
final class V02PermissionTests: XCTestCase {
    private let user = CKRecord.ID(recordName: "test-user")

    func testPermissionAdviceNeverSkipsRealWriteAndLocalSuccessIsNotEnforcement() {
        var writes = 0
        let saved = V02ReadOnlyAttempt.perform(canUpdate: false, canModify: true, valueBefore: V02Fixture.editedValue) { writes += 1 }
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(saved.canUpdateRecord ?? true)
        XCTAssertTrue(saved.saveReturnedSuccess)
        XCTAssertTrue(saved.classification.hasPrefix("Local save permitted"))
        let rejected = V02ReadOnlyAttempt.perform(canUpdate: false, canModify: false, valueBefore: V02Fixture.editedValue) {
            writes += 1
            throw NSError(domain: "NativeTest", code: 7, userInfo: [NSUnderlyingErrorKey: NSError(domain: "CloudTest", code: 10)])
        }
        XCTAssertEqual(writes, 2)
        XCTAssertFalse(rejected.saveReturnedSuccess)
        XCTAssertEqual(rejected.localSaveErrors, ["NativeTest:7", "CloudTest:10"])
        XCTAssertTrue(rejected.classification.hasPrefix("Local save rejected"))
    }

    func testCLIRequiresProbeIdentityAndExplicitRestoreProofAssertion() {
        let common = ["--v02-development-verified", "--v02-run-id", UUID().uuidString, "--v02-probe-id", UUID().uuidString]
        for role in V02PermissionRole.allCases {
            var args = common + ["--v02-permission-role", role.rawValue]
            if role == .restore {
                XCTAssertNil(V02PermissionRequest.parse(args))
                args += ["--v02-probe-stopped-and-quarantined", "--v02-probe-report", "probe.json"]
            }
            XCTAssertEqual(V02PermissionRequest.parse(args)?.role, role)
            XCTAssertNil(V02Request.parse(args))
        }
        XCTAssertNil(V02PermissionRequest.parse(common + ["--v02-permission-role", "owner-restore-readwrite", "--v02-probe-stopped-and-quarantined", "--v02-probe-report", "../probe.json"]))
    }

    func testReadOnlySnapshotNeedsExactScopePermissionAndOriginalOwnerIdentities() {
        let original = rows(owner: true, permission: .readWrite)
        let participant = rows(owner: false, permission: .readOnly)
        XCTAssertTrue(V02PermissionFixture.unchanged(participant, ownerBaseline: original, owner: false, permission: .readOnly))
        XCTAssertFalse(V02PermissionFixture.exact(rows(owner: false, permission: .readWrite), owner: false, permission: .readOnly))
        XCTAssertFalse(V02PermissionFixture.exact(participant + [original.last!], owner: false, permission: .readOnly))
        XCTAssertFalse(V02PermissionFixture.exact(Array(participant.dropLast()), owner: false, permission: .readOnly))
        XCTAssertFalse(V02PermissionFixture.exact(rows(owner: false, permission: .readOnly, attempted: true), owner: false, permission: .readOnly))
        XCTAssertTrue(V02PermissionFixture.unchanged(rows(owner: true, permission: .readOnly), ownerBaseline: original, owner: true, permission: .readOnly))
    }

    func testRestoreGateRequiresCompletedDetachedConsumedMatchingProbeAndHumanStopAssertion() throws {
        let run = UUID(), probe = UUID()
        let baseline = rows(owner: true, permission: .readWrite)
        let valid = proof(run: run, probe: probe)
        XCTAssertNoThrow(try V02ProbeRestoreGate.validate(valid, request: request(.restore, run: run, probe: probe, stopped: true), ownerBaseline: baseline))
        XCTAssertThrowsError(try V02ProbeRestoreGate.validate(valid, request: request(.restore, run: run, probe: probe), ownerBaseline: baseline))
        for field in ["finished", "finalReportRetained", "storesDetached", "probePathPermanentlyConsumed", "readOnlyImportObserved", "probeID"] {
            var broken = valid
            switch field {
            case "finished": broken.finished = nil
            case "finalReportRetained": broken.finalReportRetained = false
            case "storesDetached": broken.storesDetached = false
            case "probePathPermanentlyConsumed": broken.probePathPermanentlyConsumed = false
            case "readOnlyImportObserved": broken.readOnlyImportObserved = false
            default: broken = proof(run: run, probe: UUID())
            }
            XCTAssertThrowsError(try V02ProbeRestoreGate.validate(broken, request: request(.restore, run: run, probe: probe, stopped: true), ownerBaseline: baseline), field)
        }
    }

    func testProbeUsesFreshIsolatedStoresWritesOnceAndHoldsFullWindowThenRejectsReopen() async throws {
        let root = temporaryRoot(), originalRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: originalRoot) }
        let run = UUID(), probe = UUID()
        try binding(originalRoot, run: run, owner: false)
        let fake = FakePermissionStore(rows: rows(owner: false, permission: .readOnly))
        fake.afterAttempt = rows(owner: false, permission: .readOnly, attempted: true)
        fake.emitExportFailure = true
        var time = Date(timeIntervalSince1970: 10), sleeps = 0
        let session = makeSession(root, originalRoot: originalRoot, fake: fake, now: { time }, sleep: {
            XCTAssertFalse(fake.closed); sleeps += 1; time.addTimeInterval(2)
        })
        await session.run(request(.probe, run: run, probe: probe, window: 6), container: "test")
        XCTAssertEqual(sleeps, 3)
        XCTAssertEqual(fake.attempts, 1)
        XCTAssertTrue(fake.fresh == true)
        XCTAssertTrue(fake.directory?.path.contains("V02Laboratory/Stores") == false)
        XCTAssertTrue(fake.directory?.path.contains("participant-probe") == true)
        XCTAssertTrue(session.report?.readOnlyImportObserved == true)
        XCTAssertTrue(session.report?.attempt?.saveReturnedSuccess == true)
        XCTAssertTrue(session.report?.outcome.hasPrefix("Local save permitted") == true)
        XCTAssertEqual(session.report?.exportErrors, ["NativeExport:10"])
        XCTAssertTrue(session.report?.errors.isEmpty == true)
        XCTAssertTrue(session.report?.storesDetached == true)
        let second = FakePermissionStore(rows: rows(owner: false, permission: .readOnly))
        await makeSession(root, originalRoot: originalRoot, fake: second).run(request(.probe, run: run, probe: probe), container: "test")
        XCTAssertEqual(second.opens, 0)
        XCTAssertEqual(second.attempts, 0)
    }

    func testOwnerPermissionUpdateAndRestoreRequireUnchangedFixtureAndCopiedProbeProof() async throws {
        let root = temporaryRoot(), originalRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: originalRoot) }
        let run = UUID(), probe = UUID()
        try binding(originalRoot, run: run, owner: true)
        try V02SensitiveFiles.write(V02Envelope(purpose: "private-invitation", runID: run, containerIdentifier: "test", account: V02PrivateID(user),
            recipient: V02PrivateID(CKRecord.ID(recordName: "participant"))), to: originalRoot.appendingPathComponent("Sensitive/\(run)/private-invitation.json"))
        let set = FakePermissionStore(rows: rows(owner: true, permission: .readWrite))
        set.afterPermission = rows(owner: true, permission: .readOnly)
        let first = makeSession(root, originalRoot: originalRoot, fake: set)
        await first.run(request(.ownerReadOnly, run: run, probe: probe), container: "test")
        XCTAssertEqual(set.changes, 1)
        XCTAssertFalse(set.fresh ?? true)
        XCTAssertTrue(first.report?.permissionUpdatePersisted == true)
        let observe = makeSession(root, originalRoot: originalRoot, fake: FakePermissionStore(rows: set.afterPermission))
        await observe.run(request(.ownerObserve, run: run, probe: probe), container: "test")
        XCTAssertTrue(observe.report?.ownerUnchangedForWindow == true)
        let folder = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(proof(run: run, probe: probe)).write(to: folder.appendingPathComponent("probe.json"))
        let restored = FakePermissionStore(rows: set.afterPermission)
        restored.afterPermission = rows(owner: true, permission: .readWrite)
        let restore = makeSession(root, originalRoot: originalRoot, fake: restored)
        await restore.run(request(.restore, run: run, probe: probe, stopped: true), container: "test")
        XCTAssertEqual(restored.changes, 1)
        XCTAssertTrue(restore.report?.ownerUnchangedForWindow == true)
        XCTAssertTrue(restore.report?.externalStopAndQuarantineAsserted == true)
        XCTAssertNotNil(restore.report?.participantReportSHA256)
    }

    func testLocalProbeSaveIsActuallyPersistedAndReadThroughANewContextWithoutReplay() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: V01OwnerOnlyShareTrial.model())
        let privateStore = try coordinator.addPersistentStore(type: .sqlite, at: root.appendingPathComponent("private.sqlite"))
        let shared = try coordinator.addPersistentStore(type: .sqlite, at: root.appendingPathComponent("shared.sqlite"))
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var objects: [String: NSManagedObject] = [:]
        for row in V02Fixture.rows where row.graph == "A" {
            let object = NSEntityDescription.insertNewObject(forEntityName: "V01T6Member", into: context)
            context.assign(object, to: shared)
            for (key, value) in ["runID": run.uuidString, "graph": row.graph, "node": row.node, "kind": row.kind,
                                 "value": row.node == "A-001" ? V02Fixture.editedValue : row.value] { object.setValue(value, forKey: key) }
            objects[row.node] = object
        }
        objects["A-001"]?.setValue(objects["A-root"], forKey: "parent")
        objects["A-002"]?.setValue(objects["A-root"], forKey: "parent")
        try context.save(); context.reset()
        try coordinator.remove(shared); try coordinator.remove(privateStore)
        let store = V02CloudStore(currentUser: user, localOnly: true)
        try await store.open(directory: root, container: "test", fresh: false, event: { _ in })
        let result = try await store.attemptReadOnlySave(runID: run)
        XCTAssertTrue(result.saveReturnedSuccess)
        XCTAssertNil(result.canUpdateRecord) // A local-only test is not a native CloudKit permission check.
        XCTAssertEqual(result.freshContextValue, V02PermissionFixture.attemptedValue)
        let retained = try await store.snapshot(runID: run)
        XCTAssertEqual(retained.first { $0.node == "A-001" }?.value, V02PermissionFixture.attemptedValue)
        do { _ = try await store.attemptReadOnlySave(runID: run); XCTFail("The pre-attempt value prevents replay") } catch {}
        try await store.close()
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func request(_ role: V02PermissionRole, run: UUID, probe: UUID, window: Int = 0, stopped: Bool = false) -> V02PermissionRequest {
        V02PermissionRequest(role: role, runID: run, probeID: probe, window: window, probeReport: role == .restore ? "probe.json" : nil, stoppedAndQuarantined: stopped)
    }
    private func makeSession(_ root: URL, originalRoot: URL, fake: FakePermissionStore,
                             now: @escaping @MainActor @Sendable () -> Date = { Date() },
                             sleep: @escaping @MainActor @Sendable () async throws -> Void = {}) -> V02PermissionSession {
        V02PermissionSession(root: root, originalRoot: originalRoot, permitSimulatorForTests: true, account: { _ in self.user }, makeStore: { _, _ in fake }, now: now, sleep: sleep)
    }
    private func binding(_ root: URL, run: UUID, owner: Bool) throws {
        try V02SensitiveFiles.write(V02Envelope(purpose: "account-binding", runID: run, containerIdentifier: "test", account: V02PrivateID(user)),
            to: root.appendingPathComponent("Sensitive/\(run)/\(owner ? "owner" : "participant")-binding.json"))
    }
    private func proof(run: UUID, probe: UUID) -> V02PermissionReport {
        var report = V02PermissionReport(runID: run, probeID: probe, stageID: UUID(), processID: UUID(), role: .probe, started: Date(), windowSeconds: 60, environment: [:])
        report.finished = Date(); report.finalReportRetained = true; report.storesDetached = true
        report.probePathPermanentlyConsumed = true; report.readOnlyImportObserved = true
        report.stores = ["private": "probe-private", "shared": "probe-shared"]
        report.baseline = rows(owner: false, permission: .readOnly)
        report.attempt = V02ReadOnlyAttempt.perform(canUpdate: false, canModify: true, valueBefore: V02Fixture.editedValue) {}
        report.attempt?.freshContextValue = V02PermissionFixture.attemptedValue
        return report
    }
    private func rows(owner: Bool, permission: CKShare.ParticipantPermission, attempted: Bool = false) -> [V02Row] {
        V02Fixture.rows.filter { owner || $0.graph == "A" }.map { row in
            let key = V02RecordKey(recordName: "cloudkit.zoneshare", zoneName: "zone-" + row.graph, zoneOwnerDigest: "opaque-owner")
            var participants = [V02Participant(role: CKShare.ParticipantRole.owner.rawValue, permission: CKShare.ParticipantPermission.readWrite.rawValue, acceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue)]
            if row.graph == "A" { participants.append(V02Participant(role: CKShare.ParticipantRole.privateUser.rawValue, permission: permission.rawValue, acceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue)) }
            let share = V02ShareInfo(id: key, publicPermission: CKShare.ParticipantPermission.none.rawValue,
                currentUserRole: (owner ? CKShare.ParticipantRole.owner : .privateUser).rawValue,
                currentUserPermission: (owner ? CKShare.ParticipantPermission.readWrite : permission).rawValue,
                currentUserAcceptance: CKShare.ParticipantAcceptanceStatus.accepted.rawValue, participants: participants)
            return V02Row(scope: owner ? .privateStore : .sharedStore, graph: row.graph, node: row.node, kind: row.kind,
                value: row.node == "A-001" ? (attempted ? V02PermissionFixture.attemptedValue : V02Fixture.editedValue) : row.value,
                parent: row.parent, children: row.children, validClosure: true,
                record: V02RecordKey(recordName: "record-" + row.node, zoneName: key.zoneName, zoneOwnerDigest: key.zoneOwnerDigest), share: share)
        }
    }
}

@MainActor
private final class FakePermissionStore: V02PermissionStoreAccess {
    var rows: [V02Row]
    var afterPermission: [V02Row] = []
    var afterAttempt: [V02Row] = []
    var opens = 0, attempts = 0, changes = 0
    var fresh: Bool?
    var directory: URL?
    var closed = false
    var emitExportFailure = false
    init(rows: [V02Row]) { self.rows = rows }
    var inventory: [String: String] { ["private": "test-private", "shared": "test-shared"] }
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws {
        opens += 1; self.directory = directory; self.fresh = fresh
        if emitExportFailure {
            event(V01NativeEvent(identifier: UUID(), kind: "export", started: Date(), finished: Date(), succeeded: false, storeIdentifier: "test-shared", error: "NativeExport:10"))
        }
    }
    func snapshot(runID: UUID) async throws -> [V02Row] { rows }
    func changeParticipantPermission(runID: UUID, recipient: V02PrivateID, from: CKShare.ParticipantPermission, to: CKShare.ParticipantPermission, checkpoint: () throws -> Void) async throws {
        changes += 1; try checkpoint(); rows = afterPermission
    }
    func attemptReadOnlySave(runID: UUID) async throws -> V02ReadOnlyAttempt {
        attempts += 1; rows = afterAttempt
        var result = V02ReadOnlyAttempt.perform(canUpdate: false, canModify: true, valueBefore: V02Fixture.editedValue) {}
        result.freshContextValue = V02PermissionFixture.attemptedValue
        return result
    }
    func close() async throws { closed = true }
}
