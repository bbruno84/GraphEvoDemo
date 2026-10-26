import Foundation
import CoreData
import CloudKit

@MainActor
protocol V02StoreAccess: AnyObject {
    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws
    func insertFixture(runID: UUID) async throws
    func createShare(graph: String, runID: UUID, checkpoint: () throws -> Void) async throws
    func invite(_ identity: V02Envelope, runID: UUID, container: String, checkpoint: () throws -> Void) async throws -> V02Envelope
    func accept(_ invitation: V02Envelope, runID: UUID, container: String, checkpoint: () throws -> Void) async throws
    func snapshot(runID: UUID) async throws -> [V02Row]
    func edit(runID: UUID) async throws
    func close() async throws
    var inventory: [String: String] { get }
}

/// Laboratory owner with explicit database scopes; V02 defaults to private/shared.
@MainActor
final class V02CloudStore: V02StoreAccess {
    private var owner: NSPersistentContainer?
    private var observer: NSObjectProtocol?
    private let currentUser: CKRecord.ID
    private let localOnly: Bool
    private let trace: T6Trace?
    private let scopes: [V02Scope]
    private var stores: [V02Scope: NSPersistentStore] = [:]
    private var revocationHistoryTokenData: Data?
    var inventory: [String: String] { Dictionary(uniqueKeysWithValues: stores.map { ($0.key.rawValue, $0.value.identifier) }) }

    init(currentUser: CKRecord.ID, localOnly: Bool = false, trace: T6Trace? = nil, scopes: [V02Scope] = V02Scope.allCases) {
        self.currentUser = currentUser; self.localOnly = localOnly; self.trace = trace
        self.scopes = scopes
    }

    static func descriptions(directory: URL, container: String, scopes: [V02Scope] = V02Scope.allCases) -> [NSPersistentStoreDescription] {
        scopes.map { scope in
            let description = NSPersistentStoreDescription(url: directory.appendingPathComponent(scope.rawValue + ".sqlite"))
            description.shouldAddStoreAsynchronously = true
            description.shouldMigrateStoreAutomatically = false
            description.shouldInferMappingModelAutomatically = false
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            let options = NSPersistentCloudKitContainerOptions(containerIdentifier: container)
            options.databaseScope = scope == .privateStore ? .private : .shared
            description.cloudKitContainerOptions = options
            return description
        }
    }

