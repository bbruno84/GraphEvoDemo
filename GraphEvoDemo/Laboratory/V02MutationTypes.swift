import Foundation
import CloudKit

nonisolated enum V02MutationPhase: String, Codable {
    case original, ownerAdded, ownerDeleted, participantAdded, participantDeleted
}

nonisolated enum V02MutationRole: String, Codable, CaseIterable {
    case ownerAdd = "owner-add"
    case participantSeeOwnerAdd = "participant-see-owner-add"
    case ownerDelete = "owner-delete"
    case participantSeeOwnerDelete = "participant-see-owner-delete"
    case participantAdd = "participant-add"
    case ownerSeeParticipantAdd = "owner-see-participant-add"
    case participantDelete = "participant-delete"
    case ownerSeeParticipantDelete = "owner-see-participant-delete"
    case participantConfirmOwnerAdd = "participant-confirm-owner-add"

    var isOwner: Bool {
        switch self {
        case .ownerAdd, .ownerDelete, .ownerSeeParticipantAdd, .ownerSeeParticipantDelete: true
        default: false
        }
    }
    var writes: Bool { [.ownerAdd, .ownerDelete, .participantAdd, .participantDelete].contains(self) }
    var before: V02MutationPhase {
        switch self {
        case .ownerAdd, .participantSeeOwnerAdd: .original
        case .participantConfirmOwnerAdd: .ownerAdded
        case .ownerDelete, .participantSeeOwnerDelete: .ownerAdded
        case .participantAdd, .ownerSeeParticipantAdd: .ownerDeleted
        case .participantDelete, .ownerSeeParticipantDelete: .participantAdded
        }
    }
    var after: V02MutationPhase {
        switch self {
        case .ownerAdd, .participantSeeOwnerAdd, .participantConfirmOwnerAdd: .ownerAdded
        case .ownerDelete, .participantSeeOwnerDelete: .ownerDeleted
        case .participantAdd, .ownerSeeParticipantAdd: .participantAdded
        case .participantDelete, .ownerSeeParticipantDelete: .participantDeleted
        }
    }
}

nonisolated struct V02MutationRequest {
    let role: V02MutationRole
    let runID: UUID
    let caseID: UUID
    let window: Int
    let priorCaseID: UUID?

    init(role: V02MutationRole, runID: UUID, caseID: UUID, window: Int, priorCaseID: UUID? = nil) {
        self.role = role; self.runID = runID; self.caseID = caseID; self.window = window; self.priorCaseID = priorCaseID
    }

    static func parse(_ arguments: [String]) -> Self? {
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard arguments.contains("--v02-development-verified"),
              let role = value("--v02-mutation-role").flatMap(V02MutationRole.init(rawValue:)),
              let runID = value("--v02-run-id").flatMap(UUID.init(uuidString:)),
              let caseID = value("--v02-case-id").flatMap(UUID.init(uuidString:)),
              let window = Int(value("--v02-window") ?? "90"), (1...600).contains(window) else { return nil }
        let priorCaseID = value("--v02-prior-case-id").flatMap(UUID.init(uuidString:))
        if priorCaseID == caseID || (role == .participantConfirmOwnerAdd && priorCaseID == nil) { return nil }
        return Self(role: role, runID: runID, caseID: caseID, window: window, priorCaseID: priorCaseID)
    }
}

