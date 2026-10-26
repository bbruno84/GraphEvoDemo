import CoreData
import Foundation

/// Immutable values are the only data allowed to leave a context operation.
public struct ProbeValue: Sendable, Equatable {
    public let key: String
    public let value: Int64
    public let executedOnMainThread: Bool
}

public enum ProbeError: Error, Equatable {
    case closed
    case duplicateKey
    case deliberateRollback
    case missingStore
}

/// The caller task's cancellation state is not inherited by a Core Data
/// perform closure. A cancellation handler carries it to the commit boundary.
private final class CommitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

/// A candidate ownership experiment, not a GraphEvo API or CloudKit stack.
/// One private context serializes read/modify/save, even when actor calls reenter.
public actor ProbeStore {
    private let container: NSPersistentContainer
    private let writer: NSManagedObjectContext
    private var closed = false

    private init(container: NSPersistentContainer) {
        self.container = container
        writer = container.newBackgroundContext()
    }

    public static func open(at url: URL) async throws -> ProbeStore {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "ProbeItem"
        entity.managedObjectClassName = "NSManagedObject"
        let key = NSAttributeDescription()
        key.name = "key"
        key.attributeType = .stringAttributeType
        key.isOptional = false
        let value = NSAttributeDescription()
        value.name = "value"
        value.attributeType = .integer64AttributeType
        value.isOptional = false
        entity.properties = [key, value]
        model.entities = [entity]
        let container = NSPersistentContainer(name: "ConcurrencyProbe", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.shouldAddStoreAsynchronously = true
        description.shouldMigrateStoreAutomatically = false
        description.shouldInferMappingModelAutomatically = false
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        return ProbeStore(container: container)
    }

    /// Cancellation is checked before enqueue, not represented as a post-commit rollback.
    public func increment(
        _ key: String,
        rollback: Bool = false,
        checkCancellation: Bool = true,
        checkCancellationBeforeCommit: Bool = false,
        beforeCommit: (@Sendable () -> Void)? = nil
    ) async throws -> ProbeValue {
        guard !closed else { throw ProbeError.closed }
        if checkCancellation { try Task.checkCancellation() }
        let context = writer
        let cancellation = CommitCancellation()
        return try await withTaskCancellationHandler {
            try await context.perform {
                do {
                    let request = NSFetchRequest<NSManagedObject>(entityName: "ProbeItem")
                    request.predicate = NSPredicate(format: "key == %@", key)
                    let matches = try context.fetch(request)
                    guard matches.count < 2 else { throw ProbeError.duplicateKey }
                    let object = matches.first ?? NSEntityDescription.insertNewObject(forEntityName: "ProbeItem", into: context)
                    object.setValue(key, forKey: "key")
                    let next = (object.value(forKey: "value") as? NSNumber)?.int64Value ?? 0
                    object.setValue(next + 1, forKey: "value")
                    beforeCommit?()
                    if rollback { throw ProbeError.deliberateRollback }
                    if checkCancellationBeforeCommit { try cancellation.check() }
                    try context.save()
                    let result = ProbeValue(key: key, value: next + 1, executedOnMainThread: Thread.isMainThread)
                    context.reset()
                    return result
                } catch {
                    context.rollback()
                    context.reset()
                    throw error
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func value(for key: String) async throws -> ProbeValue? {
        guard !closed else { throw ProbeError.closed }
        let context = writer
        return try await context.perform {
            defer { context.reset() }
            let request = NSFetchRequest<NSManagedObject>(entityName: "ProbeItem")
            request.predicate = NSPredicate(format: "key == %@", key)
            let matches = try context.fetch(request)
            guard matches.count < 2 else { throw ProbeError.duplicateKey }
            guard let object = matches.first else { return nil }
            return ProbeValue(key: key, value: (object.value(forKey: "value") as? NSNumber)?.int64Value ?? 0,
                              executedOnMainThread: Thread.isMainThread)
        }
    }

    /// Enqueued writer work precedes this reset; later calls are rejected before enqueue.
    public func close() async throws {
        guard !closed else { return }
        closed = true
        let context = writer
        await context.perform { context.reset() }
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}

/// Explicit process-local ownership. The framework does not provide this registry.
public actor ProbeRegistry {
    private var owners: [String: Task<ProbeStore, Error>] = [:]
    private var closed = false

    public init() {}

    public func open(at url: URL) async throws -> ProbeStore {
        guard !closed else { throw ProbeError.closed }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = owners[canonical.path] { return try await existing.value }
        let task = Task { try await ProbeStore.open(at: canonical) }
        owners[canonical.path] = task
        do { return try await task.value }
        catch { owners.removeValue(forKey: canonical.path); throw error }
    }

    public func close() async throws {
        guard !closed else { return }
        closed = true
        let pending = Array(owners.values)
        owners.removeAll()
        for task in pending { try await task.value.close() }
    }
}