    func open(directory: URL, container: String, fresh: Bool, event: @escaping @MainActor @Sendable (V01NativeEvent) -> Void) async throws {
        guard scopes == [.privateStore] || scopes == V02Scope.allCases else { throw V02Error.missingStores }
        let descriptions = Self.descriptions(directory: directory, container: container, scopes: scopes)
        if fresh {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw V02Error.existingStores }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } else {
            guard descriptions.allSatisfy({ FileManager.default.fileExists(atPath: $0.url!.path) }) else { throw V02Error.missingStores }
        }
        try V01CloudStore.validateCloudDestinations(descriptions)
        if localOnly { descriptions.forEach { $0.cloudKitContainerOptions = nil } }
        let model = V01OwnerOnlyShareTrial.model()
        let owner: NSPersistentContainer = localOnly ? NSPersistentContainer(name: "V02Probe", managedObjectModel: model)
            : NSPersistentCloudKitContainer(name: "V02Probe", managedObjectModel: model)
        self.owner = owner
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
        for scope in scopes {
            let url = directory.appendingPathComponent(scope.rawValue + ".sqlite").standardizedFileURL
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url?.standardizedFileURL == url }) else {
                throw V02Error.missingStores
            }
            stores[scope] = store
        }
    }

    func insertFixture(runID: UUID) async throws {
        guard let owner, let store = stores[.privateStore] else { throw V01Error.notOpen }
        let context = owner.newBackgroundContext()
        let storeURL = store.url
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == storeURL }) else { throw V02Error.missingStores }
            let request = Self.request(runID, store: store)
            guard try context.count(for: request) == 0 else { throw V02Error.invalidFixture }
            var byNode: [String: NSManagedObject] = [:]
            for row in V02Fixture.rows {
                let object = NSEntityDescription.insertNewObject(forEntityName: "V01T6Member", into: context)
                context.assign(object, to: store)
                for (key, value) in ["runID": runID.uuidString, "graph": row.graph, "node": row.node, "kind": row.kind, "value": row.value] {
                    object.setValue(value, forKey: key)
                }
                byNode[row.node] = object
            }
            for row in V02Fixture.rows {
                if let parent = row.parent { byNode[row.node]?.setValue(byNode[parent], forKey: "parent") }
            }
            try context.save()
        }
    }

    private func root(_ graph: String, runID: UUID) throws -> NSManagedObject {
        guard let owner, let store = stores[.privateStore] else { throw V01Error.notOpen }
        let request = Self.request(runID, store: store)
        request.predicate = NSPredicate(format: "runID == %@ AND node == %@ AND graph == %@ AND kind == 'root'", runID.uuidString, graph + "-root", graph)
        let roots = try owner.viewContext.fetch(request)
        guard roots.count == 1, let root = roots.first else { throw V02Error.invalidFixture }
        return root
    }

    private func rootShare(_ graph: String, runID: UUID) throws -> CKShare {
        guard let cloud = owner as? NSPersistentCloudKitContainer else { throw V01Error.notOpen }
        let root = try root(graph, runID: runID)
        guard let share = try cloud.fetchShares(matching: [root.objectID])[root.objectID] else { throw V02Error.invalidShare }
        return share
    }

    func createShare(graph: String, runID: UUID, checkpoint: () throws -> Void) async throws {
        guard let cloud = owner as? NSPersistentCloudKitContainer, let store = stores[.privateStore] else { throw V01Error.notOpen }
        let root = try root(graph, runID: runID)
        guard try cloud.fetchShares(matching: [root.objectID]).isEmpty else { throw V02Error.invalidShare }
        try checkpoint()
        let share: CKShare = try await withCheckedThrowingContinuation { continuation in
            trace?.record(.shareCallEntered, graph: graph)
            cloud.share([root], to: nil) { @Sendable [trace] _, share, _, error in
                trace?.record(.shareCallbackEntered, graph: graph)
                if let error { continuation.resume(throwing: error) }
                else if let share { continuation.resume(returning: share) }
                else { continuation.resume(throwing: V02Error.missingResponse) }
            }
            trace?.record(.shareCallReturned, graph: graph)
        }
        guard T6Share(share).ownerCount == 1, T6Share(share).nonOwnerCount == 0, share.publicPermission == .none else { throw V02Error.invalidShare }
        try checkpoint()
        _ = try await persist(share, store: store, cloud: cloud, graph: graph)
    }

    func invite(_ identity: V02Envelope, runID: UUID, container: String, checkpoint: () throws -> Void) async throws -> V02Envelope {
        try identity.validate(runID: runID, container: container, purpose: "participant-identity")
        guard identity.account.recordID != currentUser, let cloud = owner as? NSPersistentCloudKitContainer,
              let store = stores[.privateStore] else { throw V02Error.invalidAccount }
        let baseline = try await snapshot(runID: runID)
        guard V02Fixture.prepared(baseline, invited: false) else { throw V02Error.invalidFixture }
        let share = try rootShare("A", runID: runID)
        guard T6Share(share).ownerCount == 1, T6Share(share).nonOwnerCount == 0, share.publicPermission == .none,
              T6Share(try rootShare("B", runID: runID)).nonOwnerCount == 0 else { throw V02Error.invalidShare }
        let participants: [CKShare.Participant] = try await withCheckedThrowingContinuation { continuation in
            cloud.fetchParticipants(matching: [CKUserIdentity.LookupInfo(userRecordID: identity.account.recordID)], into: store) { @Sendable participants, error in
                if let error { continuation.resume(throwing: error) }
                else if let participants { continuation.resume(returning: participants) }
                else { continuation.resume(throwing: V02Error.missingResponse) }
            }
        }
        guard participants.count == 1, let participant = participants.first,
              participant.userIdentity.userRecordID == identity.account.recordID else { throw V02Error.unexpectedParticipant }
        participant.role = .privateUser
        participant.permission = .readWrite
        share.addParticipant(participant)
        try checkpoint()
        let saved = try await persist(share, store: store, cloud: cloud, graph: "A")
        guard T6Share(saved).ownerCount == 1, T6Share(saved).nonOwnerCount == 1,
              saved.publicPermission == .none, let url = saved.url else { throw V02Error.invalidShare }
        return V02Envelope(purpose: "private-invitation", runID: runID, containerIdentifier: container,
                           account: V02PrivateID(currentUser), recipient: identity.account, share: V02PrivateID(saved.recordID), shareURL: url)
    }

    private func persist(_ share: CKShare, store: NSPersistentStore, cloud: NSPersistentCloudKitContainer, graph: String) async throws -> CKShare {
        try await withCheckedThrowingContinuation { continuation in
            trace?.record(.persistCallEntered, graph: graph)
            cloud.persistUpdatedShare(share, in: store) { @Sendable [trace] saved, error in
                trace?.record(.persistCallbackEntered, graph: graph)
                if let error { continuation.resume(throwing: error) }
                else if let saved { continuation.resume(returning: saved) }
                else { continuation.resume(throwing: V02Error.missingResponse) }
            }
            trace?.record(.persistCallReturned, graph: graph)
        }
    }

    func accept(_ invitation: V02Envelope, runID: UUID, container: String, checkpoint: () throws -> Void) async throws {
        try invitation.validate(runID: runID, container: container, purpose: "private-invitation")
        guard invitation.recipient?.recordID == currentUser, invitation.account.recordID != currentUser,
              let expectedShare = invitation.share, let url = invitation.shareURL,
              url.scheme == "https", ["www.icloud.com", "icloud.com"].contains(url.host?.lowercased() ?? ""), url.path.hasPrefix("/share/"),
              let cloud = owner as? NSPersistentCloudKitContainer, let store = stores[.sharedStore] else { throw V02Error.invalidEnvelope }
        let metadata: CKShare.Metadata = try await CKContainer(identifier: container).shareMetadata(for: url)
        guard metadata.containerIdentifier == container, expectedShare.matches(metadata.share.recordID, shareOwner: invitation.account.recordID),
              metadata.ownerIdentity.userRecordID == invitation.account.recordID,
              metadata.share.publicPermission == .none, metadata.participantRole == .privateUser,
              metadata.participantPermission == .readWrite, metadata.participantStatus == .pending else { throw V02Error.invalidMetadata }
        try checkpoint()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cloud.acceptShareInvitations(from: [metadata], into: store) { @Sendable accepted, error in
                if let error { continuation.resume(throwing: error) }
                else if accepted?.count == 1 { continuation.resume() }
                else { continuation.resume(throwing: V02Error.missingResponse) }
            }
        }
    }

    func snapshot(runID: UUID) async throws -> [V02Row] {
        guard let owner else { throw V01Error.notOpen }
        let context = owner.newBackgroundContext()
        let scopedURLs = stores.mapValues(\.url)
        let selectedScopes = scopes
        let currentUser = currentUser
        return try await context.perform {
            defer { context.reset() }
            var result: [V02Row] = []
            let cloud = owner as? NSPersistentCloudKitContainer
            for scope in selectedScopes {
                guard let url = scopedURLs[scope], let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == url }) else { throw V02Error.missingStores }
                let objects = try context.fetch(Self.request(runID, store: store))
                let shares = try cloud?.fetchShares(matching: objects.map(\.objectID)) ?? [:]
                for object in objects {
                    let parent = object.value(forKey: "parent") as? NSManagedObject
                    let children = object.value(forKey: "children") as? Set<NSManagedObject> ?? []
                    let related = Array(children) + (parent.map { [$0] } ?? [])
                    let valid = related.allSatisfy { $0.value(forKey: "runID") as? String == runID.uuidString &&
                        $0.value(forKey: "graph") as? String == object.value(forKey: "graph") as? String && $0.objectID.persistentStore === store }
                    let share = shares[object.objectID].map { Self.shareInfo($0, currentUser: currentUser, runID: runID) }
                    result.append(V02Row(scope: scope, graph: object.value(forKey: "graph") as? String,
                        node: object.value(forKey: "node") as? String, kind: object.value(forKey: "kind") as? String,
                        value: object.value(forKey: "value") as? String, parent: parent?.value(forKey: "node") as? String,
                        children: children.compactMap { $0.value(forKey: "node") as? String }.sorted(), validClosure: valid,
                        record: cloud?.recordID(for: object.objectID).map { V02RecordKey.make($0, currentUser: currentUser, runID: runID) }, share: share))
                }
            }
            return result.sorted { ($0.scope.rawValue + ($0.node ?? "")) < ($1.scope.rawValue + ($1.node ?? "")) }
        }
    }

    func edit(runID: UUID) async throws {
        let before = try await snapshot(runID: runID)
        guard V02Fixture.exact(before, owner: false, edited: false, requireShares: !localOnly),
              let owner, let store = stores[.sharedStore] else { throw V02Error.editNotReady }
        let context = owner.newBackgroundContext()
        let storeURL = store.url
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == storeURL }) else { throw V02Error.missingStores }
            let objects = try context.fetch(Self.request(runID, store: store)).filter { $0.value(forKey: "node") as? String == "A-001" }
            guard objects.count == 1, let object = objects.first,
                  object.value(forKey: "value") as? String == "alpha" else { throw V02Error.editNotReady }
            object.setValue(V02Fixture.editedValue, forKey: "value")
            try context.save()
        }
    }

    func close() async throws {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let owner else { return }
        owner.viewContext.reset()
        for store in owner.persistentStoreCoordinator.persistentStores { try owner.persistentStoreCoordinator.remove(store) }
        stores = [:]; self.owner = nil
    }

    nonisolated private static func request(_ runID: UUID, store: NSPersistentStore) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "V01T6Member")
        request.predicate = NSPredicate(format: "runID == %@", runID.uuidString)
        request.affectedStores = [store]
        return request
    }

    nonisolated private static func shareInfo(_ share: CKShare, currentUser: CKRecord.ID, runID: UUID) -> V02ShareInfo {
        V02ShareInfo(id: .make(share.recordID, currentUser: currentUser, runID: runID), publicPermission: share.publicPermission.rawValue,
            currentUserRole: share.currentUserParticipant?.role.rawValue, currentUserPermission: share.currentUserParticipant?.permission.rawValue,
            currentUserAcceptance: share.currentUserParticipant?.acceptanceStatus.rawValue,
            participants: share.participants.map { V02Participant(role: $0.role.rawValue, permission: $0.permission.rawValue, acceptance: $0.acceptanceStatus.rawValue) }
                .sorted { [$0.role, $0.permission, $0.acceptance].lexicographicallyPrecedes([$1.role, $1.permission, $1.acceptance]) })
    }
}