nonisolated enum V02MutationFixture {
    static let ownerValue = "alpha-owner-updated"
    static let participantValue = "beta-participant-updated"

    static func exact(_ rows: [V02Row], phase: V02MutationPhase, owner: Bool) -> Bool {
        var expected = V02Fixture.rows.filter { owner || $0.graph == "A" }
        if phase == .ownerAdded {
            expected.append(("A", "A-003", "item", "owner-delta", "A-root", []))
        }
        if phase == .participantAdded {
            expected.append(("A", "A-004", "item", "participant-delta", "A-root", []))
        }
        guard rows.count == expected.count else { return false }
        let ownerEdited = phase != .original
        let participantEdited = phase == .participantAdded || phase == .participantDeleted
        for target in expected {
            let matches = rows.filter { $0.node == target.node }
            guard matches.count == 1, let row = matches.first else { return false }
            var children = target.children
            if target.node == "A-root" {
                if phase == .ownerAdded { children.append("A-003") }
                if phase == .participantAdded { children.append("A-004") }
            }
            let value = target.node == "A-001" && ownerEdited ? ownerValue :
                target.node == "A-002" && participantEdited ? participantValue : target.value
            guard row.scope == (owner ? .privateStore : .sharedStore),
                  row.graph == target.graph, row.kind == target.kind, row.value == value,
                  row.parent == target.parent, row.children == children.sorted(), row.validClosure,
                  let record = row.record, let share = row.share,
                  record.zoneName == share.id.zoneName,
                  record.zoneOwnerDigest == share.id.zoneOwnerDigest,
                  share.publicPermission == CKShare.ParticipantPermission.none.rawValue else { return false }
            if row.graph == "A" {
                guard share.privateReadWritePair,
                      share.currentUserRole == (owner ? CKShare.ParticipantRole.owner.rawValue : CKShare.ParticipantRole.privateUser.rawValue),
                      share.currentUserPermission == CKShare.ParticipantPermission.readWrite.rawValue,
                      share.participants.allSatisfy({ $0.acceptance == CKShare.ParticipantAcceptanceStatus.accepted.rawValue }) else { return false }
            } else if !share.ownerOnly { return false }
        }
        guard rows.allSatisfy({ row in rows.filter { $0.record == row.record }.count == 1 }) else { return false }
        let a = rows.filter { $0.graph == "A" }.compactMap(\.share)
        guard a.count == (phase == .ownerAdded || phase == .participantAdded ? 4 : 3),
              a.allSatisfy({ $0.id == a.first?.id }) else { return false }
        if owner {
            let b = rows.filter { $0.graph == "B" }.compactMap(\.share)
            guard b.count == 2, b.allSatisfy({ $0.id == b.first?.id }),
                  a.first?.id.zoneName != b.first?.id.zoneName else { return false }
        }
        return true
    }

    static func preserves(_ rows: [V02Row], original: [V02Row], phase: V02MutationPhase, owner: Bool,
                          addedRecord: V02RecordKey?) -> Bool {
        guard exact(rows, phase: phase, owner: owner), exact(original, phase: .original, owner: owner) else { return false }
        if owner, rows.filter({ $0.graph == "B" }) != original.filter({ $0.graph == "B" }) { return false }
        for old in original where old.graph == "A" {
            guard let current = rows.first(where: { $0.node == old.node }),
                  current.record == old.record, current.share?.id == old.share?.id else { return false }
        }
        let addedNode = phase == .ownerAdded ? "A-003" : phase == .participantAdded ? "A-004" : nil
        if let addedNode {
            guard let added = rows.first(where: { $0.node == addedNode }),
                  added.share?.id == original.first(where: { $0.graph == "A" })?.share?.id,
                  added.record != nil, addedRecord == nil || added.record == addedRecord else { return false }
        }
        return true
    }
}

nonisolated struct V02MutationState: Codable {
    let runID: UUID
    let caseID: UUID
    var priorCaseID: UUID? = nil
    let owner: Bool
    let stores: [String: String]
    let original: [V02Row]
    var phase: V02MutationPhase = .original
    var reservedRole: V02MutationRole?
    var ownerAddedRecord: V02RecordKey?
    var participantAddedRecord: V02RecordKey?
}

nonisolated struct V02MutationReport: Codable {
    var procedure = "V02-cross-account-incremental-members-v1"
    let role: V02MutationRole
    let runID: UUID
    let caseID: UUID
    var priorCaseID: UUID?
    let stageID: UUID
    let started: Date
    let windowSeconds: Int
    let environment: [String: String]
    var finished: Date?
    var phase = "Preflight"
    var outcome = "Running; not completed evidence"
    var stores: [String: String] = [:]
    var before: [V02Row] = []
    var members: [V02Row] = []
    var readyForWriter = false
    var mutationSaved = false
    var targetObserved = false
    var firstTargetAt: Date?
    var sampleCount = 0
    var fullWindowObserved = false
    var events: [V01NativeEvent] = []
    var droppedEvents = 0
    var errors: [String] = []
    var storesDetached = false
    var finalReportRetained = false
}
