import Foundation
import CloudKit
import CryptoKit

nonisolated enum V02Role: String, Codable, CaseIterable {
    case identity, ownerPrepare = "owner-prepare", ownerInvite = "owner-invite"
    case participantAccept = "participant-accept", participantEdit = "participant-edit"
    case ownerObserve = "owner-observe", ownerReopen = "owner-reopen", participantReopen = "participant-reopen"
    var isOwner: Bool { [.ownerPrepare, .ownerInvite, .ownerObserve, .ownerReopen].contains(self) }
    var createsStores: Bool { self == .ownerPrepare || self == .participantAccept }
}

nonisolated struct V02Request {
    let role: V02Role
    let runID: UUID
    let window: Int
    let input: String?
    let invitationAuthorized: Bool

    static func parse(_ arguments: [String]) -> V02Request? {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: key), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard arguments.contains("--v02-development-verified"),
              let role = value("--v02-role").flatMap(V02Role.init(rawValue:)),
              let id = value("--v02-run-id").flatMap(UUID.init(uuidString:)),
              let window = Int(value("--v02-window") ?? "120"), (1...600).contains(window) else { return nil }
        let input = value("--v02-input")
        if let input, !validFilename(input) { return nil }
        let authorized = arguments.contains("--v02-invitation-authorized")
        if role == .ownerInvite && (!authorized || input == nil) { return nil }
        if role == .participantAccept && input == nil { return nil }
        return V02Request(role: role, runID: id, window: window, input: input, invitationAuthorized: authorized)
    }

    static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name.count < 100 && name.hasSuffix(".json") &&
        name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0) } &&
        !name.contains("..")
    }
}

nonisolated enum V02Scope: String, Codable, CaseIterable { case privateStore = "private", sharedStore = "shared" }

