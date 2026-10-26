import Foundation
import CloudKit

nonisolated enum V02RevocationRole: String, Codable, CaseIterable {
    case watch = "participant-watch", revoke = "owner-revoke", verify = "owner-verify"
}
nonisolated struct V02RevocationRequest {
    let role: V02RevocationRole
    let runID: UUID
    let caseID: UUID
    let window: Int
    static func parse(_ arguments: [String]) -> Self? {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: key), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard arguments.contains("--v02-development-verified"),
              let role = value("--v02-revocation-role").flatMap(V02RevocationRole.init(rawValue:)),
              let run = value("--v02-run-id").flatMap(UUID.init(uuidString:)),
              let id = value("--v02-case-id").flatMap(UUID.init(uuidString:)),
              let window = Int(value("--v02-window") ?? "120"), (1...600).contains(window) else { return nil }
        return Self(role: role, runID: run, caseID: id, window: window)
    }
}

nonisolated struct V02RevocationObject: Codable {
    let node: String?
    let objectURI: String
}
nonisolated struct V02RevocationHistory: Codable {
    let available: Bool
    let transactions: Int
    let truncated: Bool
    let watchedInserts: Int
    let watchedUpdates: Int
    let watchedDeletes: Int
    let watchedDeletedURIs: [String]
    let error: String?
}
nonisolated struct V02RevocationSample: Codable {
    let timestamp: Date
    let members: [V02Row]
}
nonisolated enum V02RevocationFixture {
    static func participantBefore(_ rows: [V02Row]) -> Bool {
        V02PermissionFixture.exact(rows, owner: false, permission: .readOnly) ||
        V02PermissionFixture.exact(rows, owner: false, permission: .readWrite)
    }
    static func ownerBefore(_ rows: [V02Row]) -> Bool {
        V02PermissionFixture.exact(rows, owner: true, permission: .readOnly) ||
        V02PermissionFixture.exact(rows, owner: true, permission: .readWrite)
    }
    static func ownerAfter(_ rows: [V02Row], original: [V02Row]) -> Bool {
        guard V02Fixture.exact(rows, owner: true, edited: true, requireShares: false), ownerBefore(original) else { return false }
        for row in rows {
            guard let old = original.first(where: { $0.node == row.node }), row.record == old.record,
                  row.share?.id == old.share?.id, row.share?.ownerOnly == true,
                  row.share?.currentUserRole == CKShare.ParticipantRole.owner.rawValue else { return false }
            if row.graph == "B" && row != old { return false }
        }
        return true
    }
    static func removal(before: [V02Row], after: [V02Row], sameStores: Bool) -> Bool {
        participantBefore(before) && after.isEmpty && sameStores
    }
}

nonisolated struct V02RevocationState: Codable {
    let runID: UUID
    let caseID: UUID
    let originalOwner: [V02Row]
    let ownerStores: [String: String]
    var revokeCompleted = false
}
nonisolated struct V02RevocationReport: Codable {
    var procedure = "V02-live-revocation-v1"
    let runID: UUID
    let caseID: UUID
    let role: V02RevocationRole
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
    var knownObjects: [V02RevocationObject] = []
    var members: [V02Row] = []
    var readyForOwnerAction = false
    var readyAt: Date?
    var revokeAPIReturned = false
    var removalObserved = false
    var firstAbsenceAt: Date?
    var ownerPreserved = false
    var firstUnexpectedOwnerSnapshot: [V02Row] = []
    var samples: [V02RevocationSample] = []
    var droppedSamples = 0
    var history: V02RevocationHistory?
    var historyAnchorAvailable = false
    var historyAnchorError: String?
    var events: [V01NativeEvent] = []
    var droppedEvents = 0
    var sampleErrors: [String] = []
    var errors: [String] = []
    var traceWriteFailures = 0
    var traceDroppedEntries = 0
    var storesDetached = false
    var finalReportRetained = false
}
