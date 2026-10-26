import CloudKit
import Darwin
import Foundation
import UIKit

nonisolated enum V09Phase: String, Codable, CaseIterable {
    case prepared, invited, baseline, smallAdded, largeAdded, largeReplaced
    case largeDeleted, graphAdded, graphEdited, graphDeleted
    case graphOnlyAdded, graphOnlyEdited, graphOnlyDeleted
    case concurrentDisjoint
}

nonisolated enum V09Role: String, Codable {
    case identity, ownerSeed = "owner-seed", ownerInvite = "owner-invite"
    case participantAccept = "participant-accept"
    case ownerSmall = "owner-small", ownerLarge = "owner-large"
    case participantReplace = "participant-replace", participantDelete = "participant-delete"
    case participantGraphAdd = "participant-graph-add", participantGraphEdit = "participant-graph-edit"
    case ownerGraphDelete = "owner-graph-delete"
    case participantGraphAddOnly = "participant-graph-add-only"
    case participantGraphEditOnly = "participant-graph-edit-only"
    case ownerGraphDeleteOnly = "owner-graph-delete-only"
    case ownerConcurrent = "owner-concurrent", participantConcurrent = "participant-concurrent"
    case read

    var writes: Bool { self != .read && self != .identity }
    var createsStores: Bool { self == .ownerSeed || self == .participantAccept }
    var isOwner: Bool {
        [.ownerSeed, .ownerInvite, .ownerSmall, .ownerLarge,
         .ownerGraphDelete, .ownerGraphDeleteOnly, .ownerConcurrent].contains(self)
    }
    var before: V09Phase? {
        switch self {
        case .ownerSeed, .identity, .read: nil
        case .ownerInvite: .prepared
        case .participantAccept: nil
        case .ownerSmall: .baseline
        case .ownerLarge: .smallAdded
        case .participantReplace: .largeAdded
        case .participantDelete: .largeReplaced
        case .participantGraphAdd: .largeDeleted
        case .participantGraphEdit: .graphAdded
        case .ownerGraphDelete: .graphEdited
        case .participantGraphAddOnly: .baseline
        case .participantGraphEditOnly: .graphOnlyAdded
        case .ownerGraphDeleteOnly: .graphOnlyEdited
        case .ownerConcurrent, .participantConcurrent: .baseline
        }
    }
    var after: V09Phase? {
        switch self {
        case .identity, .read: nil
        case .ownerSeed: .prepared
        case .ownerInvite: .invited
        case .participantAccept: .baseline
        case .ownerSmall: .smallAdded
        case .ownerLarge: .largeAdded
        case .participantReplace: .largeReplaced
        case .participantDelete: .largeDeleted
        case .participantGraphAdd: .graphAdded
        case .participantGraphEdit: .graphEdited
        case .ownerGraphDelete: .graphDeleted
        case .participantGraphAddOnly: .graphOnlyAdded
        case .participantGraphEditOnly: .graphOnlyEdited
        case .ownerGraphDeleteOnly: .graphOnlyDeleted
        case .ownerConcurrent, .participantConcurrent: .concurrentDisjoint
        }
    }
}

nonisolated struct V09Request {
    let role: V09Role
    let runID: UUID
    let window: Int
    let input: String?
    let owner: Bool
    let expected: V09Phase?
    let invitationAuthorized: Bool
    let startUnix: Int?

    static func parse(_ arguments: [String]) -> V09Request? {
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard arguments.contains("--v09-development-verified"),
              let role = value("--v09-role").flatMap(V09Role.init(rawValue:)),
              let runID = value("--v09-run-id").flatMap(UUID.init(uuidString:)),
              let window = Int(value("--v09-window") ?? "180"), (1...600).contains(window) else { return nil }
        let input = value("--v09-input")
        if let input, !V02Request.validFilename(input) { return nil }
        let owner = value("--v09-side") == "owner"
        let expected = value("--v09-expect").flatMap(V09Phase.init(rawValue:))
        let invitationAuthorized = arguments.contains("--v09-invitation-authorized")
        let startUnix = value("--v09-start-unix").flatMap(Int.init)
        guard role != .ownerInvite || (invitationAuthorized && input != nil),
              role != .participantAccept || input != nil,
              role != .read || (expected != nil && ["owner", "participant"].contains(value("--v09-side"))),
              ![V09Role.ownerConcurrent, .participantConcurrent].contains(role) || startUnix != nil else {
            return nil
        }
        return V09Request(role: role, runID: runID, window: window, input: input, owner: owner,
                          expected: expected, invitationAuthorized: invitationAuthorized, startUnix: startUnix)
    }
}