// The membership control uses this same stack with only private scope selected.
// These mutations intentionally never invoke a share API for the new object.
extension V02CloudStore: V01MembershipStoreAccess {
    func addMembershipChild(runID: UUID) async throws {
        try await mutateMembership(runID: runID, adding: true)
    }
    func deleteMembershipChild(runID: UUID) async throws {
        try await mutateMembership(runID: runID, adding: false)
    }
    private func mutateMembership(runID: UUID, adding: Bool) async throws {
        guard scopes == [.privateStore], let owner, let url = stores[.privateStore]?.url else { throw V02Error.missingStores }
        let context = owner.newBackgroundContext()
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == url }) else { throw V02Error.missingStores }
            let objects = try context.fetch(Self.request(runID, store: store))
            let roots = objects.filter { $0.value(forKey: "node") as? String == "A-root" && $0.value(forKey: "graph") as? String == "A" }
            let firstChildren = objects.filter { $0.value(forKey: "node") as? String == "A-001" && $0.value(forKey: "graph") as? String == "A" }
            let newChildren = objects.filter { $0.value(forKey: "node") as? String == V01MembershipFixture.addedNode }
            guard roots.count == 1, let root = roots.first, firstChildren.count == 1, let first = firstChildren.first,
                  root.value(forKey: "kind") as? String == "root", first.value(forKey: "parent") as? NSManagedObject === root else { throw V02Error.invalidFixture }
            if adding {
                guard objects.count == 5, newChildren.isEmpty, first.value(forKey: "value") as? String == "alpha" else { throw V02Error.editNotReady }
                let child = NSEntityDescription.insertNewObject(forEntityName: "V01T6Member", into: context)
                context.assign(child, to: store)
                for (key, value) in ["runID": runID.uuidString, "graph": "A", "node": V01MembershipFixture.addedNode, "kind": "item", "value": "delta"] {
                    child.setValue(value, forKey: key)
                }
                child.setValue(root, forKey: "parent")
                first.setValue(V01MembershipFixture.updatedValue, forKey: "value")
            } else {
                guard objects.count == 6, newChildren.count == 1, let child = newChildren.first,
                      first.value(forKey: "value") as? String == V01MembershipFixture.updatedValue,
                      child.value(forKey: "value") as? String == "delta", child.value(forKey: "parent") as? NSManagedObject === root else { throw V02Error.editNotReady }
                context.delete(child)
            }
            try context.save()
        }
    }
}

