import Foundation
import CoreData

/// One fixed-shape mapping candidate; no final graph-model protocol is proposed.
public protocol DocumentModel: Sendable {
    var document: DocumentValue { get }
    init(document: DocumentValue) throws
}

public struct DocumentValue: Sendable, Equatable {
    public var id: String
    public var graph: String
    public var title: String?
    public var rank: Int64
    public var parentID: String?
    public var bytes: Data?
    public var filename: String?
    public var contentType: String?
    public init(id: String, graph: String, title: String? = nil, rank: Int64 = 0,
                parentID: String? = nil, bytes: Data? = nil, filename: String? = nil, contentType: String? = nil) {
        self.id = id; self.graph = graph; self.title = title; self.rank = rank
        self.parentID = parentID; self.bytes = bytes; self.filename = filename; self.contentType = contentType
    }
    func validate() throws {
        guard !id.isEmpty, !graph.isEmpty else { throw DocumentError.invalidValue }
        if bytes != nil && (filename?.isEmpty != false || contentType?.isEmpty != false) { throw DocumentError.invalidAttachment }
    }
}

public struct DocumentCursor: Sendable { public let rank: Int64; public let id: String
    public init(rank: Int64, id: String) { self.rank = rank; self.id = id }
}
public struct DocumentProjection: Sendable, Equatable { public let id: String; public let title: String? }
public enum DocumentError: Error, Equatable {
    case invalidValue, invalidAttachment, crossGraph, missingParent, corruptRecord, rollback, closed
}