nonisolated struct V02RecordKey: Codable, Equatable {
    let recordName: String
    let zoneName: String
    let zoneOwnerDigest: String
    static func make(_ id: CKRecord.ID, currentUser: CKRecord.ID, runID: UUID) -> Self {
        let owner = id.zoneID.ownerName == CKCurrentUserDefaultName ? currentUser.recordName : id.zoneID.ownerName
        let digest = SHA256.hash(data: Data((runID.uuidString + "|" + owner).utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(recordName: id.recordName, zoneName: id.zoneID.zoneName, zoneOwnerDigest: digest)
    }
}

nonisolated struct V02Participant: Codable, Equatable {
    let role: Int
    let permission: Int
    let acceptance: Int
}

nonisolated struct V02ShareInfo: Codable, Equatable {
    let id: V02RecordKey
    let publicPermission: Int
    let currentUserRole: Int?
    let currentUserPermission: Int?
    let currentUserAcceptance: Int?
    let participants: [V02Participant]
    var privateReadWritePair: Bool {
        publicPermission == CKShare.ParticipantPermission.none.rawValue && participants.count == 2 &&
        participants.filter { $0.role == CKShare.ParticipantRole.owner.rawValue }.count == 1 &&
        participants.filter { $0.role == CKShare.ParticipantRole.privateUser.rawValue && $0.permission == CKShare.ParticipantPermission.readWrite.rawValue }.count == 1
    }
    var ownerOnly: Bool {
        publicPermission == CKShare.ParticipantPermission.none.rawValue && participants.count == 1 &&
        participants.first?.role == CKShare.ParticipantRole.owner.rawValue
    }
}

nonisolated struct V02Row: Codable, Equatable {
    let scope: V02Scope
    let graph: String?
    let node: String?
    let kind: String?
    let value: String?
    let parent: String?
    let children: [String]
    let validClosure: Bool
    let record: V02RecordKey?
    let share: V02ShareInfo?
}

nonisolated enum V02Fixture {
    static let editedValue = "alpha-from-participant"
    static let rows: [(graph: String, node: String, kind: String, value: String, parent: String?, children: [String])] = [
        ("A", "A-root", "root", "A", nil, ["A-001", "A-002"]),
        ("A", "A-001", "item", "alpha", "A-root", []),
        ("A", "A-002", "item", "beta", "A-root", []),
        ("B", "B-root", "root", "B", nil, ["B-001"]),
        ("B", "B-001", "item", "gamma", "B-root", [])]

    static func exact(_ actual: [V02Row], owner: Bool, edited: Bool, requireShares: Bool = true) -> Bool {
        let expected = rows.filter { owner || $0.graph == "A" }
        guard actual.count == expected.count else { return false }
        for expected in expected {
            let matches = actual.filter { $0.node == expected.node }
            guard matches.count == 1, let row = matches.first,
                  row.scope == (owner ? .privateStore : .sharedStore), row.graph == expected.graph,
                  row.kind == expected.kind, row.value == (edited && expected.node == "A-001" ? editedValue : expected.value),
                  row.parent == expected.parent, row.children == expected.children, row.validClosure else { return false }
            if requireShares {
                guard let record = row.record, let share = row.share,
                      record.zoneName == share.id.zoneName, record.zoneOwnerDigest == share.id.zoneOwnerDigest,
                      share.publicPermission == CKShare.ParticipantPermission.none.rawValue else { return false }
                if expected.graph == "A" {
                    guard share.privateReadWritePair,
                          share.currentUserRole == (owner ? CKShare.ParticipantRole.owner.rawValue : CKShare.ParticipantRole.privateUser.rawValue),
                          share.currentUserPermission == CKShare.ParticipantPermission.readWrite.rawValue,
                          share.participants.allSatisfy({ $0.acceptance == CKShare.ParticipantAcceptanceStatus.accepted.rawValue }) else { return false }
                } else if !share.ownerOnly { return false }
            }
        }
        if requireShares {
            let a = actual.filter { $0.graph == "A" }.compactMap(\.share)
            guard a.count == 3, a.allSatisfy({ $0.id == a.first?.id }) else { return false }
            if owner {
                let b = actual.filter { $0.graph == "B" }.compactMap(\.share)
                guard b.count == 2, b.allSatisfy({ $0.id == b.first?.id }), a.first?.id.zoneName != b.first?.id.zoneName else { return false }
            }
        }
        return true
    }

    static func prepared(_ actual: [V02Row], invited: Bool) -> Bool {
        guard exact(actual, owner: true, edited: false, requireShares: false) else { return false }
        for graph in ["A", "B"] {
            let rows = actual.filter { $0.graph == graph }
            guard let share = rows.first?.share,
                  rows.allSatisfy({ $0.share?.id == share.id && $0.record?.zoneName == share.id.zoneName &&
                      $0.record?.zoneOwnerDigest == share.id.zoneOwnerDigest }),
                  share.currentUserRole == CKShare.ParticipantRole.owner.rawValue,
                  (graph == "A" && invited ? share.privateReadWritePair : share.ownerOnly) else { return false }
        }
        return actual.first(where: { $0.graph == "A" })?.share?.id.zoneName != actual.first(where: { $0.graph == "B" })?.share?.id.zoneName
    }
}

// Sensitive transport envelopes are retained only in the app's private Sensitive directory.
// They must never be encoded into a V02Report or printed to the console.
nonisolated struct V02PrivateID: Codable, Equatable {
    let recordName: String
    let zoneName: String
    let ownerName: String
    init(_ id: CKRecord.ID) { recordName = id.recordName; zoneName = id.zoneID.zoneName; ownerName = id.zoneID.ownerName }
    var recordID: CKRecord.ID { CKRecord.ID(recordName: recordName, zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)) }
    func matches(_ other: CKRecord.ID, shareOwner: CKRecord.ID) -> Bool {
        func canonical(_ owner: String) -> String { owner == CKCurrentUserDefaultName ? shareOwner.recordName : owner }
        return recordName == other.recordName && zoneName == other.zoneID.zoneName &&
            canonical(ownerName) == canonical(other.zoneID.ownerName)
    }
}

nonisolated struct V02Envelope: Codable {
    var version = 1
    let purpose: String
    let runID: UUID
    let containerIdentifier: String
    let account: V02PrivateID
    var recipient: V02PrivateID?
    var share: V02PrivateID?
    var shareURL: URL?
    var caseID: UUID?
    func validate(runID: UUID, container: String, purpose: String) throws {
        guard version == 1, self.runID == runID, containerIdentifier == container, self.purpose == purpose,
              !account.recordName.isEmpty else { throw V02Error.invalidEnvelope }
    }
}

nonisolated enum V02Error: Int, Error {
    case invalidEnvelope = 1, invalidAccount, missingStores, existingStores, invalidFixture, invalidShare
    case unauthorizedInvitation, unexpectedParticipant, missingResponse, invalidMetadata, editNotReady, retentionFailure
}