extension V02CloudStore: V02PermissionStoreAccess {
    func changeParticipantPermission(runID: UUID, recipient: V02PrivateID, from oldPermission: CKShare.ParticipantPermission,
                                     to newPermission: CKShare.ParticipantPermission, checkpoint: () throws -> Void) async throws {
        guard scopes == V02Scope.allCases, let cloud = owner as? NSPersistentCloudKitContainer,
              let store = stores[.privateStore] else { throw V02Error.missingStores }
        let share = try rootShare("A", runID: runID)
        let others = share.participants.filter { $0.role != .owner }
        guard share.publicPermission == .none, share.participants.filter({ $0.role == .owner }).count == 1,
              others.count == 1, let participant = others.first, participant.role == .privateUser,
              participant.acceptanceStatus == .accepted, participant.permission == oldPermission,
              participant.userIdentity.userRecordID == recipient.recordID,
              T6Share(try rootShare("B", runID: runID)).nonOwnerCount == 0 else { throw V02Error.unexpectedParticipant }
        participant.permission = newPermission
        try checkpoint()
        let saved = try await persist(share, store: store, cloud: cloud, graph: "A")
        guard saved.publicPermission == .none, saved.participants.filter({ $0.role != .owner }).count == 1,
              saved.participants.first(where: { $0.userIdentity.userRecordID == recipient.recordID })?.permission == newPermission else { throw V02Error.invalidShare }
    }