/// Exact application-visible structure and zone identity, with no dependence
/// on CloudKit's internal record layout or asynchronous event ordering.
nonisolated enum V09Fixture {
    static func exact(_ rows: [V09Row], owner: Bool, phase: V09Phase) -> Bool {
        let base = ["root", "entity-1", "entity-2", "relationship", "action"]
        var a = Set(base.map { "A-" + $0 })
        let b = Set(base.map { "B-" + $0 })
        if [.smallAdded, .largeAdded, .largeReplaced, .largeDeleted,
            .graphAdded, .graphEdited, .graphDeleted].contains(phase) { a.insert("A-file-small") }
        if [.largeAdded, .largeReplaced].contains(phase) { a.insert("A-file-large") }
        if [.graphAdded, .graphEdited, .graphOnlyAdded, .graphOnlyEdited].contains(phase) {
            a.formUnion(["A-entity-3", "A-relationship-2", "A-action-2"])
        }
        guard Set(rows.map(\.id)) == (owner ? a.union(b) : a),
              rows.count == (owner ? a.count + b.count : a.count),
              rows.allSatisfy({ $0.scope == (owner ? .privateStore : .sharedStore) }) else { return false }

        func validGraph(_ graph: String) -> Bool {
            let members = rows.filter { $0.graph == graph }
            guard let root = members.first(where: { $0.id == graph + "-root" }),
                  root.kind == "root", root.parent == nil else { return false }
            for number in [1, 2] {
                guard let entity = members.first(where: { $0.id == graph + "-entity-\(number)" }),
                      entity.kind == "entity", entity.parent == root.id,
                  entity.label == (
                    graph == "A" && phase == .concurrentDisjoint
                        ? (number == 1 ? "owner-concurrent" : "participant-concurrent")
                        : (graph == "A" && number == 1 &&
                           [.graphEdited, .graphDeleted, .graphOnlyEdited, .graphOnlyDeleted].contains(phase)
                            ? "participant-edited" : (number == 1 ? "first" : "second"))
                  ) else { return false }
            }
            guard let edge = members.first(where: { $0.id == graph + "-relationship" }),
                  edge.kind == "relationship", edge.parent == root.id,
                  edge.source == graph + "-entity-1", edge.target == graph + "-entity-2",
                  let action = members.first(where: { $0.id == graph + "-action" }),
                  action.kind == "action", action.parent == root.id,
                  action.subjects == [graph + "-entity-1", graph + "-entity-2"],
                  action.objects == [graph + "-entity-2"] else { return false }
            return true
        }
        guard validGraph("A"), (!owner || validGraph("B")) else { return false }
        if a.contains("A-file-small") {
            guard let file = rows.first(where: { $0.id == "A-file-small" }),
                  file.kind == "attachment", file.parent == "A-root", file.fileOwner == "A-entity-1",
                  file.filename == "small.bin", file.contentType == "application/octet-stream",
                  file.byteCount == 512, file.checksumMatches == true else { return false }
        }
        if a.contains("A-file-large") {
            guard let file = rows.first(where: { $0.id == "A-file-large" }),
                  file.kind == "attachment", file.parent == "A-root", file.fileOwner == "A-entity-1",
                  file.filename == (phase == .largeReplaced ? "large-replaced.bin" : "large.bin"),
                  file.byteCount == 10 * 1_024 * 1_024, file.checksumMatches == true else { return false }
        }
        if a.contains("A-entity-3") {
            guard let third = rows.first(where: { $0.id == "A-entity-3" }),
                  third.kind == "entity", third.parent == "A-root",
                  let edge = rows.first(where: { $0.id == "A-relationship-2" }),
                  edge.kind == "relationship", edge.parent == "A-root",
                  edge.source == third.id, edge.target == "A-entity-2",
                  let action = rows.first(where: { $0.id == "A-action-2" }),
                  action.kind == "action", action.parent == "A-root",
                  action.subjects == ["A-entity-1", third.id],
                  action.objects == ["A-entity-2"] else { return false }
        }
        for row in rows {
            guard let record = row.record, let share = row.share,
                  record.zoneName == share.id.zoneName,
                  record.zoneOwnerDigest == share.id.zoneOwnerDigest,
                  share.publicPermission == CKShare.ParticipantPermission.none.rawValue,
                  row.checksumMatches != false else { return false }
        }
        let aShares = rows.filter { $0.graph == "A" }.compactMap(\.share)
        guard aShares.count == a.count, aShares.allSatisfy({ $0.id == aShares.first?.id }) else { return false }
        if phase == .prepared {
            guard aShares.allSatisfy(\.ownerOnly) else { return false }
        } else {
            guard aShares.allSatisfy(\.privateReadWritePair) else { return false }
            if phase != .invited {
                guard aShares.allSatisfy({
                    $0.participants.allSatisfy {
                        $0.acceptance == CKShare.ParticipantAcceptanceStatus.accepted.rawValue
                    }
                }) else { return false }
            }
        }
        if owner {
            let bShares = rows.filter { $0.graph == "B" }.compactMap(\.share)
            guard bShares.count == b.count, bShares.allSatisfy({ $0.id == bShares.first?.id && $0.ownerOnly }),
                  aShares.first?.id.zoneName != bShares.first?.id.zoneName else { return false }
        }
        return true
    }
}

