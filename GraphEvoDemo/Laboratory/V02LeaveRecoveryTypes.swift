import Foundation
import CloudKit

nonisolated enum V02LeaveRecoveryRole: String, Codable, CaseIterable {
    case participant = "participant-fresh"
    case owner = "owner-snapshot"
}

nonisolated struct V02LeaveRecoveryRequest {
    let role: V02LeaveRecoveryRole
    let runID: UUID
    let caseID: UUID
    let priorCaseID: UUID
    let window: Int

    static func parse(_ arguments: [String]) -> Self? {
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard arguments.contains("--v02-development-verified"),
              let role = value("--v02-leave-recovery-role").flatMap(V02LeaveRecoveryRole.init(rawValue:)),
              let run = value("--v02-run-id").flatMap(UUID.init(uuidString:)),
              let id = value("--v02-case-id").flatMap(UUID.init(uuidString:)),
              let prior = value("--v02-prior-case-id").flatMap(UUID.init(uuidString:)), id != prior,
              let window = Int(value("--v02-window") ?? "180"), (1...600).contains(window) else { return nil }
        return Self(role: role, runID: run, caseID: id, priorCaseID: prior, window: window)
    }
}

/// Structured codes only: CloudKit error descriptions and partial-error dictionary keys can contain sensitive IDs.
nonisolated struct V02PublicReadError: Codable {
    let domain: String
    let code: Int
    let cloudKitCode: String?
    let retryAfterSeconds: Double?
    static func capture(_ error: Error, depth: Int = 0) -> [Self] {
        guard depth < 4 else { return [] }
        let ns = error as NSError
        let ck = error as? CKError
        var result = [Self(domain: ns.domain, code: ns.code, cloudKitCode: ck.map { String(describing: $0.code) },
                           retryAfterSeconds: ns.userInfo[CKErrorRetryAfterKey] as? Double)]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { result += capture(underlying, depth: depth + 1) }
        if let partial = ns.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            for child in partial.values.prefix(3) { result += capture(child, depth: depth + 1) }
        }
        return Array(result.prefix(16))
    }
}

nonisolated struct V02LeaveMetadata: Codable {
    var api = "CKContainer.shareMetadata(for:)"
    let requestedAt: Date
    var completedAt: Date?
    var returnedMetadata = false
    var participantStatus: Int?
    var participantRole: Int?
    var participantPermission: Int?
    var publicPermission: Int?
    var containerMatches: Bool?
    var ownerMatches: Bool?
    var shareMatches: Bool?
    var shareID: V02RecordKey?
    var errors: [V02PublicReadError] = []
}

nonisolated enum V02LeaveRecoveryFixture {
    static func exactA(_ rows: [V02Row], original: [V02Row]) -> Bool {
        guard original.count == 3, V02Fixture.exact(rows, owner: false, edited: true, requireShares: false) else { return false }
        return rows.allSatisfy { row in
            guard let old = original.first(where: { $0.node == row.node }), let record = row.record, let share = row.share else { return false }
            return row.scope == .sharedStore && record == old.record && share.id == old.share?.id
        }
    }
    static func ownerData(_ rows: [V02Row], original: [V02Row]) -> Bool {
        guard V02Fixture.exact(rows, owner: true, edited: true, requireShares: false), original.count == 5 else { return false }
        return rows.allSatisfy { row in
            guard let old = original.first(where: { $0.node == row.node }), let record = row.record, let share = row.share else { return false }
            return record == old.record && share.id == old.share?.id && (row.graph != "B" || row == old)
        }
    }
}

nonisolated struct V02LeaveRecoveryReport: Codable {
    var procedure = "V02-post-leave-read-only-recovery-v1"
    let role: V02LeaveRecoveryRole
    let runID: UUID
    let caseID: UUID
    let priorCaseID: UUID
    let stageID: UUID
    let processID: UUID
    let started: Date
    let windowSeconds: Int
    let environment: [String: String]
    var finished: Date?
    var phase = "Preflight"
    var outcome = "Running; not completed evidence"
    var stores: [String: String] = [:]
    var priorStores: [String: String] = [:]
    var freshReplicaRequested = false
    var probePathPermanentlyConsumed = false
    var metadataBefore: V02LeaveMetadata?
    var metadataAfter: V02LeaveMetadata?
    var observationStarted: Date?
    var observationFinished: Date?
    var fullWindowObserved = false
    var openingSnapshot: [V02Row] = []
    var firstRecoveryAt: Date?
    var firstRecoveredRows: [V02Row] = []
    var members: [V02Row] = []
    var sampleCount = 0
    var emptySampleCount = 0
    var observedB = false
    var observedPrivateCopy = false
    var ownerDataMatches: Bool?
    var events: [V01NativeEvent] = []
    var droppedEvents = 0
    var snapshotErrors: [V02PublicReadError] = []
    var errors: [V02PublicReadError] = []
    var traceWriteFailures = 0
    var traceDroppedEntries = 0
    var storesDetached = false
    var finalReportRetained = false
    var observationLimit = "A bounded negative fresh-store observation cannot establish permanent access denial, server membership, or a synchronization deadline. Metadata errors alone do not establish permission state."
}