    func attemptReadOnlySave(runID: UUID) async throws -> V02ReadOnlyAttempt {
        let before = try await snapshot(runID: runID)
        guard localOnly ? V02Fixture.exact(before, owner: false, edited: true, requireShares: false)
            : V02PermissionFixture.exact(before, owner: false, permission: .readOnly),
              let owner, let url = stores[.sharedStore]?.url else { throw V02Error.editNotReady }
        let context = owner.newBackgroundContext()
        let cloud = owner as? NSPersistentCloudKitContainer
        var result = try await context.perform {
            defer { context.reset() } // Discard only pending changes after failure; never restore persisted values.
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == url }) else { throw V02Error.missingStores }
            let objects = try context.fetch(Self.request(runID, store: store))
                .filter { $0.value(forKey: "node") as? String == "A-001" && $0.value(forKey: "graph") as? String == "A" }
            guard objects.count == 1, let object = objects.first,
                  object.value(forKey: "value") as? String == V02Fixture.editedValue else { throw V02Error.editNotReady }
            return V02ReadOnlyAttempt.perform(canUpdate: cloud?.canUpdateRecord(forManagedObjectWith: object.objectID),
                canModify: cloud?.canModifyManagedObjects(in: store), valueBefore: object.value(forKey: "value") as? String) {
                object.setValue(V02PermissionFixture.attemptedValue, forKey: "value")
                try context.save() // Exactly one real attempt, even if canUpdateRecord returned false.
            }
        }
        let fresh = owner.newBackgroundContext()
        do {
            result.freshContextValue = try await fresh.perform {
                defer { fresh.reset() }
                guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == url }) else { throw V02Error.missingStores }
                let objects = try fresh.fetch(Self.request(runID, store: store)).filter { $0.value(forKey: "node") as? String == "A-001" }
                guard objects.count == 1 else { throw V02Error.invalidFixture }
                return objects[0].value(forKey: "value") as? String
            }
        } catch { result.freshReadErrors = [v01ErrorCode(error)] }
        return result
    }
}

extension V02CloudStore: V02RevocationStoreAccess {
    func captureRevocationHistoryAnchor() async throws -> Bool {
        guard let owner, let url = stores[.sharedStore]?.url else { throw V02Error.missingStores }
        let context = owner.newBackgroundContext()
        let data: Data? = try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == url }) else { throw V02Error.missingStores }
            guard let token = owner.persistentStoreCoordinator.currentPersistentHistoryToken(fromStores: [store]) else { return nil }
            return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        }
        revocationHistoryTokenData = data
        return data != nil
    }
    func revokeParticipant(runID: UUID, recipient: V02PrivateID, checkpoint: () throws -> Void) async throws {
        guard scopes == V02Scope.allCases, let cloud = owner as? NSPersistentCloudKitContainer,
              let store = stores[.privateStore] else { throw V02Error.missingStores }
        let share = try rootShare("A", runID: runID)
        let participants = share.participants.filter { $0.role != .owner }
        guard share.publicPermission == .none, share.participants.filter({ $0.role == .owner }).count == 1,
              participants.count == 1, let participant = participants.first, participant.role == .privateUser,
              participant.acceptanceStatus == .accepted, [.readOnly, .readWrite].contains(participant.permission),
              participant.userIdentity.userRecordID == recipient.recordID else { throw V02Error.unexpectedParticipant }
        share.removeParticipant(participant)
        try checkpoint()
        let saved = try await persist(share, store: store, cloud: cloud, graph: "A")
        guard T6Share(saved).ownerCount == 1, T6Share(saved).nonOwnerCount == 0, saved.publicPermission == .none else { throw V02Error.invalidShare }
    }

    func captureWatchedObjects(runID: UUID) async throws -> [V02RevocationObject] {
        guard let owner, let url = stores[.sharedStore]?.url else { throw V02Error.missingStores }
        let context = owner.newBackgroundContext()
        return try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == url }) else { throw V02Error.missingStores }
            return try context.fetch(Self.request(runID, store: store)).map {
                V02RevocationObject(node: $0.value(forKey: "node") as? String, objectURI: $0.objectID.uriRepresentation().absoluteString)
            }.sorted { ($0.node ?? "") < ($1.node ?? "") }
        }
    }

    func revocationHistory(since: Date, watchedURIs: [String]) async throws -> V02RevocationHistory {
        guard let owner, let url = stores[.sharedStore]?.url else { throw V02Error.missingStores }
        let context = owner.newBackgroundContext()
        let tokenData = revocationHistoryTokenData
        return try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == url }) else { throw V02Error.missingStores }
            let request: NSPersistentHistoryChangeRequest
            if let tokenData, let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: tokenData) {
                request = .fetchHistory(after: token)
            } else { request = .fetchHistory(after: since) }
            request.affectedStores = [store]
            request.resultType = .transactionsAndChanges
            let fetch = NSPersistentHistoryTransaction.fetchRequest!
            fetch.fetchLimit = 65
            request.fetchRequest = fetch
            guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction] else {
                return V02RevocationHistory(available: false, transactions: 0, truncated: false, watchedInserts: 0,
                    watchedUpdates: 0, watchedDeletes: 0, watchedDeletedURIs: [], error: "History result unavailable")
            }
            var inserts = 0, updates = 0, deletes = 0
            var deleted: Set<String> = []
            let watched = Set(watchedURIs)
            var inspectedChanges = 0
            var truncated = transactions.count > 64
            for transaction in transactions.prefix(64) {
                for change in transaction.changes ?? [] {
                    inspectedChanges += 1
                    if inspectedChanges > 512 { truncated = true; break }
                    let uri = change.changedObjectID.uriRepresentation().absoluteString
                    guard watched.contains(uri) else { continue }
                    switch change.changeType {
                    case .insert: inserts += 1
                    case .update: updates += 1
                    case .delete: deletes += 1; deleted.insert(uri)
                    @unknown default: break
                    }
                }
                if inspectedChanges > 512 { break }
            }
            return V02RevocationHistory(available: true, transactions: min(transactions.count, 64), truncated: truncated,
                watchedInserts: inserts, watchedUpdates: updates, watchedDeletes: deletes, watchedDeletedURIs: deleted.sorted(), error: nil)
        }
    }
}

