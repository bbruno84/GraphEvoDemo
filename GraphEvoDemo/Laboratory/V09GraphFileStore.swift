import CloudKit
import CoreData
import CryptoKit
import Foundation

/// A disposable framework fixture. Kinds describe graph roles while one Core Data
/// entity keeps the experiment independent of a proposed GraphEvo 2 schema.
enum V09Model {
    static func make() -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = "V09Member"
        entity.managedObjectClassName = "NSManagedObject"

        func attribute(_ name: String, _ type: NSAttributeType, external: Bool = false) -> NSAttributeDescription {
            let value = NSAttributeDescription()
            value.name = name
            value.attributeType = type
            value.isOptional = true
            value.allowsExternalBinaryDataStorage = external
            return value
        }
        var properties: [NSPropertyDescription] = [
            attribute("runID", .stringAttributeType),
            attribute("graph", .stringAttributeType),
            attribute("memberID", .stringAttributeType),
            attribute("kind", .stringAttributeType),
            attribute("label", .stringAttributeType),
            attribute("bytes", .binaryDataAttributeType, external: true),
            attribute("filename", .stringAttributeType),
            attribute("contentType", .stringAttributeType),
            attribute("checksum", .stringAttributeType)
        ]
        func pair(_ forward: String, _ reverse: String, forwardMany: Bool = false, reverseMany: Bool = false) {
            let a = NSRelationshipDescription()
            let b = NSRelationshipDescription()
            a.name = forward
            b.name = reverse
            a.destinationEntity = entity
            b.destinationEntity = entity
            a.minCount = 0
            b.minCount = 0
            a.maxCount = forwardMany ? 0 : 1
            b.maxCount = reverseMany ? 0 : 1
            a.isOptional = true
            b.isOptional = true
            a.deleteRule = .nullifyDeleteRule
            b.deleteRule = .nullifyDeleteRule
            a.inverseRelationship = b
            b.inverseRelationship = a
            properties += [a, b]
        }
        pair("parent", "children", reverseMany: true)
        pair("source", "sourceEdges", reverseMany: true)
        pair("target", "targetEdges", reverseMany: true)
        pair("subjects", "subjectActions", forwardMany: true, reverseMany: true)
        pair("objects", "objectActions", forwardMany: true, reverseMany: true)
        pair("fileOwner", "attachments", reverseMany: true)
        entity.properties = properties
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }
}

nonisolated struct V09Row: Codable, Equatable {
    let scope: V02Scope
    let graph: String
    let id: String
    let kind: String
    let label: String?
    let parent: String?
    let source: String?
    let target: String?
    let subjects: [String]
    let objects: [String]
    let fileOwner: String?
    let filename: String?
    let contentType: String?
    let byteCount: Int?
    let checksum: String?
    let checksumMatches: Bool?
    let record: V02RecordKey?
    let share: V02ShareInfo?
}

enum V09Error: Error {
    case missingStore, invalidFixture, invalidShare, missingResponse, unexpectedAccount, closed
}

@MainActor
final class V09GraphFileStore {
    private var container: NSPersistentCloudKitContainer?
    private var stores: [V02Scope: NSPersistentStore] = [:]
    private let currentUser: CKRecord.ID
    private var observer: NSObjectProtocol?

    init(currentUser: CKRecord.ID) { self.currentUser = currentUser }

