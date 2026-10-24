import UIKit
import CoreData
import CloudKit

nonisolated struct T6Member: Codable, Equatable {
    let graph: String?
    let node: String?
    let kind: String?
    let value: String?
    let parent: String?
    let children: [String]
    let recordName: String?
    let zoneName: String?
    let share: T6Share?
}

nonisolated struct T6Share: Codable, Equatable {
    let recordName: String
    let zoneName: String
    let ownerCount: Int
    let nonOwnerCount: Int
    let publicPermission: Int

    init(recordName: String, zoneName: String, ownerCount: Int, nonOwnerCount: Int, publicPermission: Int) {
        self.recordName = recordName
        self.zoneName = zoneName
        self.ownerCount = ownerCount
        self.nonOwnerCount = nonOwnerCount
        self.publicPermission = publicPermission
    }

    init(_ share: CKShare) {
        recordName = share.recordID.recordName
        zoneName = share.recordID.zoneID.zoneName
        ownerCount = share.participants.filter { $0.role == .owner }.count
        nonOwnerCount = share.participants.filter { $0.role != .owner }.count
        publicPermission = share.publicPermission.rawValue
    }
}

nonisolated struct T6ShareOperation: Codable {
    let graph: String
    let callbackShare: T6Share
    let callbackNodeIDs: [String]
    let callbackLookupErrors: [String]
    var persistedShare: T6Share?
}

nonisolated struct T6Report: Codable {
    var procedure = "V01-T6-owner-only-shares-v1"
    let runID: UUID
    let stageID: UUID
    let processID: UUID
    let role: String
    let started: Date
    let environment: [String: String]
    let windowSeconds: Int
    var finished: Date?
    var storeIdentifier: String?
    var fixtureSaved = false
    var initialMembers: [T6Member] = []
    var shareOperations: [T6ShareOperation] = []
    var members: [T6Member] = []
    var nativeEvents: [V01NativeEvent] = []
    var droppedEvents = 0
    var diagnosticTrace: String?
    var diagnosticWriteFailures: Int?
    var diagnosticDroppedEntries: Int?
    var errors: [String] = []
    var outcome = "Running; not completed evidence"
    var lifecycle = "Not opened"
}