extension V02CloudStore: V02LifecycleStoreAccess {
    func reinviteParticipant(runID: UUID, caseID: UUID, recipient: V02PrivateID, container: String,
                             checkpoint: () throws -> Void) async throws -> V02Envelope {
        guard recipient.recordID != currentUser, let cloud = owner as? NSPersistentCloudKitContainer,
              let store = stores[.privateStore] else { throw V02Error.invalidAccount }
        let share = try rootShare("A", runID: runID)
        guard share.publicPermission == .none, T6Share(share).ownerCount == 1, T6Share(share).nonOwnerCount == 0 else { throw V02Error.invalidShare }
        let people: [CKShare.Participant] = try await withCheckedThrowingContinuation { continuation in
            cloud.fetchParticipants(matching: [CKUserIdentity.LookupInfo(userRecordID: recipient.recordID)], into: store) { @Sendable people, error in
                if let error { continuation.resume(throwing: error) }
                else if let people { continuation.resume(returning: people) }
                else { continuation.resume(throwing: V02Error.missingResponse) }
            }
        }
        guard people.count == 1, let person = people.first, person.userIdentity.userRecordID == recipient.recordID else { throw V02Error.unexpectedParticipant }
        person.role = .privateUser; person.permission = .readWrite; share.addParticipant(person)
        try checkpoint()
        let saved = try await persist(share, store: store, cloud: cloud, graph: "A")
        guard saved.publicPermission == .none, T6Share(saved).ownerCount == 1, T6Share(saved).nonOwnerCount == 1,
              let url = saved.url else { throw V02Error.invalidShare }
        return V02Envelope(purpose: "lifecycle-invitation", runID: runID, containerIdentifier: container,
            account: V02PrivateID(currentUser), recipient: recipient, share: V02PrivateID(saved.recordID), shareURL: url, caseID: caseID)
    }

