import Foundation
import CloudKit

nonisolated enum V02PermissionRole: String, Codable, CaseIterable {
    case ownerReadOnly = "owner-readonly", probe = "participant-readonly-probe"
    case ownerObserve = "owner-observe-readonly", restore = "owner-restore-readwrite"
    var isOwner: Bool { self != .probe }
}

nonisolated struct V02PermissionRequest {
    let role: V02PermissionRole
    let runID: UUID
    let probeID: UUID
    let window: Int
    let probeReport: String?
    let stoppedAndQuarantined: Bool
    static func parse(_ arguments: [String]) -> Self? {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: key), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard arguments.contains("--v02-development-verified"),
              let role = value("--v02-permission-role").flatMap(V02PermissionRole.init(rawValue:)),
              let runID = value("--v02-run-id").flatMap(UUID.init(uuidString:)),
              let probeID = value("--v02-probe-id").flatMap(UUID.init(uuidString:)),
              let window = Int(value("--v02-window") ?? "60"), (1...600).contains(window) else { return nil }
        let file = value("--v02-probe-report")
        if let file, !V02Request.validFilename(file) { return nil }
        let stopped = arguments.contains("--v02-probe-stopped-and-quarantined")
        if role == .restore && (!stopped || file == nil) { return nil }
        return Self(role: role, runID: runID, probeID: probeID, window: window, probeReport: file, stoppedAndQuarantined: stopped)
    }
}

nonisolated enum V02PermissionFixture {
    static let attemptedValue = "alpha-readonly-attempt"
    static func exact(_ rows: [V02Row], owner: Bool, permission: CKShare.ParticipantPermission) -> Bool {
        guard V02Fixture.exact(rows, owner: owner, edited: true, requireShares: false) else { return false }
        for row in rows {
            guard let record = row.record, let share = row.share,
                  record.zoneName == share.id.zoneName, record.zoneOwnerDigest == share.id.zoneOwnerDigest,
                  share.publicPermission == CKShare.ParticipantPermission.none.rawValue else { return false }
            if row.graph == "A" {
                let participants = share.participants
                guard participants.count == 2,
                      participants.filter({ $0.role == CKShare.ParticipantRole.owner.rawValue }).count == 1,
                      participants.filter({ $0.role == CKShare.ParticipantRole.privateUser.rawValue && $0.permission == permission.rawValue }).count == 1,
                      participants.allSatisfy({ $0.acceptance == CKShare.ParticipantAcceptanceStatus.accepted.rawValue }),
                      share.currentUserRole == (owner ? CKShare.ParticipantRole.owner.rawValue : CKShare.ParticipantRole.privateUser.rawValue),
                      share.currentUserPermission == (owner ? CKShare.ParticipantPermission.readWrite.rawValue : permission.rawValue),
                      share.currentUserAcceptance == CKShare.ParticipantAcceptanceStatus.accepted.rawValue else { return false }
            } else if !share.ownerOnly { return false }
        }
        let a = rows.filter { $0.graph == "A" }.compactMap(\.share)
        guard a.count == 3, a.allSatisfy({ $0.id == a.first?.id }) else { return false }
        if owner {
            let b = rows.filter { $0.graph == "B" }.compactMap(\.share)
            guard b.count == 2, b.allSatisfy({ $0.id == b.first?.id }), a.first?.id.zoneName != b.first?.id.zoneName else { return false }
        }
        return true
    }

    static func unchanged(_ rows: [V02Row], ownerBaseline: [V02Row], owner: Bool,
                          permission: CKShare.ParticipantPermission) -> Bool {
        guard exact(rows, owner: owner, permission: permission) else { return false }
        let reference = ownerBaseline.filter { owner || $0.graph == "A" }
        guard rows.count == reference.count else { return false }
        for row in rows {
            guard let original = reference.first(where: { $0.node == row.node }), row.graph == original.graph,
                  row.value == original.value, row.kind == original.kind, row.parent == original.parent,
                  row.children == original.children, row.record == original.record, row.share?.id == original.share?.id else { return false }
            if row.graph == "B" && row != original { return false }
        }
        return true
    }
}