/// A bounded direct-framework experiment. No invitation or CloudKit CRUD is performed.
@MainActor
final class V01OwnerOnlyShareTrial {
    static let shared = V01OwnerOnlyShareTrial()
    private var owner: NSPersistentCloudKitContainer?
    private var observer: NSObjectProtocol?
    private var started = false
    private let root: URL
    private(set) var report: T6Report?
    var didChange: ((String) -> Void)?

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("V01Laboratory")
    }

    static func parse(_ arguments: [String]) -> V01LaunchRequest? {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: key), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard arguments.contains("--v01-development-verified"),
              let role = value("--v01-role"), ["t6-writer", "t6-reader"].contains(role),
              let id = value("--v01-run-id"), let runID = UUID(uuidString: id),
              let seconds = Int(value("--v01-window") ?? "120"), (1...600).contains(seconds) else { return nil }
        return V01LaunchRequest(role: role, runID: runID, window: seconds)
    }

    static func model() -> NSManagedObjectModel {
        // Keep the old probe entity available for the existing Development schema.
        let model = V01CloudStore.makeModel()
        let member = NSEntityDescription()
        member.name = "V01T6Member"
        member.managedObjectClassName = "NSManagedObject"
        let attributes = ["runID", "graph", "node", "kind", "value"].map { name in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = .stringAttributeType
            attribute.isOptional = true
            return attribute
        }
        let parent = NSRelationshipDescription()
        parent.name = "parent"
        parent.destinationEntity = member
        parent.minCount = 0
        parent.maxCount = 1
        parent.isOptional = true
        parent.deleteRule = .nullifyDeleteRule
        let children = NSRelationshipDescription()
        children.name = "children"
        children.destinationEntity = member
        children.minCount = 0
        children.maxCount = 0
        children.isOptional = true
        children.isOrdered = false
        children.deleteRule = .nullifyDeleteRule
        parent.inverseRelationship = children
        children.inverseRelationship = parent
        member.properties = attributes + [parent, children]
        model.entities += [member]
        return model
    }

    nonisolated static func insertFixture(runID: UUID, context: NSManagedObjectContext) throws {
        for (graph, values) in [("A", [("A-001", "alpha"), ("A-002", "beta")]),
                                ("B", [("B-001", "gamma")])] {
            let root = NSEntityDescription.insertNewObject(forEntityName: "V01T6Member", into: context)
            for (key, value) in ["runID": runID.uuidString, "graph": graph, "node": graph + "-root", "kind": "root", "value": graph] {
                root.setValue(value, forKey: key)
            }
            for (node, value) in values {
                let child = NSEntityDescription.insertNewObject(forEntityName: "V01T6Member", into: context)
                for (key, value) in ["runID": runID.uuidString, "graph": graph, "node": node, "kind": "item", "value": value] {
                    child.setValue(value, forKey: key)
                }
                child.setValue(root, forKey: "parent")
            }
        }
        try context.save()
    }

    static func exactFixture(_ members: [T6Member]) -> Bool {
        let expected: [(String, String, String, String, String?, [String])] = [
            ("A", "A-root", "root", "A", nil, ["A-001", "A-002"]),
            ("A", "A-001", "item", "alpha", "A-root", []),
            ("A", "A-002", "item", "beta", "A-root", []),
            ("B", "B-root", "root", "B", nil, ["B-001"]),
            ("B", "B-001", "item", "gamma", "B-root", [])]
        guard members.count == expected.count else { return false }
        return expected.allSatisfy { graph, node, kind, value, parent, children in
            members.filter { $0.node == node && $0.graph == graph && $0.kind == kind && $0.value == value && $0.parent == parent && $0.children == children }.count == 1
        }
    }

    static func separatedOwnerOnlyShares(_ members: [T6Member]) -> Bool {
        guard exactFixture(members) else { return false }
        var shares: [String: T6Share] = [:]
        for graph in ["A", "B"] {
            let group = members.filter { $0.graph == graph }
            guard let share = group.first?.share, share.ownerCount == 1,
                  share.nonOwnerCount == 0, share.publicPermission == CKShare.ParticipantPermission.none.rawValue,
                  group.allSatisfy({ $0.share == share && $0.zoneName == share.zoneName && $0.recordName != nil }) else { return false }
            shares[graph] = share
        }
        return shares["A"]?.zoneName != shares["B"]?.zoneName
    }

    func run(_ request: V01LaunchRequest, containerIdentifier: String) async {
        guard !started else { return }
        started = true
        let stageID = UUID()
        let directory = root.appendingPathComponent("Stores/\(request.runID)/\(request.role)-\(stageID)")
        let storeURL = directory.appendingPathComponent("probe.sqlite")
        let reportURL = root.appendingPathComponent("Reports/\(request.runID)-\(request.role)-\(stageID).json")
        let provenance = ["LaboratoryDemoRevision", "LaboratoryGraphEvoRevision", "LaboratorySourceState", "LaboratoryToolchain"]
        var environment = Dictionary(uniqueKeysWithValues: provenance.map { ($0, Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "Unrecorded") })
        environment["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        environment["deviceClass"] = UIDevice.current.model
        environment["topology"] = "One private SQLite; two disconnected root graphs; new owner-only share per root; entire-run reads"
        report = T6Report(runID: request.runID, stageID: stageID, processID: UUID(), role: request.role,
                          started: Date(), environment: environment, windowSeconds: request.window)
        var trace: T6Trace?
        var heartbeat: Task<Void, Never>?
        func persist() throws {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: reportURL, options: .atomic)
            didChange?(String(decoding: data, as: UTF8.self))
        }
        do {
            if ProcessInfo.processInfo.arguments.contains("--v01-t6-trace") {
                let url = reportURL.deletingPathExtension().appendingPathExtension("trace.jsonl")
                trace = try T6Trace(url: url)
                report?.diagnosticTrace = url.lastPathComponent
                trace?.record(.runStarted)
                heartbeat = Task { @MainActor in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                        catch { break }
                        trace?.record(.mainActorHeartbeat)
                        report?.diagnosticWriteFailures = trace?.counts.failures
                        report?.diagnosticDroppedEntries = trace?.counts.dropped
                        do { try persist() } catch { trace?.record(.checkpointFailed) }
                    }
                }
            }
            guard !GraphProvider.wasInitialized, !containerIdentifier.isEmpty,
                  ["t6-writer", "t6-reader"].contains(request.role) else { throw V01Error.missingConfiguration }
            #if targetEnvironment(simulator)
            throw V01Error.missingConfiguration
            #endif
            guard try await CKContainer(identifier: containerIdentifier).accountStatus() == .available else { throw V01Error.accountUnavailable }
            guard !FileManager.default.fileExists(atPath: storeURL.path) else { throw V01Error.freshPathRequired }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try persist()
            let owner = NSPersistentCloudKitContainer(name: "V01T6Probe", managedObjectModel: Self.model())
            self.owner = owner
            owner.persistentStoreDescriptions = V01CloudStore.descriptions(stores: [V01StoreLocation(key: "main", url: storeURL)], containerIdentifier: containerIdentifier)
            observer = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: owner, queue: .main) { [weak self] note in
                guard let trial = self,
                      let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
                let kind: String
                switch event.type {
                case .setup: kind = "setup"
                case .import: kind = "import"
                case .export: kind = "export"
                @unknown default: kind = "unknown"
                }
                let value = V01NativeEvent(identifier: event.identifier, kind: kind, started: event.startDate, finished: event.endDate,
                                           succeeded: event.succeeded, storeIdentifier: event.storeIdentifier, error: event.error.map(v01ErrorCode))
                Task { @MainActor in
                    guard trial.report?.finished == nil else { return }
                    if trial.report?.nativeEvents.count ?? 0 < 128 { trial.report?.nativeEvents.append(value) }
                    else { trial.report?.droppedEvents += 1 }
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                owner.loadPersistentStores { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            report?.storeIdentifier = owner.persistentStoreCoordinator.persistentStores.first?.identifier
            report?.lifecycle = "Fresh private store opened"
            if request.role == "t6-writer" {
                let context = owner.newBackgroundContext()
                try await context.perform {
                    defer { context.reset() }
                    try Self.insertFixture(runID: request.runID, context: context)
                }
                report?.fixtureSaved = true
                report?.initialMembers = try await snapshot(runID: request.runID)
                try persist()
                for graph in ["A", "B"] {
                    report?.lifecycle = "Requesting a new owner-only share for root \(graph)"
                    try persist()
                    try await createShare(graph: graph, runID: request.runID, trace: trace, checkpoint: persist)
                    try persist()
                }
            }
            let deadline = Date().addingTimeInterval(TimeInterval(request.window))
            repeat {
                report?.members = try await snapshot(runID: request.runID)
                try persist()
                if request.role == "t6-reader", Self.separatedOwnerOnlyShares(report?.members ?? []) { break }
                if Date() >= deadline { break }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } while Date() < deadline
            let separated = Self.separatedOwnerOnlyShares(report?.members ?? [])
            report?.outcome = separated
                ? "Observed exact A/B fixture in distinct owner-only share zones. This does not prove selective download or separate local stores."
                : "Inconclusive: exact fixture, distinct share zones or owner-only metadata not fully observed. Inspect raw members, callbacks and errors."
        } catch {
            report?.errors.append(v01ErrorCode(error))
            report?.outcome = "Stage failed; no fallback, resource substitution or retry."
        }
        heartbeat?.cancel()
        report?.diagnosticWriteFailures = trace?.counts.failures
        report?.diagnosticDroppedEntries = trace?.counts.dropped
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        do {
            if let owner {
                owner.viewContext.reset()
                for store in owner.persistentStoreCoordinator.persistentStores { try owner.persistentStoreCoordinator.remove(store) }
            }
            self.owner = nil
            report?.lifecycle = "Contexts reset, store detached and owner released. Terminate process; no shutdown acknowledgement inferred."
        } catch { report?.errors.append("Close: " + v01ErrorCode(error)) }
        report?.finished = Date()
        trace?.record(.runFinished)
        do { try persist(); print("V01 T6 stage ended; retained=true; role=\(request.role); runID=\(request.runID)") }
        catch { print("V01 T6 final report retention failed: \(v01ErrorCode(error))") }
    }

    private func createShare(graph: String, runID: UUID, trace: T6Trace?, checkpoint: () throws -> Void) async throws {
        guard let owner, let store = owner.persistentStoreCoordinator.persistentStores.first else { throw V01Error.notOpen }
        // The main-queue context stays owned by the container throughout the asynchronous share operation.
        let context = owner.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "V01T6Member")
        request.predicate = NSPredicate(format: "runID == %@ AND node == %@", runID.uuidString, graph + "-root")
        trace?.record(.rootFetchStarted, graph: graph)
        let roots = try context.fetch(request)
        trace?.record(.rootFetchFinished, graph: graph)
        guard roots.count == 1 else { throw V01Error.notOpen }
        let (share, ids): (CKShare, Set<NSManagedObjectID>) = try await withCheckedThrowingContinuation { continuation in
            trace?.record(.shareCallEntered, graph: graph)
            owner.share(roots, to: nil) { ids, share, _, error in
                trace?.record(.shareCallbackEntered, graph: graph)
                if error != nil { trace?.record(.shareCallbackFailed, graph: graph) }
                if let error { continuation.resume(throwing: error) }
                else if let share, let ids { continuation.resume(returning: (share, ids)) }
                else { continuation.resume(throwing: V01Error.notOpen) }
            }
            trace?.record(.shareCallReturned, graph: graph)
        }
        trace?.record(.shareContinuationResumed, graph: graph)
        trace?.record(.metadataReadStarted, graph: graph)
        let callback = T6Share(share)
        trace?.record(.metadataReadFinished, graph: graph)
        var names: [String] = []
        var lookupErrors: [String] = []
        for id in ids {
            trace?.record(.objectLookupStarted, graph: graph)
            do { names.append(try context.existingObject(with: id).value(forKey: "node") as? String ?? "<nil>") }
            catch { lookupErrors.append(v01ErrorCode(error)) }
            trace?.record(.objectLookupFinished, graph: graph)
        }
        let index = report?.shareOperations.count ?? 0
        report?.shareOperations.append(T6ShareOperation(graph: graph, callbackShare: callback,
                                                       callbackNodeIDs: names.sorted(), callbackLookupErrors: lookupErrors,
                                                       persistedShare: nil))
        // Retain successful assignment even if subsequent persistence fails or the process ends.
        try checkpoint()
        guard callback.nonOwnerCount == 0,
              callback.publicPermission == CKShare.ParticipantPermission.none.rawValue else {
            throw NSError(domain: "V01T6UnexpectedShareAccess", code: 1)
        }
        // Explicitly persist through Core Data; this completion is distinct from object export.
        let persisted: CKShare = try await withCheckedThrowingContinuation { continuation in
            trace?.record(.persistCallEntered, graph: graph)
            owner.persistUpdatedShare(share, in: store) { share, error in
                trace?.record(.persistCallbackEntered, graph: graph)
                if let error { continuation.resume(throwing: error) }
                else if let share { continuation.resume(returning: share) }
                else { continuation.resume(throwing: V01Error.notOpen) }
            }
            trace?.record(.persistCallReturned, graph: graph)
        }
        trace?.record(.persistContinuationResumed, graph: graph)
        let summary = T6Share(persisted)
        report?.shareOperations[index].persistedShare = summary
        try checkpoint()
        guard summary.ownerCount == 1, summary.nonOwnerCount == 0,
              summary.publicPermission == CKShare.ParticipantPermission.none.rawValue else {
            throw NSError(domain: "V01T6UnexpectedShareAccess", code: 2)
        }
        trace?.record(.shareFinished, graph: graph)
    }

    private func snapshot(runID: UUID) async throws -> [T6Member] {
        guard let owner else { throw V01Error.notOpen }
        let context = owner.newBackgroundContext()
        return try await context.perform {
            defer { context.reset() }
            let request = NSFetchRequest<NSManagedObject>(entityName: "V01T6Member")
            request.predicate = NSPredicate(format: "runID == %@", runID.uuidString)
            let objects = try context.fetch(request)
            let shares = try owner.fetchShares(matching: objects.map(\.objectID))
            return objects.map { object in
                let record = owner.recordID(for: object.objectID)
                let parent = object.value(forKey: "parent") as? NSManagedObject
                let children = object.value(forKey: "children") as? Set<NSManagedObject> ?? []
                return T6Member(graph: object.value(forKey: "graph") as? String, node: object.value(forKey: "node") as? String,
                                kind: object.value(forKey: "kind") as? String, value: object.value(forKey: "value") as? String,
                                parent: parent?.value(forKey: "node") as? String,
                                children: children.compactMap { $0.value(forKey: "node") as? String }.sorted(),
                                recordName: record?.recordName, zoneName: record?.zoneID.zoneName,
                                share: shares[object.objectID].map(T6Share.init))
            }.sorted { ($0.node ?? "") < ($1.node ?? "") }
        }
    }
}

/// CLI-only presentation keeps this experiment separate from the normal demo and older trials.
final class V01OwnerOnlyShareViewController: UIViewController {
    private let request: V01LaunchRequest
    private let output = UITextView()
    private var launched = false

    init(request: V01LaunchRequest) {
        self.request = request
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(request:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "V01 T6 — Owner-only shares"
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.text = "Preparing owner-only share trial; no invitations are sent."
        view = output
        V01OwnerOnlyShareTrial.shared.didChange = { [weak self] in self?.output.text = $0 }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !launched else { return }
        launched = true
        let identifier = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String ?? ""
        Task { await V01OwnerOnlyShareTrial.shared.run(request, containerIdentifier: identifier) }
    }
}