    func reacceptInvitation(_ invitation: V02Envelope, runID: UUID, caseID: UUID, container: String,
                             checkpoint: () throws -> Void) async throws -> V02ReacceptResult {
        try invitation.validate(runID: runID, container: container, purpose: "lifecycle-invitation")
        guard invitation.caseID == caseID, invitation.recipient?.recordID == currentUser, invitation.account.recordID != currentUser,
              let expectedShare = invitation.share, let url = invitation.shareURL, url.scheme == "https",
              ["www.icloud.com", "icloud.com"].contains(url.host?.lowercased() ?? ""), url.path.hasPrefix("/share/"),
              let cloud = owner as? NSPersistentCloudKitContainer, let store = stores[.sharedStore] else { throw V02Error.invalidEnvelope }
        let metadata = try await CKContainer(identifier: container).shareMetadata(for: url)
        guard metadata.containerIdentifier == container, metadata.ownerIdentity.userRecordID == invitation.account.recordID,
              expectedShare.matches(metadata.share.recordID, shareOwner: invitation.account.recordID), metadata.share.publicPermission == .none,
              metadata.participantRole == .privateUser, metadata.participantPermission == .readWrite else { throw V02Error.invalidMetadata }
        if metadata.participantStatus == .accepted {
            return V02ReacceptResult(metadataStatus: metadata.participantStatus.rawValue, acceptanceAPICalled: false, alreadyAccepted: true)
        }
        guard metadata.participantStatus == .pending else { throw V02Error.invalidMetadata }
        try checkpoint()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cloud.acceptShareInvitations(from: [metadata], into: store) { @Sendable accepted, error in
                if let error { continuation.resume(throwing: error) }
                else if accepted?.count == 1 { continuation.resume() }
                else { continuation.resume(throwing: V02Error.missingResponse) }
            }
        }
        return V02ReacceptResult(metadataStatus: metadata.participantStatus.rawValue, acceptanceAPICalled: true, alreadyAccepted: false)
    }

    func leaveSharedA(_ invitation: V02Envelope, runID: UUID, caseID: UUID, container: String,
                       checkpoint: () throws -> Void) async throws -> V02RecordKey? {
        try invitation.validate(runID: runID, container: container, purpose: "lifecycle-invitation")
        guard invitation.caseID == caseID, invitation.recipient?.recordID == currentUser, invitation.account.recordID != currentUser,
              let expected = invitation.share, scopes == V02Scope.allCases,
              let cloud = owner as? NSPersistentCloudKitContainer, let shared = stores[.sharedStore], shared !== stores[.privateStore],
              cloud.persistentStoreDescriptions.first(where: { $0.url == shared.url })?.cloudKitContainerOptions?.databaseScope == .shared else { throw V02Error.invalidShare }
        let rows = try await snapshot(runID: runID)
        let expectedKey = V02RecordKey.make(expected.recordID, currentUser: invitation.account.recordID, runID: runID)
        guard V02LifecycleFixture.permitsLeave(rows, scope: .sharedStore, role: .privateUser, expectedShare: expectedKey) else { throw V02Error.invalidFixture }
        let request = Self.request(runID, store: shared)
        request.predicate = NSPredicate(format: "runID == %@ AND node == 'A-root' AND graph == 'A'", runID.uuidString)
        let roots = try cloud.viewContext.fetch(request)
        guard roots.count == 1, let root = roots.first,
              let share = try cloud.fetchShares(matching: [root.objectID])[root.objectID], share.currentUserParticipant?.role == .privateUser,
              expected.matches(share.recordID, shareOwner: invitation.account.recordID) else { throw V02Error.invalidShare }
        let zone = share.recordID.zoneID
        try checkpoint()
        let returned: CKRecordZone.ID? = try await withCheckedThrowingContinuation { continuation in
            trace?.record(.purgeCallEntered, graph: "A")
            // A non-nil, validated shared store is mandatory: never purge owner-private data or all stores.
            cloud.purgeObjectsAndRecordsInZone(with: zone, in: shared) { @Sendable [trace] returned, error in
                trace?.record(.purgeCallbackEntered, graph: "A")
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: returned) }
            }
            trace?.record(.purgeCallReturned, graph: "A")
        }
        if let returned {
            let key = V02RecordKey.make(CKRecord.ID(recordName: share.recordID.recordName, zoneID: returned), currentUser: currentUser, runID: runID)
            guard key == expectedKey else { throw V02Error.invalidShare }
            return key
        }
        return nil // A nil zone with no error is retained, not silently interpreted as data removal.
    }
}

extension V02CloudStore: V02LeaveRecoveryStoreAccess {
    func invitationMetadata(_ invitation: V02Envelope, runID: UUID, priorCaseID: UUID, container: String) async throws -> V02LeaveMetadata {
        try invitation.validate(runID: runID, container: container, purpose: "lifecycle-invitation")
        guard invitation.caseID == priorCaseID, let expected = invitation.share, let url = invitation.shareURL,
              invitation.account.recordID == currentUser || invitation.recipient?.recordID == currentUser,
              url.scheme == "https", ["icloud.com", "www.icloud.com"].contains(url.host?.lowercased() ?? ""),
              url.path.hasPrefix("/share/") else { throw V02Error.invalidEnvelope }
        var result = V02LeaveMetadata(requestedAt: Date())
        do {
            let metadata = try await CKContainer(identifier: container).shareMetadata(for: url)
            result.returnedMetadata = true
            result.participantStatus = metadata.participantStatus.rawValue
            result.participantRole = metadata.participantRole.rawValue
            result.participantPermission = metadata.participantPermission.rawValue
            result.publicPermission = metadata.share.publicPermission.rawValue
            result.containerMatches = metadata.containerIdentifier == container
            result.ownerMatches = metadata.ownerIdentity.userRecordID == invitation.account.recordID
            result.shareMatches = expected.matches(metadata.share.recordID, shareOwner: invitation.account.recordID)
            result.shareID = V02RecordKey.make(metadata.share.recordID, currentUser: invitation.account.recordID, runID: runID)
        } catch { result.errors = V02PublicReadError.capture(error) }
        result.completedAt = Date()
        return result
    }
}