nonisolated struct V02ReadOnlyAttempt: Codable {
    var attempted = true
    let canUpdateRecord: Bool?
    let canModifyStore: Bool?
    let valueBefore: String?
    var attemptedValue = V02PermissionFixture.attemptedValue
    let saveReturnedSuccess: Bool
    let localSaveErrors: [String]
    var freshContextValue: String?
    var freshReadErrors: [String] = []

    /// Permission advice is recorded, never used to skip the real write closure.
    static func perform(canUpdate: Bool?, canModify: Bool?, valueBefore: String?, write: () throws -> Void) -> Self {
        do {
            try write()
            return Self(canUpdateRecord: canUpdate, canModifyStore: canModify, valueBefore: valueBefore, saveReturnedSuccess: true, localSaveErrors: [])
        } catch {
            return Self(canUpdateRecord: canUpdate, canModifyStore: canModify, valueBefore: valueBefore,
                        saveReturnedSuccess: false, localSaveErrors: errorCodes(error))
        }
    }
    var classification: String {
        saveReturnedSuccess
            ? "Local save permitted; do not label read-only enforcement. Compare local persistence, export errors and independent owner data."
            : "Local save rejected with a recorded error; remote non-mutation requires independent owner observation."
    }
    private static func errorCodes(_ error: Error, depth: Int = 0) -> [String] {
        guard depth < 4 else { return [] }
        let ns = error as NSError
        var result = [v01ErrorCode(error)]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { result += errorCodes(underlying, depth: depth + 1) }
        if let detailed = ns.userInfo["NSDetailedErrors"] as? [Error] {
            for child in detailed.prefix(3) { result += errorCodes(child, depth: depth + 1) }
        }
        return Array(result.prefix(16))
    }
}

nonisolated enum V02PermissionProgress: String, Codable { case downgrading, readOnlyReady, ownerUnchanged, restoring, restored }
nonisolated struct V02PermissionState: Codable {
    let runID: UUID
    let probeID: UUID
    var progress: V02PermissionProgress = .downgrading
    let originalOwner: [V02Row]
    let ownerStores: [String: String]
}

nonisolated struct V02PermissionReport: Codable {
    var procedure = "V02-readonly-fresh-replica-v1"
    let runID: UUID
    let probeID: UUID
    let stageID: UUID
    let processID: UUID
    let role: V02PermissionRole
    let started: Date
    let windowSeconds: Int
    let environment: [String: String]
    var finished: Date?
    var phase = "Preflight"
    var outcome = "Running; not completed evidence"
    var stores: [String: String] = [:]
    var openingSnapshot: [V02Row] = []
    var baseline: [V02Row] = []
    var members: [V02Row] = []
    var readOnlyImportObserved = false
    var permissionUpdatePersisted = false
    var ownerUnchangedForWindow = false
    var firstUnexpectedOwnerSnapshot: [V02Row] = []
    var attempt: V02ReadOnlyAttempt?
    var probePathPermanentlyConsumed = false
    var storesDetached = false
    var externalStopAndQuarantineAsserted = false
    var participantReportSHA256: String?
    var events: [V01NativeEvent] = []
    var exportErrors: [String] = []
    var droppedEvents = 0
    var errors: [String] = []
    var traceWriteFailures = 0
    var traceDroppedEntries = 0
    var finalReportRetained = false
}

nonisolated enum V02ProbeRestoreGate {
    static func validate(_ report: V02PermissionReport, request: V02PermissionRequest, ownerBaseline: [V02Row]) throws {
        guard request.role == .restore, request.stoppedAndQuarantined,
              report.role == .probe, report.runID == request.runID, report.probeID == request.probeID,
              report.finished != nil, report.finalReportRetained, report.storesDetached,
              report.probePathPermanentlyConsumed, report.readOnlyImportObserved, report.attempt?.attempted == true,
              report.attempt?.freshReadErrors.isEmpty == true,
              [V02Fixture.editedValue, V02PermissionFixture.attemptedValue].contains(report.attempt?.freshContextValue ?? ""),
              report.traceWriteFailures == 0,
              report.errors.isEmpty, report.stores.count == 2,
              V02PermissionFixture.unchanged(report.baseline, ownerBaseline: ownerBaseline, owner: false, permission: .readOnly) else {
            throw V02Error.invalidEnvelope
        }
    }
}