nonisolated struct V09Report: Codable {
    var procedure = "V09-graph-file-direct-framework-v1"
    let runID: UUID
    let stageID: UUID
    let role: V09Role
    let started: Date
    let environment: [String: String]
    var finished: Date?
    var phase = "Preflight"
    var outcome = "Running; not completed evidence"
    var expected: V09Phase?
    var before: [V09Row] = []
    var after: [V09Row] = []
    var writeCompleted = false
    var exactObserved = false
    var elapsedWriteSeconds: Double?
    var sensitiveArtifact: String?
    var events: [V01NativeEvent] = []
    var droppedEvents = 0
    var errors: [String] = []
    var failurePhase: String?
    var finalReportRetained = false
}

@MainActor
final class V09GraphFileSession {
    static let shared = V09GraphFileSession()
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("V09Laboratory")
    private var started = false
    private(set) var report: V09Report?
    var didChange: ((String) -> Void)?

    func run(_ request: V09Request, cloudIdentifier: String) async {
        guard !started else { return }
        started = true
        let stageID = UUID()
        let reportURL = root.appendingPathComponent(
            "Reports/\(request.runID)-\(request.role.rawValue)-\(stageID).json")
        var environment = Dictionary(uniqueKeysWithValues: [
            "LaboratoryDemoRevision", "LaboratoryGraphEvoRevision",
            "LaboratorySourceState", "LaboratoryToolchain"
        ].map { ($0, Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "Unrecorded") })
        environment["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        environment["deviceClass"] = UIDevice.current.model
        environment["topology"] = "One CloudKit container with private and shared Core Data stores"
        report = V09Report(runID: request.runID, stageID: stageID, role: request.role,
                           started: Date(), environment: environment)
        var store: V09GraphFileStore?
        func persist() throws {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: reportURL, options: .atomic)
            didChange?(String(decoding: data, as: UTF8.self))
        }
        func checkpoint(_ message: String) throws { report?.phase = message; try persist() }
        func reserveWrite() throws {
            let ticket = root.appendingPathComponent("Tickets/\(request.runID)-\(request.role.rawValue)")
            try FileManager.default.createDirectory(at: ticket.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(ticket.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard descriptor >= 0 else {
                throw V09Error.invalidFixture
            }
            _ = close(descriptor)
        }
        do {
            try persist()
            guard !GraphProvider.wasInitialized, !cloudIdentifier.isEmpty else { throw V01Error.missingConfiguration }
            #if targetEnvironment(simulator)
            throw V01Error.missingConfiguration
            #endif
            let cloud = CKContainer(identifier: cloudIdentifier)
            guard try await cloud.accountStatus() == .available else { throw V01Error.accountUnavailable }
            let currentUser = try await cloud.userRecordID()
            let sensitive = root.appendingPathComponent("Sensitive/\(request.runID)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
            if request.role == .identity {
                let file = sensitive.appendingPathComponent("participant-identity.json")
                try V02SensitiveFiles.write(V02Envelope(purpose: "participant-identity", runID: request.runID,
                    containerIdentifier: cloudIdentifier, account: V02PrivateID(currentUser)), to: file)
                report?.sensitiveArtifact = file.lastPathComponent
                report?.outcome = "Participant identity retained; no store or share operation."
            } else {
                let isOwner = request.role == .read ? request.owner : request.role.isOwner
                let side = isOwner ? "owner" : "participant"
                let bindingURL = sensitive.appendingPathComponent(side + "-binding.json")
                if request.role.createsStores {
                    try V02SensitiveFiles.write(V02Envelope(purpose: "account-binding", runID: request.runID,
                        containerIdentifier: cloudIdentifier, account: V02PrivateID(currentUser)), to: bindingURL)
                } else {
                    let binding = try V02SensitiveFiles.read(bindingURL)
                    try binding.validate(runID: request.runID, container: cloudIdentifier, purpose: "account-binding")
                    guard binding.account.recordID == currentUser else { throw V09Error.unexpectedAccount }
                }
                let opened = V09GraphFileStore(currentUser: currentUser)
                store = opened
                try checkpoint(request.role.createsStores ? "Opening fresh stores" : "Reopening existing stores")
                try await opened.open(directory: root.appendingPathComponent("Stores/\(request.runID)/" + side),
                                      cloudIdentifier: cloudIdentifier, fresh: request.role.createsStores) { [weak self] event in
                    guard let self, self.report?.finished == nil else { return }
                    if self.report?.events.count ?? 0 < 128 { self.report?.events.append(event) }
                    else { self.report?.droppedEvents += 1 }
                }
                report?.before = try await opened.snapshot(runID: request.runID)
                try persist()
                if let before = request.role.before {
                    let deadline = Date().addingTimeInterval(TimeInterval(request.window))
                    while !V09Fixture.exact(report?.before ?? [], owner: isOwner, phase: before) {
                        guard Date() < deadline else { throw V09Error.invalidFixture }
                        try checkpoint("Waiting for complete previous-phase data and share metadata")
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        report?.before = try await opened.snapshot(runID: request.runID)
                        try persist()
                    }
                }
                if request.role == .ownerSeed {
                    guard report?.before.isEmpty == true else { throw V09Error.invalidFixture }
                }
                if request.role == .participantAccept {
                    guard report?.before.isEmpty == true else { throw V09Error.invalidFixture }
                }
                let target = request.role == .read ? request.expected : request.role.after
                report?.expected = target
                if request.role.writes {
                    let ticket = root.appendingPathComponent("Tickets/\(request.runID)-\(request.role.rawValue)")
                    guard !FileManager.default.fileExists(atPath: ticket.path) else { throw V09Error.invalidFixture }
                    try checkpoint("Reserving single-write stage")
                    try reserveWrite()
                    if let startUnix = request.startUnix {
                        let delay = Double(startUnix) - Date().timeIntervalSince1970
                        guard delay > 0, delay <= 120 else { throw V09Error.invalidFixture }
                        try checkpoint("Waiting for coordinated write start")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    let startedWrite = Date()
                    switch request.role {
                    case .ownerSeed:
                        try await opened.seed(runID: request.runID)
                        for graph in ["A", "B"] {
                            try checkpoint("Creating owner-only share for " + graph)
                            try await opened.createShare(graph, runID: request.runID) { try persist() }
                        }
                    case .ownerInvite:
                        guard request.invitationAuthorized, let input = request.input else { throw V09Error.invalidFixture }
                        let identity = try V02SensitiveFiles.read(root.appendingPathComponent("Inbox/" + input))
                        try checkpoint("Inviting the specified participant to A")
                        let invitation = try await opened.invite(identity, runID: request.runID,
                                                                 cloudIdentifier: cloudIdentifier) { try persist() }
                        let file = sensitive.appendingPathComponent("private-invitation.json")
                        try V02SensitiveFiles.write(invitation, to: file)
                        report?.sensitiveArtifact = file.lastPathComponent
                    case .participantAccept:
                        guard let input = request.input else { throw V09Error.invalidFixture }
                        let invitation = try V02SensitiveFiles.read(root.appendingPathComponent("Inbox/" + input))
                        try checkpoint("Accepting the specified A invitation")
                        try await opened.accept(invitation, runID: request.runID,
                                                cloudIdentifier: cloudIdentifier) { try persist() }
                    case .ownerSmall: try await opened.addAttachment(runID: request.runID, large: false)
                    case .ownerLarge: try await opened.addAttachment(runID: request.runID, large: true)
                    case .participantReplace: try await opened.replaceLargeAttachment(runID: request.runID)
                    case .participantDelete: try await opened.deleteLargeAttachment(runID: request.runID)
                    case .participantGraphAdd, .participantGraphAddOnly:
                        try await opened.addParticipantGraphMembers(runID: request.runID) { try persist() }
                    case .participantGraphEdit, .participantGraphEditOnly:
                        try await opened.editExistingEntity(runID: request.runID)
                    case .ownerGraphDelete, .ownerGraphDeleteOnly:
                        try await opened.deleteParticipantGraphMembers(runID: request.runID)
                    case .ownerConcurrent:
                        try await opened.editDisjointEntity(runID: request.runID, ownerSide: true)
                    case .participantConcurrent:
                        try await opened.editDisjointEntity(runID: request.runID, ownerSide: false)
                    case .identity, .read: break
                    }
                    report?.elapsedWriteSeconds = Date().timeIntervalSince(startedWrite)
                    report?.writeCompleted = true
                    try persist()
                }
                if let target {
                    let deadline = Date().addingTimeInterval(TimeInterval(request.window))
                    repeat {
                        let rows = try await opened.snapshot(runID: request.runID)
                        report?.after = rows
                        report?.exactObserved = V09Fixture.exact(rows, owner: isOwner, phase: target)
                        try persist()
                        if report?.exactObserved == true { break }
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    } while Date() < deadline
                    let observed = report?.exactObserved == true
                    report?.outcome = observed
                        ? "Exact graph, file checksum, store scope and share zone observed."
                        : "Inconclusive: expected state not observed in the bounded window."
                }
            }
        } catch {
            let failedAt = report?.phase
            report?.failurePhase = failedAt
            report?.errors.append(v01ErrorCode(error))
            report?.outcome = "Stage failed; do not replay its reserved write or invitation."
        }
        do { try await store?.close() }
        catch { report?.errors.append("Close: " + v01ErrorCode(error)) }
        report?.finished = Date()
        report?.phase = "Finished; stores detached"
        report?.finalReportRetained = true
        do { try persist() }
        catch {
            report?.finalReportRetained = false
            didChange?("Final report retention failed; do not use partial checkpoints as evidence.")
        }
    }
}

final class V09GraphFileViewController: UIViewController {
    private let request: V09Request
    private let output = UITextView()
    private var launched = false

    init(request: V09Request) { self.request = request; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(request:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "V09 — Graph and file laboratory"
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view = output
        V09GraphFileSession.shared.didChange = { [weak self] in self?.output.text = $0 }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !launched else { return }
        launched = true
        let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String ?? ""
        Task { await V09GraphFileSession.shared.run(request, cloudIdentifier: identifier) }
    }
}