    func open(directory: URL, cloudIdentifier: String, fresh: Bool,
              event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws {
        let descriptions = V02CloudStore.descriptions(directory: directory, container: cloudIdentifier)
        if fresh {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw V09Error.invalidFixture }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } else {
            guard descriptions.allSatisfy({ FileManager.default.fileExists(atPath: $0.url!.path) }) else {
                throw V09Error.missingStore
            }
        }
        try V01CloudStore.validateCloudDestinations(descriptions)
        let owner = NSPersistentCloudKitContainer(name: "V09GraphFileProbe", managedObjectModel: V09Model.make())
        container = owner
        owner.persistentStoreDescriptions = descriptions
        observer = T6EventDelivery.observe(owner: owner, receive: event)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var remaining = descriptions.count
            var firstError: Error?
            owner.loadPersistentStores { _, error in
                Task { @MainActor in
                    if let error, firstError == nil { firstError = error }
                    remaining -= 1
                    if remaining == 0 {
                        if let firstError { continuation.resume(throwing: firstError) }
                        else { continuation.resume() }
                    }
                }
            }
        }
        for scope in V02Scope.allCases {
            let url = directory.appendingPathComponent(scope.rawValue + ".sqlite").standardizedFileURL
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: {
                $0.url?.standardizedFileURL == url
            }) else { throw V09Error.missingStore }
            stores[scope] = store
        }
    }

    nonisolated private static func fetch(_ runID: UUID, store: NSPersistentStore) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "V09Member")
        request.predicate = NSPredicate(format: "runID == %@", runID.uuidString)
        request.affectedStores = [store]
        return request
    }

    nonisolated private static func member(_ id: String, runID: UUID, context: NSManagedObjectContext,
                               store: NSPersistentStore) throws -> NSManagedObject {
        let request = fetch(runID, store: store)
        request.predicate = NSPredicate(format: "runID == %@ AND memberID == %@", runID.uuidString, id)
        let matches = try context.fetch(request)
        guard matches.count == 1, let object = matches.first else { throw V09Error.invalidFixture }
        return object
    }

    nonisolated private static func insert(_ id: String, graph: String, kind: String, label: String?,
                               runID: UUID, context: NSManagedObjectContext,
                               store: NSPersistentStore) -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: "V09Member", into: context)
        context.assign(object, to: store)
        object.setValue(runID.uuidString, forKey: "runID")
        object.setValue(graph, forKey: "graph")
        object.setValue(id, forKey: "memberID")
        object.setValue(kind, forKey: "kind")
        object.setValue(label, forKey: "label")
        return object
    }

    func seed(runID: UUID) async throws {
        guard let owner = container, let store = stores[.privateStore] else { throw V09Error.missingStore }
        let context = owner.newBackgroundContext()
        let storeURL = store.url
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == storeURL }),
                  try context.count(for: Self.fetch(runID, store: store)) == 0 else { throw V09Error.invalidFixture }
            for graph in ["A", "B"] {
                let root = Self.insert("\(graph)-root", graph: graph, kind: "root", label: graph,
                                       runID: runID, context: context, store: store)
                let first = Self.insert("\(graph)-entity-1", graph: graph, kind: "entity", label: "first",
                                        runID: runID, context: context, store: store)
                let second = Self.insert("\(graph)-entity-2", graph: graph, kind: "entity", label: "second",
                                         runID: runID, context: context, store: store)
                first.setValue(root, forKey: "parent")
                second.setValue(root, forKey: "parent")
                let forward = Self.insert("\(graph)-relationship", graph: graph, kind: "relationship",
                                          label: "forward", runID: runID, context: context, store: store)
                forward.setValue(root, forKey: "parent")
                forward.setValue(first, forKey: "source")
                forward.setValue(second, forKey: "target")
                let action = Self.insert("\(graph)-action", graph: graph, kind: "action",
                                         label: "use", runID: runID, context: context, store: store)
                action.setValue(root, forKey: "parent")
                action.setValue(NSSet(array: [first, second]), forKey: "subjects")
                action.setValue(NSSet(array: [second]), forKey: "objects")
            }
            try context.save()
        }
    }

    private func root(_ graph: String, runID: UUID) throws -> NSManagedObject {
        guard let owner = container, let store = stores[.privateStore] else { throw V09Error.missingStore }
        return try Self.member("\(graph)-root", runID: runID, context: owner.viewContext, store: store)
    }

    private func rootShare(_ graph: String, runID: UUID) throws -> CKShare {
        guard let owner = container else { throw V09Error.closed }
        let object = try root(graph, runID: runID)
        guard let share = try owner.fetchShares(matching: [object.objectID])[object.objectID] else {
            throw V09Error.invalidShare
        }
        return share
    }

    func createShare(_ graph: String, runID: UUID, checkpoint: () throws -> Void) async throws {
        guard let owner = container, let store = stores[.privateStore] else { throw V09Error.missingStore }
        let object = try root(graph, runID: runID)
        guard try owner.fetchShares(matching: [object.objectID]).isEmpty else { throw V09Error.invalidShare }
        try checkpoint()
        let share = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKShare, Error>) in
            owner.share([object], to: nil) { _, share, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let share { continuation.resume(returning: share) }
                else { continuation.resume(throwing: V09Error.missingResponse) }
            }
        }
        try checkpoint()
        _ = try await persist(share, in: store)
    }

    private func persist(_ share: CKShare, in store: NSPersistentStore) async throws -> CKShare {
        guard let owner = container else { throw V09Error.closed }
        return try await withCheckedThrowingContinuation { continuation in
            owner.persistUpdatedShare(share, in: store) { saved, error in
                if let error { continuation.resume(throwing: error) }
                else if let saved { continuation.resume(returning: saved) }
                else { continuation.resume(throwing: V09Error.missingResponse) }
            }
        }
    }

    func invite(_ identity: V02Envelope, runID: UUID, cloudIdentifier: String,
                checkpoint: () throws -> Void) async throws -> V02Envelope {
        try identity.validate(runID: runID, container: cloudIdentifier, purpose: "participant-identity")
        guard identity.account.recordID != currentUser, let owner = container,
              let store = stores[.privateStore] else { throw V09Error.unexpectedAccount }
        let share = try rootShare("A", runID: runID)
        guard T6Share(share).nonOwnerCount == 0, T6Share(try rootShare("B", runID: runID)).nonOwnerCount == 0
        else { throw V09Error.invalidShare }
        let participants: [CKShare.Participant] = try await withCheckedThrowingContinuation { continuation in
            owner.fetchParticipants(matching: [CKUserIdentity.LookupInfo(userRecordID: identity.account.recordID)],
                                    into: store) { participants, error in
                if let error { continuation.resume(throwing: error) }
                else if let participants { continuation.resume(returning: participants) }
                else { continuation.resume(throwing: V09Error.missingResponse) }
            }
        }
        guard participants.count == 1, let participant = participants.first,
              participant.userIdentity.userRecordID == identity.account.recordID else { throw V09Error.unexpectedAccount }
        participant.role = .privateUser
        participant.permission = .readWrite
        share.addParticipant(participant)
        try checkpoint()
        let saved = try await persist(share, in: store)
        guard let url = saved.url else { throw V09Error.invalidShare }
        return V02Envelope(purpose: "private-invitation", runID: runID, containerIdentifier: cloudIdentifier,
                           account: V02PrivateID(currentUser), recipient: identity.account,
                           share: V02PrivateID(saved.recordID), shareURL: url)
    }

    func accept(_ invitation: V02Envelope, runID: UUID, cloudIdentifier: String,
                checkpoint: () throws -> Void) async throws {
        try invitation.validate(runID: runID, container: cloudIdentifier, purpose: "private-invitation")
        guard invitation.recipient?.recordID == currentUser, let expected = invitation.share,
              let url = invitation.shareURL, let owner = container,
              let store = stores[.sharedStore] else { throw V09Error.unexpectedAccount }
        let metadata = try await CKContainer(identifier: cloudIdentifier).shareMetadata(for: url)
        guard metadata.containerIdentifier == cloudIdentifier,
              expected.matches(metadata.share.recordID, shareOwner: invitation.account.recordID),
              metadata.ownerIdentity.userRecordID == invitation.account.recordID,
              metadata.participantRole == .privateUser, metadata.participantPermission == .readWrite,
              metadata.participantStatus == .pending else { throw V09Error.invalidShare }
        try checkpoint()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            owner.acceptShareInvitations(from: [metadata], into: store) { accepted, error in
                if let error { continuation.resume(throwing: error) }
                else if accepted?.count == 1 { continuation.resume() }
                else { continuation.resume(throwing: V09Error.missingResponse) }
            }
        }
    }

    func snapshot(runID: UUID) async throws -> [V09Row] {
        guard let owner = container else { throw V09Error.closed }
        let context = owner.newBackgroundContext()
        let urls = stores.mapValues(\.url)
        let currentUser = currentUser
        return try await context.perform {
            defer { context.reset() }
            var rows: [V09Row] = []
            for scope in V02Scope.allCases {
                guard let url = urls[scope],
                      let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == url })
                else { throw V09Error.missingStore }
                let objects = try context.fetch(Self.fetch(runID, store: store))
                let shares = try owner.fetchShares(matching: objects.map(\.objectID))
                for object in objects {
                    func id(_ key: String) -> String? {
                        (object.value(forKey: key) as? NSManagedObject)?.value(forKey: "memberID") as? String
                    }
                    func ids(_ key: String) -> [String] {
                        (object.value(forKey: key) as? Set<NSManagedObject> ?? [])
                            .compactMap { $0.value(forKey: "memberID") as? String }.sorted()
                    }
                    guard let graph = object.value(forKey: "graph") as? String,
                          let memberID = object.value(forKey: "memberID") as? String,
                          let kind = object.value(forKey: "kind") as? String else { throw V09Error.invalidFixture }
                    let bytes = object.value(forKey: "bytes") as? Data
                    let checksum = object.value(forKey: "checksum") as? String
                    let actual = bytes.map { Self.digest($0) }
                    let share = shares[object.objectID].map { V02CloudStore.shareInfo($0, currentUser: currentUser, runID: runID) }
                    rows.append(V09Row(
                        scope: scope, graph: graph, id: memberID, kind: kind,
                        label: object.value(forKey: "label") as? String,
                        parent: id("parent"), source: id("source"), target: id("target"),
                        subjects: ids("subjects"), objects: ids("objects"), fileOwner: id("fileOwner"),
                        filename: object.value(forKey: "filename") as? String,
                        contentType: object.value(forKey: "contentType") as? String,
                        byteCount: bytes?.count, checksum: checksum,
                        checksumMatches: bytes.map { _ in actual == checksum },
                        record: owner.recordID(for: object.objectID).map {
                            V02RecordKey.make($0, currentUser: currentUser, runID: runID)
                        }, share: share))
                }
            }
            return rows.sorted { ($0.graph, $0.id) < ($1.graph, $1.id) }
        }
    }

    private static func fixtureBytes(runID: UUID, generation: UInt8, count: Int) -> Data {
        let seed = Array(runID.uuidString.utf8)
        var state: UInt64 = 0x9E3779B97F4A7C15 ^ UInt64(generation)
        for byte in seed { state = (state ^ UInt64(byte)) &* 0x100000001B3 }
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { raw in
            guard let output = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<count {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                output[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        return bytes
    }

    func addAttachment(runID: UUID, large: Bool) async throws {
        guard let owner = container, let store = stores[.privateStore] else { throw V09Error.missingStore }
        let context = owner.newBackgroundContext()
        let storeURL = store.url
        let count = large ? 10 * 1_024 * 1_024 : 512
        let bytes = Self.fixtureBytes(runID: runID, generation: large ? 2 : 1, count: count)
        let checksum = Self.digest(bytes)
        let id = large ? "A-file-large" : "A-file-small"
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == storeURL })
            else { throw V09Error.missingStore }
            let existing = try context.fetch(Self.fetch(runID, store: store))
            guard !existing.contains(where: { $0.value(forKey: "memberID") as? String == id }) else {
                throw V09Error.invalidFixture
            }
            let root = try Self.member("A-root", runID: runID, context: context, store: store)
            let subject = try Self.member("A-entity-1", runID: runID, context: context, store: store)
            guard owner.canUpdateRecord(forManagedObjectWith: root.objectID) else { throw V09Error.invalidShare }
            let file = Self.insert(id, graph: "A", kind: "attachment", label: nil,
                                   runID: runID, context: context, store: store)
            file.setValue(root, forKey: "parent")
            file.setValue(subject, forKey: "fileOwner")
            file.setValue(bytes, forKey: "bytes")
            file.setValue(large ? "large.bin" : "small.bin", forKey: "filename")
            file.setValue("application/octet-stream", forKey: "contentType")
            file.setValue(checksum, forKey: "checksum")
            try context.save()
        }
    }

    func replaceLargeAttachment(runID: UUID) async throws {
        guard let owner = container, let store = stores[.sharedStore] else { throw V09Error.missingStore }
        let context = owner.newBackgroundContext()
        let storeURL = store.url
        let bytes = Self.fixtureBytes(runID: runID, generation: 3, count: 10 * 1_024 * 1_024)
        let checksum = Self.digest(bytes)
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == storeURL })
            else { throw V09Error.missingStore }
            let file = try Self.member("A-file-large", runID: runID, context: context, store: store)
            guard file.value(forKey: "filename") as? String == "large.bin",
                  owner.canUpdateRecord(forManagedObjectWith: file.objectID) else { throw V09Error.invalidFixture }
            file.setValue(bytes, forKey: "bytes")
            file.setValue(checksum, forKey: "checksum")
            file.setValue("large-replaced.bin", forKey: "filename")
            try context.save()
        }
    }

    func deleteLargeAttachment(runID: UUID) async throws {
        guard let owner = container, let store = stores[.sharedStore] else { throw V09Error.missingStore }
        let context = owner.newBackgroundContext()
        let storeURL = store.url
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == storeURL })
            else { throw V09Error.missingStore }
            let file = try Self.member("A-file-large", runID: runID, context: context, store: store)
            guard owner.canDeleteRecord(forManagedObjectWith: file.objectID) else { throw V09Error.invalidShare }
            context.delete(file)
            try context.save()
        }
    }

    /// Assign every new participant object to A's existing share before linking
    /// it to the imported graph. This is the supported path observed in V02.
    func addParticipantGraphMembers(runID: UUID, checkpoint: () throws -> Void) async throws {
        guard let owner = container, let sharedStore = stores[.sharedStore],
              owner.canModifyManagedObjects(in: sharedStore) else { throw V09Error.missingStore }
        let root = try Self.member("A-root", runID: runID, context: owner.viewContext, store: sharedStore)
        guard owner.canUpdateRecord(forManagedObjectWith: root.objectID),
              let share = try owner.fetchShares(matching: [root.objectID])[root.objectID] else {
            throw V09Error.invalidShare
        }
        let ids = ["A-entity-3", "A-relationship-2", "A-action-2"]
        let kinds = ["entity", "relationship", "action"]
        for id in ids {
            let request = Self.fetch(runID, store: sharedStore)
            request.predicate = NSPredicate(format: "runID == %@ AND memberID == %@", runID.uuidString, id)
            guard try owner.viewContext.count(for: request) == 0 else { throw V09Error.invalidFixture }
        }
        var newObjects: [NSManagedObject] = []
        for (id, kind) in zip(ids, kinds) {
            newObjects.append(Self.insert(id, graph: "A", kind: kind, label: "participant-added",
                                          runID: runID, context: owner.viewContext, store: sharedStore))
        }
        try checkpoint()
        try owner.viewContext.save()
        try checkpoint()
        let assigned: CKShare = try await withCheckedThrowingContinuation { continuation in
            owner.share(newObjects, to: share) { _, returnedShare, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let returnedShare { continuation.resume(returning: returnedShare) }
                else { continuation.resume(throwing: V09Error.missingResponse) }
            }
        }
        guard assigned.recordID == share.recordID else { throw V09Error.invalidShare }
        let context = owner.newBackgroundContext()
        let storeURL = sharedStore.url
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == storeURL })
            else { throw V09Error.missingStore }
            let root = try Self.member("A-root", runID: runID, context: context, store: store)
            let first = try Self.member("A-entity-1", runID: runID, context: context, store: store)
            let second = try Self.member("A-entity-2", runID: runID, context: context, store: store)
            let third = try Self.member(ids[0], runID: runID, context: context, store: store)
            let edge = try Self.member(ids[1], runID: runID, context: context, store: store)
            let action = try Self.member(ids[2], runID: runID, context: context, store: store)
            third.setValue(root, forKey: "parent")
            edge.setValue(root, forKey: "parent")
            edge.setValue(third, forKey: "source")
            edge.setValue(second, forKey: "target")
            action.setValue(root, forKey: "parent")
            action.setValue(NSSet(array: [first, third]), forKey: "subjects")
            action.setValue(NSSet(array: [second]), forKey: "objects")
            try context.save()
        }
    }

    func deleteParticipantGraphMembers(runID: UUID) async throws {
        guard let owner = container, let store = stores[.privateStore] else { throw V09Error.missingStore }
        let context = owner.newBackgroundContext()
        let storeURL = store.url
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == storeURL })
            else { throw V09Error.missingStore }
            for id in ["A-action-2", "A-relationship-2", "A-entity-3"] {
                let object = try Self.member(id, runID: runID, context: context, store: store)
                guard owner.canDeleteRecord(forManagedObjectWith: object.objectID) else { throw V09Error.invalidShare }
                context.delete(object)
            }
            try context.save()
        }
    }

    func editExistingEntity(runID: UUID) async throws {
        guard let owner = container, let store = stores[.sharedStore] else { throw V09Error.missingStore }
        let context = owner.newBackgroundContext()
        let storeURL = store.url
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == storeURL })
            else { throw V09Error.missingStore }
            let entity = try Self.member("A-entity-1", runID: runID, context: context, store: store)
            guard entity.value(forKey: "label") as? String == "first",
                  owner.canUpdateRecord(forManagedObjectWith: entity.objectID) else { throw V09Error.invalidFixture }
            entity.setValue("participant-edited", forKey: "label")
            try context.save()
        }
    }

    func editDisjointEntity(runID: UUID, ownerSide: Bool) async throws {
        guard let owner = container,
              let store = stores[ownerSide ? .privateStore : .sharedStore] else { throw V09Error.missingStore }
        let context = owner.newBackgroundContext()
        let storeURL = store.url
        let id = ownerSide ? "A-entity-1" : "A-entity-2"
        let previous = ownerSide ? "first" : "second"
        let next = ownerSide ? "owner-concurrent" : "participant-concurrent"
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == storeURL })
            else { throw V09Error.missingStore }
            let entity = try Self.member(id, runID: runID, context: context, store: store)
            guard entity.value(forKey: "label") as? String == previous,
                  owner.canUpdateRecord(forManagedObjectWith: entity.objectID) else { throw V09Error.invalidFixture }
            entity.setValue(next, forKey: "label")
            try context.save()
        }
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func close() async throws {
        guard let owner = container else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for store in owner.persistentStoreCoordinator.persistentStores {
            try owner.persistentStoreCoordinator.remove(store)
        }
        stores.removeAll()
        container = nil
    }
}