extension V02CloudStore: V02MutationStoreAccess {
    func mutate(_ role: V02MutationRole, runID: UUID) async throws {
        if role == .participantExplicitAdd {
            try await addParticipantObjectToExistingShare(runID: runID)
            return
        }
        guard role.writes, scopes == V02Scope.allCases,
              let owner, let cloud = owner as? NSPersistentCloudKitContainer,
              let url = stores[role.isOwner ? .privateStore : .sharedStore]?.url else { throw V02Error.missingStores }
        let context = owner.newBackgroundContext()
        try await context.perform {
            defer { context.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == url }),
                  cloud.canModifyManagedObjects(in: store) else { throw V02Error.editNotReady }
            let objects = try context.fetch(Self.request(runID, store: store))
            func one(_ node: String) throws -> NSManagedObject {
                let found = objects.filter { $0.value(forKey: "node") as? String == node }
                guard found.count == 1, let object = found.first,
                      object.value(forKey: "graph") as? String == "A" else { throw V02Error.invalidFixture }
                return object
            }
            let root = try one("A-root")
            guard cloud.canUpdateRecord(forManagedObjectWith: root.objectID) else { throw V02Error.editNotReady }
            switch role {
            case .ownerAdd, .participantAdd:
                let node = role == .ownerAdd ? "A-003" : "A-004"
                let edited = try one(role == .ownerAdd ? "A-001" : "A-002")
                let expectedValue = role == .ownerAdd ? "alpha" : "beta"
                guard objects.filter({ $0.value(forKey: "node") as? String == node }).isEmpty,
                      edited.value(forKey: "value") as? String == expectedValue,
                      cloud.canUpdateRecord(forManagedObjectWith: edited.objectID) else { throw V02Error.editNotReady }
                let child = NSEntityDescription.insertNewObject(forEntityName: "V01T6Member", into: context)
                context.assign(child, to: store)
                for (key, value) in ["runID": runID.uuidString, "graph": "A", "node": node,
                                     "kind": "item", "value": role == .ownerAdd ? "owner-delta" : "participant-delta"] {
                    child.setValue(value, forKey: key)
                }
                child.setValue(root, forKey: "parent")
                edited.setValue(role == .ownerAdd ? V02MutationFixture.ownerValue : V02MutationFixture.participantValue,
                                forKey: "value")
            case .ownerDelete, .participantDelete, .participantExplicitDelete:
                let child = try one(role == .ownerDelete ? "A-003" : "A-004")
                guard child.value(forKey: "parent") as? NSManagedObject === root,
                      cloud.canDeleteRecord(forManagedObjectWith: child.objectID) else { throw V02Error.editNotReady }
                context.delete(child)
            default:
                throw V02Error.editNotReady
            }
            try context.save()
        }
    }

    private func addParticipantObjectToExistingShare(runID: UUID) async throws {
        guard let owner, let cloud = owner as? NSPersistentCloudKitContainer,
              let privateStore = stores[.privateStore], let sharedStore = stores[.sharedStore],
              cloud.canModifyManagedObjects(in: sharedStore) else { throw V02Error.editNotReady }
        let context = owner.viewContext
        let sharedRows = try context.fetch(Self.request(runID, store: sharedStore))
        guard sharedRows.count == 3,
              sharedRows.filter({ $0.value(forKey: "node") as? String == "A-root" }).count == 1,
              let root = sharedRows.first(where: { $0.value(forKey: "node") as? String == "A-root" }),
              cloud.canUpdateRecord(forManagedObjectWith: root.objectID),
              try context.fetch(Self.request(runID, store: privateStore)).isEmpty,
              let share = try cloud.fetchShares(matching: [root.objectID])[root.objectID],
              T6Share(share).nonOwnerCount == 1 else { throw V02Error.invalidFixture }

        // Share an unconnected object first: Apple's API rejects a traversal
        // through an object that already belongs to a share.
        let child = NSEntityDescription.insertNewObject(forEntityName: "V01T6Member", into: context)
        context.assign(child, to: sharedStore)
        for (key, value) in ["runID": runID.uuidString, "graph": "A", "node": "A-004",
                             "kind": "item", "value": "participant-delta"] {
            child.setValue(value, forKey: key)
        }
        try context.save()
        let assigned: CKShare = try await withCheckedThrowingContinuation { continuation in
            cloud.share([child], to: share) { _, returnedShare, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let returnedShare { continuation.resume(returning: returnedShare) }
                else { continuation.resume(throwing: V02Error.missingResponse) }
            }
        }
        guard assigned.recordID == share.recordID else { throw V02Error.invalidShare }
        let linkingContext = owner.newBackgroundContext()
        let sharedURL = sharedStore.url
        try await linkingContext.perform {
            defer { linkingContext.reset() }
            guard let store = owner.persistentStoreCoordinator.persistentStores.first(where: { $0.url == sharedURL }) else {
                throw V02Error.missingStores
            }
            let rows = try linkingContext.fetch(Self.request(runID, store: store))
            guard rows.count == 4,
                  let sharedRoot = rows.first(where: { $0.value(forKey: "node") as? String == "A-root" }),
                  let sharedChild = rows.first(where: { $0.value(forKey: "node") as? String == "A-004" }),
                  sharedChild.value(forKey: "parent") == nil else { throw V02Error.invalidFixture }
            sharedChild.setValue(sharedRoot, forKey: "parent")
            try linkingContext.save()
        }
    }
}
