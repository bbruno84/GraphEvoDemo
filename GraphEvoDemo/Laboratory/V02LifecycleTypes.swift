import Foundation
import CloudKit

nonisolated enum V02LifecycleRole: String, Codable, CaseIterable {
    case reinvite = "owner-reinvite", reaccept = "participant-reaccept", leave = "participant-leave", verify = "owner-verify-leave"
    case rejoinOld = "participant-rejoin-old-link"
    var isOwner: Bool { self == .reinvite || self == .verify }
}
nonisolated struct V02LifecycleRequest {
    let role: V02LifecycleRole
    let runID: UUID
    let caseID: UUID
    let window: Int
    let input: String?
    let priorCaseID: UUID?
    init(role: V02LifecycleRole, runID: UUID, caseID: UUID, window: Int, input: String?, priorCaseID: UUID? = nil) {
        self.role = role; self.runID = runID; self.caseID = caseID; self.window = window
        self.input = input; self.priorCaseID = priorCaseID
    }
    static func parse(_ arguments: [String]) -> Self? {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: key), arguments.indices.contains(i + 1) else { return nil }; return arguments[i + 1]
        }
        guard arguments.contains("--v02-development-verified"),
              let role = value("--v02-lifecycle-role").flatMap(V02LifecycleRole.init(rawValue:)),
              let run = value("--v02-run-id").flatMap(UUID.init(uuidString:)),
              let id = value("--v02-case-id").flatMap(UUID.init(uuidString:)),
              let window = Int(value("--v02-window") ?? "60"), (1...600).contains(window) else { return nil }
        let input = value("--v02-input")
        if let input, !V02Request.validFilename(input) { return nil }
        if role == .reaccept && input == nil { return nil }
        let prior = value("--v02-prior-case-id").flatMap(UUID.init(uuidString:))
        if role == .rejoinOld && (prior == nil || prior == id || input != nil) { return nil }
        if role != .rejoinOld && prior != nil { return nil }
        return Self(role: role, runID: run, caseID: id, window: window, input: input, priorCaseID: prior)
    }
}

nonisolated enum V02LifecycleFixture {
    static func owner(_ rows: [V02Row], invited: Bool, original: [V02Row]? = nil) -> Bool {
        guard V02Fixture.exact(rows, owner: true, edited: true, requireShares: false) else { return false }
        for row in rows {
            guard let share = row.share, let record = row.record,
                  record.zoneName == share.id.zoneName, record.zoneOwnerDigest == share.id.zoneOwnerDigest,
                  share.currentUserRole == CKShare.ParticipantRole.owner.rawValue,
                  share.publicPermission == CKShare.ParticipantPermission.none.rawValue,
                  (row.graph == "A" && invited ? share.privateReadWritePair : share.ownerOnly) else { return false }
            if let original {
                guard let old = original.first(where: { $0.node == row.node }), old.record == row.record, old.share?.id == share.id else { return false }
                if row.graph == "B" && row != old { return false }
            }
        }
        for graph in ["A", "B"] {
            let shares = rows.filter { $0.graph == graph }.compactMap(\.share)
            guard shares.allSatisfy({ $0.id == shares.first?.id }) else { return false }
        }
        return rows.first(where: { $0.graph == "A" })?.share?.id.zoneName != rows.first(where: { $0.graph == "B" })?.share?.id.zoneName
    }
    static func participant(_ rows: [V02Row], expectedShare: V02RecordKey) -> Bool {
        V02PermissionFixture.exact(rows, owner: false, permission: .readWrite) && rows.allSatisfy { $0.share?.id == expectedShare }
    }
    static func permitsLeave(_ rows: [V02Row], scope: V02Scope, role: CKShare.ParticipantRole, expectedShare: V02RecordKey) -> Bool {
        scope == .sharedStore && role == .privateUser && V02RevocationFixture.participantBefore(rows) &&
        rows.allSatisfy { $0.scope == .sharedStore && $0.share?.id == expectedShare }
    }
}

nonisolated struct V02ReacceptResult: Codable {
    let metadataStatus: Int
    let acceptanceAPICalled: Bool
    let alreadyAccepted: Bool
}
nonisolated enum V02LifecycleProgress: String, Codable { case inviting, invited, accepting, recovered, leaving, left }
nonisolated struct V02LifecycleState: Codable {
    let runID: UUID
    let caseID: UUID
    var priorCaseID: UUID?
    var progress: V02LifecycleProgress
    let stores: [String: String]
    let originalOwner: [V02Row]
    var recoveredParticipant: [V02Row] = []
}
nonisolated struct V02LifecycleReport: Codable {
    var procedure = "V02-reinvite-voluntary-leave-v1"
    let runID: UUID
    let caseID: UUID
    var priorCaseID: UUID?
    let role: V02LifecycleRole
    let stageID: UUID
    let processID: UUID
    let started: Date
    let windowSeconds: Int
    let environment: [String: String]
    var finished: Date?
    var phase = "Preflight"
    var outcome = "Running; not completed evidence"
    var stores: [String: String] = [:]
    var openingSnapshot: [V02Row] = []
    var before: [V02Row] = []
    var members: [V02Row] = []
    var invitationPersisted = false
    var sensitiveArtifact: String?
    var initiallyAbsent = false
    var reaccept: V02ReacceptResult?
    var exactRecovery = false
    var leaveRequested = false
    var leaveAPIReturned = false
    var returnedPurgeZone: V02RecordKey?
    var purgeScope: String?
    var absenceAfterKnownFixture = false
    var ownerPreserved = false
    var events: [V01NativeEvent] = []
    var droppedEvents = 0
    var errors: [String] = []
    var traceWriteFailures = 0
    var traceDroppedEntries = 0
    var storesDetached = false
    var finalReportRetained = false
}
