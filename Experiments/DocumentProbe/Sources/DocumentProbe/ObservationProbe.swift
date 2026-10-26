import Foundation
import CoreData

public struct ObservationRow: Sendable, Equatable {
    public let id: String
    public let title: String
    public let rank: Int64
}

/// A local NSFetchedResultsController experiment, distinct from durable event delivery.
@MainActor
public final class ObservationProbe {
    private let container: NSPersistentContainer
    private init(_ container: NSPersistentContainer) { self.container = container }
    public static func open(_ url: URL) async throws -> ObservationProbe {
        let entity = NSEntityDescription(); entity.name = "ObservedItem"; entity.managedObjectClassName = "NSManagedObject"
        var properties: [NSPropertyDescription] = ["id", "title"].map { name in
            let field = NSAttributeDescription(); field.name = name; field.attributeType = .stringAttributeType; field.isOptional = true; return field
        }
        let rank = NSAttributeDescription(); rank.name = "rank"; rank.attributeType = .integer64AttributeType; rank.isOptional = true
        let parent = NSRelationshipDescription(), children = NSRelationshipDescription()
        parent.name = "parent"; parent.destinationEntity = entity; parent.maxCount = 1; parent.isOptional = true; parent.deleteRule = .nullifyDeleteRule
        children.name = "children"; children.destinationEntity = entity; children.maxCount = 0; children.isOptional = true; children.deleteRule = .nullifyDeleteRule
        parent.inverseRelationship = children; children.inverseRelationship = parent
        properties += [rank, parent, children]; entity.properties = properties
        let model = NSManagedObjectModel(); model.entities = [entity]
        let container = NSPersistentContainer(name: "ObservationProbe", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url); description.shouldAddStoreAsynchronously = true
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return ObservationProbe(container)
    }
    public func write(id: String, title: String, rank: Int64, parentID: String? = nil) async throws {
        let context = container.newBackgroundContext()
        try await context.perform {
            defer { context.reset() }
            let request = NSFetchRequest<NSManagedObject>(entityName: "ObservedItem")
            request.predicate = NSPredicate(format: "id == %@", id)
            let object = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: "ObservedItem", into: context)
            object.setValue(id, forKey: "id"); object.setValue(title, forKey: "title"); object.setValue(rank, forKey: "rank")
            if let parentID {
                request.predicate = NSPredicate(format: "id == %@", parentID)
                guard let parent = try context.fetch(request).first else { throw DocumentError.missingParent }
                object.setValue(parent, forKey: "parent")
            }
            try context.save()
        }
    }
    public func delete(id: String) async throws {
        let context = container.newBackgroundContext()
        try await context.perform {
            defer { context.reset() }; let request = NSFetchRequest<NSManagedObject>(entityName: "ObservedItem")
            request.predicate = NSPredicate(format: "id == %@", id)
            for object in try context.fetch(request) { context.delete(object) }; try context.save()
        }
    }
    public func observe(childTitle: String? = nil, capacity: Int = 1) throws -> ObservationHandle {
        try ObservationHandle(context: container.viewContext, childTitle: childTitle, capacity: capacity)
    }
    public func fresh(childTitle: String? = nil) async throws -> [ObservationRow] {
        let context = container.newBackgroundContext()
        return try await context.perform {
            defer { context.reset() }
            let request = Self.request(childTitle: childTitle)
            return try context.fetch(request).map(Self.row)
        }
    }
    /// Local queue processing assistance, never a CloudKit synchronization barrier.
    public func settle() async {
        for _ in 0..<3 { await container.viewContext.perform { self.container.viewContext.processPendingChanges() }; await Task.yield() }
    }
    public func close() throws {
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
    }
    nonisolated static func request(childTitle: String?) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ObservedItem")
        if let childTitle { request.predicate = NSPredicate(format: "ANY children.title == %@", childTitle) }
        request.sortDescriptors = [NSSortDescriptor(key: "rank", ascending: true), NSSortDescriptor(key: "id", ascending: true)]
        return request
    }
    nonisolated static func row(_ object: NSManagedObject) throws -> ObservationRow {
        guard let id = object.value(forKey: "id") as? String, let title = object.value(forKey: "title") as? String,
              let rank = object.value(forKey: "rank") as? NSNumber else { throw DocumentError.corruptRecord }
        return ObservationRow(id: id, title: title, rank: rank.int64Value)
    }
}

@MainActor
public final class ObservationHandle: NSObject, NSFetchedResultsControllerDelegate {
    public let stream: AsyncThrowingStream<[ObservationRow], Error>
    private let continuation: AsyncThrowingStream<[ObservationRow], Error>.Continuation
    private var controller: NSFetchedResultsController<NSManagedObject>?
    public private(set) var latest: [ObservationRow] = []
    public private(set) var droppedBatches = 0
    public private(set) var publicationCount = 0
    public private(set) var cancelled = false
    init(context: NSManagedObjectContext, childTitle: String?, capacity: Int) throws {
        let pair = AsyncThrowingStream<[ObservationRow], Error>.makeStream(bufferingPolicy: .bufferingNewest(max(1, capacity)))
        stream = pair.stream; continuation = pair.continuation
        super.init()
        // Delegate execution is confined to this explicitly main-queue context.
        precondition(context.concurrencyType == .mainQueueConcurrencyType)
        let controller = NSFetchedResultsController(fetchRequest: ObservationProbe.request(childTitle: childTitle), managedObjectContext: context, sectionNameKeyPath: nil, cacheName: nil)
        self.controller = controller; controller.delegate = self
        try controller.performFetch(); publish()
        continuation.onTermination = { @Sendable [weak self] _ in Task { @MainActor in self?.cancel() } }
    }
    nonisolated public func controllerDidChangeContent(_ controller: NSFetchedResultsController<any NSFetchRequestResult>) {
        // NSFetchedResultsController delivers this delegate on its context queue.
        // The initializer accepts only a main-queue context; no managed objects cross.
        MainActor.assumeIsolated { publish() }
    }
    private func publish() {
        guard !cancelled, let controller else { return }
        do {
            latest = try (controller.fetchedObjects ?? []).map(ObservationProbe.row)
            publicationCount += 1
            if case .dropped = continuation.yield(latest) { droppedBatches += 1 }
        } catch { continuation.finish(throwing: error); controller.delegate = nil }
    }
    public func cancel() {
        guard !cancelled else { return }; cancelled = true
        controller?.delegate = nil; controller = nil; continuation.finish()
    }
}
