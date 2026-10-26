import Foundation
import CloudKit

nonisolated enum V01MembershipPhase: String, Codable, CaseIterable { case original, added, deleted }
nonisolated enum V01MembershipRole: String, Codable, CaseIterable {
    case prepare = "writer-prepare", add = "writer-add", delete = "writer-delete", reopen = "writer-reopen", reader
    var mutates: Bool { self == .prepare || self == .add || self == .delete }
}

nonisolated struct V01MembershipRequest {
    let role: V01MembershipRole
    let runID: UUID
    let phase: V01MembershipPhase
    let window: Int
    static func parse(_ arguments: [String]) -> Self? {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: key), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard arguments.contains("--v01-membership-development-verified"),
              let role = value("--v01-membership-role").flatMap(V01MembershipRole.init(rawValue:)),
              let run = value("--v01-membership-run-id").flatMap(UUID.init(uuidString:)),
              let window = Int(value("--v01-membership-window") ?? "60"), (1...600).contains(window) else { return nil }
        let phase: V01MembershipPhase
        switch role {
        case .prepare: phase = .original
        case .add: phase = .added
        case .delete: phase = .deleted
        case .reader, .reopen:
            guard let supplied = value("--v01-membership-phase").flatMap(V01MembershipPhase.init(rawValue:)) else { return nil }
            phase = supplied
        }
        if let supplied = value("--v01-membership-phase"), supplied != phase.rawValue { return nil }
        return Self(role: role, runID: run, phase: phase, window: window)
    }
}

nonisolated enum V01MembershipFixture {
    static let addedNode = "A-003"
    static let updatedValue = "alpha-updated"

    static func exact(_ actual: [V02Row], phase: V01MembershipPhase, requireShares: Bool = true) -> Bool {
        var expected = V02Fixture.rows
        if phase == .added { expected.append(("A", addedNode, "item", "delta", "A-root", [])) }
        guard actual.count == expected.count else { return false }
        for target in expected {
            let matches = actual.filter { $0.node == target.node }
            var children = target.children
            if phase == .added && target.node == "A-root" { children.append(addedNode) }
            guard matches.count == 1, let row = matches.first,
                  row.scope == .privateStore, row.graph == target.graph, row.kind == target.kind,
                  row.value == (phase != .original && target.node == "A-001" ? updatedValue : target.value),
                  row.parent == target.parent, row.children == children, row.validClosure else { return false }
            if requireShares {
                guard let share = row.share, let record = row.record, share.ownerOnly,
                      share.currentUserRole == CKShare.ParticipantRole.owner.rawValue,
                      record.zoneName == share.id.zoneName, record.zoneOwnerDigest == share.id.zoneOwnerDigest else { return false }
            }
        }
        if requireShares {
            guard actual.allSatisfy({ row in actual.filter { $0.record == row.record }.count == 1 }) else { return false }
            let a = actual.filter { $0.graph == "A" }.compactMap(\.share)
            let b = actual.filter { $0.graph == "B" }.compactMap(\.share)
            guard a.count == (phase == .added ? 4 : 3), b.count == 2,
                  a.allSatisfy({ $0.id == a.first?.id }), b.allSatisfy({ $0.id == b.first?.id }),
                  a.first?.id.zoneName != b.first?.id.zoneName else { return false }
        }
        return true
    }

    static func preserved(_ actual: [V02Row], original: [V02Row], added: [V02Row], phase: V01MembershipPhase) -> Bool {
        guard exact(actual, phase: phase), exact(original, phase: .original) else { return false }
        // B is compared in full, including permissions, scope, links and cloud identities.
        guard actual.filter({ $0.graph == "B" }) == original.filter({ $0.graph == "B" }) else { return false }
        for old in original where old.graph == "A" {
            guard let row = actual.first(where: { $0.node == old.node }), row.record == old.record, row.share == old.share else { return false }
        }
        if phase == .added {
            guard let new = actual.first(where: { $0.node == addedNode }), let originalA = original.first(where: { $0.graph == "A" }),
                  new.share?.id == originalA.share?.id else { return false }
            if let priorNew = added.first(where: { $0.node == addedNode }), new.record != priorNew.record { return false }
        }
        return true
    }
}

nonisolated enum V01MembershipProgress: String, Codable { case preparing, ready, adding, added, deleting, deleted }
nonisolated struct V01MembershipLedger: Codable {
    let runID: UUID
    var progress: V01MembershipProgress = .preparing
    var writerStores: [String: String] = [:]
    var original: [V02Row] = []
    var added: [V02Row] = []
    var deleted: [V02Row] = []
    func phaseIsReady(_ phase: V01MembershipPhase) -> Bool {
        switch phase {
        case .original: return progress == .ready
        case .added: return progress == .added
        case .deleted: return progress == .deleted
        }
    }
}

nonisolated struct V01MembershipReport: Codable {
    var procedure = "V01-incremental-membership-relation-save-v1"
    let runID: UUID
    let stageID: UUID
    let processID: UUID
    let role: V01MembershipRole
    let expectedPhase: V01MembershipPhase
    let windowSeconds: Int
    let started: Date
    let environment: [String: String]
    var finished: Date?
    var phase = "Preflight"
    var outcome = "Running; not completed evidence"
    var topology = "One private SQLite; owner-only A/B; fresh reader is preliminary on the same device"
    var stores: [String: String] = [:]
    var original: [V02Row] = []
    var baseline: [V02Row] = []
    var precondition: [V02Row] = []
    var members: [V02Row] = []
    var fixtureSaved = false
    var localMutationSaved = false
    var initialShareCreationCalls = 0
    var explicitExistingShareCalls = 0
    var exactFixture = false
    var preservedIdentities = false
    var events: [V01NativeEvent] = []
    var droppedEvents = 0
    var errors: [String] = []
    var traceWriteFailures = 0
    var traceDroppedEntries = 0
    var finalReportRetained = false
}