/// Local direct-framework capabilities; one context serializes each complete operation.
public actor DocumentStore {
    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext
    private var closed = false
    private init(_ container: NSPersistentContainer) { self.container = container; context = container.newBackgroundContext() }
    public static func open(_ url: URL) async throws -> DocumentStore {
        let model = NSManagedObjectModel(), entity = NSEntityDescription()
        entity.name = "ProbeDocument"; entity.managedObjectClassName = "NSManagedObject"
        let fields: [(String, NSAttributeType)] = [("id", .stringAttributeType), ("graph", .stringAttributeType),
            ("title", .stringAttributeType), ("rank", .integer64AttributeType), ("bytes", .binaryDataAttributeType),
            ("filename", .stringAttributeType), ("contentType", .stringAttributeType)]
        var properties: [NSPropertyDescription] = fields.map { name, type in
            let attribute = NSAttributeDescription(); attribute.name = name; attribute.attributeType = type; attribute.isOptional = true
            if name == "bytes" { attribute.allowsExternalBinaryDataStorage = true }
            return attribute
        }
        let parent = NSRelationshipDescription(), children = NSRelationshipDescription()
        parent.name = "parent"; parent.destinationEntity = entity; parent.maxCount = 1; parent.isOptional = true; parent.deleteRule = .nullifyDeleteRule
        children.name = "children"; children.destinationEntity = entity; children.maxCount = 0; children.isOptional = true; children.deleteRule = .nullifyDeleteRule
        parent.inverseRelationship = children; children.inverseRelationship = parent
        properties += [parent, children]; entity.properties = properties; model.entities = [entity]
        let container = NSPersistentContainer(name: "DocumentProbe", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url); description.shouldAddStoreAsynchronously = true
        description.shouldMigrateStoreAutomatically = false; description.shouldInferMappingModelAutomatically = false
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return DocumentStore(container)
    }
    public func write<T: DocumentModel>(_ model: T, rollback: Bool = false) async throws {
        try await write(model.document, rollback: rollback)
    }
    public func write(_ value: DocumentValue, rollback: Bool = false) async throws {
        guard !closed else { throw DocumentError.closed }; try value.validate()
        let context = context
        try await context.perform {
            do {
                let object = try Self.find(value.id, context) ?? NSEntityDescription.insertNewObject(forEntityName: "ProbeDocument", into: context)
                if let oldGraph = object.value(forKey: "graph") as? String, oldGraph != value.graph { throw DocumentError.crossGraph }
                var parent: NSManagedObject?
                if let parentID = value.parentID {
                    guard let found = try Self.find(parentID, context) else { throw DocumentError.missingParent }
                    guard found.value(forKey: "graph") as? String == value.graph else { throw DocumentError.crossGraph }
                    parent = found
                }
                object.setValue(value.id, forKey: "id")
                object.setValue(value.graph, forKey: "graph")
                object.setValue(value.title, forKey: "title")
                object.setValue(value.rank, forKey: "rank")
                object.setValue(value.bytes, forKey: "bytes")
                object.setValue(value.filename, forKey: "filename")
                object.setValue(value.contentType, forKey: "contentType")
                object.setValue(parent, forKey: "parent")
                if rollback { throw DocumentError.rollback }
                try context.save(); context.reset()
            } catch { context.rollback(); context.reset(); throw error }
        }
    }
    public func read(_ id: String) async throws -> DocumentValue? {
        guard !closed else { throw DocumentError.closed }; let context = context
        return try await context.perform { defer { context.reset() }; return try Self.find(id, context).map(Self.decode) }
    }
    public func read<T: DocumentModel>(_ id: String, as type: T.Type) async throws -> T? {
        try await read(id).map(T.init(document:))
    }
    public func delete(_ id: String, rollback: Bool = false) async throws {
        guard !closed else { throw DocumentError.closed }; let context = context
        try await context.perform {
            do {
                if let object = try Self.find(id, context) { context.delete(object) }
                if rollback { throw DocumentError.rollback }
                try context.save(); context.reset()
            } catch { context.rollback(); context.reset(); throw error }
        }
    }
    /// Deterministic keyset order uses rank and identity, not an offset into changing rows.
    public func page(graph: String, after: DocumentCursor? = nil, limit: Int = 20) async throws -> [DocumentValue] {
        guard !closed else { throw DocumentError.closed }; let context = context
        return try await context.perform {
            defer { context.reset() }
            let request = Self.request(); var filters = [NSPredicate(format: "graph == %@", graph)]
            if let after { filters.append(NSPredicate(format: "rank > %lld OR (rank == %lld AND id > %@)", after.rank, after.rank, after.id)) }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: filters)
            request.sortDescriptors = [NSSortDescriptor(key: "rank", ascending: true), NSSortDescriptor(key: "id", ascending: true)]
            request.fetchLimit = max(1, limit)
            return try context.fetch(request).map(Self.decode)
        }
    }
    public func parents(graph: String, childTitle: String) async throws -> [DocumentValue] {
        guard !closed else { throw DocumentError.closed }; let context = context
        return try await context.perform {
            defer { context.reset() }; let request = Self.request()
            request.predicate = NSPredicate(format: "graph == %@ AND ANY children.title == %@", graph, childTitle)
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            return try context.fetch(request).map(Self.decode)
        }
    }
    public func summary(graph: String) async throws -> (count: Int, sum: Int64, titles: [DocumentProjection]) {
        guard !closed else { throw DocumentError.closed }; let context = context
        return try await context.perform {
            defer { context.reset() }; let predicate = NSPredicate(format: "graph == %@", graph)
            let countRequest = Self.request(); countRequest.predicate = predicate
            let count = try context.count(for: countRequest)
            let sum = NSExpressionDescription(); sum.name = "rankSum"
            sum.expression = NSExpression(forFunction: "sum:", arguments: [NSExpression(forKeyPath: "rank")]); sum.expressionResultType = .integer64AttributeType
            let aggregate = NSFetchRequest<NSDictionary>(entityName: "ProbeDocument")
            aggregate.predicate = predicate; aggregate.resultType = .dictionaryResultType; aggregate.propertiesToFetch = [sum]
            let total = (try context.fetch(aggregate).first?["rankSum"] as? NSNumber)?.int64Value ?? 0
            let projection = NSFetchRequest<NSDictionary>(entityName: "ProbeDocument")
            projection.predicate = predicate; projection.resultType = .dictionaryResultType; projection.propertiesToFetch = ["id", "title"]
            projection.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            let titles = try context.fetch(projection).map { value -> DocumentProjection in
                guard let id = value["id"] as? String else { throw DocumentError.corruptRecord }
                return DocumentProjection(id: id, title: value["title"] as? String)
            }
            return (count, total, titles)
        }
    }
    /// A saved Core Data row can be valid for the store but invalid for the application decoder.
    public func removeAttachmentMetadataForFixture(_ id: String) async throws {
        guard !closed else { throw DocumentError.closed }; let context = context
        try await context.perform { defer { context.reset() }; let object = try Self.find(id, context); object?.setValue(nil, forKey: "filename"); try context.save() }
    }
    public func close() async throws {
        guard !closed else { return }; closed = true; let context = context
        await context.perform { context.reset() }
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
    }
    nonisolated private static func request() -> NSFetchRequest<NSManagedObject> { NSFetchRequest(entityName: "ProbeDocument") }
    nonisolated private static func find(_ id: String, _ context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = request(); request.predicate = NSPredicate(format: "id == %@", id)
        let objects = try context.fetch(request); guard objects.count < 2 else { throw DocumentError.corruptRecord }; return objects.first
    }
    nonisolated private static func decode(_ object: NSManagedObject) throws -> DocumentValue {
        guard let id = object.value(forKey: "id") as? String, let graph = object.value(forKey: "graph") as? String,
              let rank = object.value(forKey: "rank") as? NSNumber else { throw DocumentError.corruptRecord }
        let value = DocumentValue(id: id, graph: graph, title: object.value(forKey: "title") as? String, rank: rank.int64Value,
            parentID: (object.value(forKey: "parent") as? NSManagedObject)?.value(forKey: "id") as? String,
            bytes: object.value(forKey: "bytes") as? Data, filename: object.value(forKey: "filename") as? String,
            contentType: object.value(forKey: "contentType") as? String)
        try value.validate(); return value
    }
}
