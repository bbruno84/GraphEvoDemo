import Foundation
import CoreData
import CloudKit

struct V01Row: Codable, Equatable {
    let runID: String?
    let logicalGraphID: String?
    let itemID: String?
    let value: String?

    static func fixture(_ runID: UUID) -> [V01Row] {
        [("A", "A-001", "alpha"), ("A", "A-002", "beta"), ("B", "B-001", "gamma")].map {
            V01Row(runID: runID.uuidString, logicalGraphID: $0.0, itemID: $0.1, value: $0.2)
        }
    }

    var sortKey: String { [runID, logicalGraphID, itemID, value].map { $0 ?? "<nil>" }.joined(separator: "|") }
}

struct V01Mapping: Codable {
    let itemID: String?
    let recordName: String?
    let zoneName: String?
    // CloudKit owner account identifiers are deliberately excluded.
}

struct V01Snapshot: Codable {
    var rows: [V01Row]
    var mappings: [V01Mapping]
    var storeIdentifier: String?
}

struct V01NativeEvent: Codable {
    let identifier: UUID
    let kind: String
    let started: Date
    let finished: Date?
    let succeeded: Bool
    let storeIdentifier: String
    let error: String?
    var ownerKey: String? = nil
}

func v01ErrorCode(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain):\(nsError.code)"
}

@MainActor
protocol V01StoreAccess: AnyObject {
    func open(at url: URL, containerIdentifier: String, event: @escaping (V01NativeEvent) -> Void) async throws
    func insert(_ rows: [V01Row]) async throws
    func snapshot(runID: UUID) async throws -> V01Snapshot
    func close() async throws
}

/// One owner for the explicitly configured SQLite files. This code never writes CKRecords directly.
@MainActor
final class V01CloudStore: V01TopologyStoreAccess {
    private var container: NSPersistentContainer?
    private let localOnlyForTests: Bool
    private let makeCloudOwner: @MainActor (NSManagedObjectModel) throws -> NSPersistentCloudKitContainer
    private(set) var loadResults: [V01StoreLoad] = []
    private var storeURLs: [String: URL] = [:]

    init(localOnlyForTests: Bool = false,
         makeCloudOwner: @escaping @MainActor (NSManagedObjectModel) throws -> NSPersistentCloudKitContainer = {
             NSPersistentCloudKitContainer(name: "V01Probe", managedObjectModel: $0)
         }) {
        self.localOnlyForTests = localOnlyForTests
        self.makeCloudOwner = makeCloudOwner
    }
    private var observer: NSObjectProtocol?

    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "V01ProbeItem"
        entity.managedObjectClassName = "NSManagedObject"
        entity.properties = ["runID", "logicalGraphID", "itemID", "value"].map { name in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = .stringAttributeType
            attribute.isOptional = true
            return attribute
        }
        model.entities = [entity]
        return model
    }

    func open(at url: URL, containerIdentifier: String, event: @escaping (V01NativeEvent) -> Void) async throws {
        try await open(stores: [V01StoreLocation(key: "main", url: url)], containerIdentifier: containerIdentifier, event: event)
    }

    static func descriptions(stores: [V01StoreLocation], containerIdentifier: String) -> [NSPersistentStoreDescription] {
        stores.map { location in
            let description = NSPersistentStoreDescription(url: location.url)
            description.shouldAddStoreAsynchronously = true
            let cloud = NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
            cloud.databaseScope = .private
            description.cloudKitContainerOptions = cloud
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            description.shouldMigrateStoreAutomatically = false
            description.shouldInferMappingModelAutomatically = false
            return description
        }
    }

    static func validateCloudDestinations(_ descriptions: [NSPersistentStoreDescription]) throws {
        var scopesByIdentifier: [String: Set<Int>] = [:]
        for description in descriptions {
            guard let cloud = description.cloudKitContainerOptions else { continue }
            let scope = cloud.databaseScope.rawValue
            guard scopesByIdentifier[cloud.containerIdentifier, default: []].insert(scope).inserted else {
                throw V01ConfigurationError.duplicateCloudDestination
            }
        }
    }

    func open(stores: [V01StoreLocation], containerIdentifier: String, event: @escaping (V01NativeEvent) -> Void) async throws {
        guard !stores.isEmpty, Set(stores.map(\.key)).count == stores.count,
              Set(stores.map { $0.url.standardizedFileURL }).count == stores.count else { throw V01Error.freshPathRequired }
        let descriptions = Self.descriptions(stores: stores, containerIdentifier: containerIdentifier)
        if localOnlyForTests { for description in descriptions { description.cloudKitContainerOptions = nil } }
        // Validate before constructing an owner, not just before loading its stores.
        try Self.validateCloudDestinations(descriptions)
        let owner: NSPersistentContainer
        if localOnlyForTests {
            owner = NSPersistentContainer(name: "V01Probe", managedObjectModel: Self.makeModel())
        } else {
            owner = try makeCloudOwner(Self.makeModel())
        }
        owner.persistentStoreDescriptions = descriptions
        storeURLs = Dictionary(uniqueKeysWithValues: stores.map { ($0.key, $0.url.standardizedFileURL) })
        loadResults = []
        container = owner
        observer = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                                         object: owner, queue: .main) { notification in
            guard let native = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let kind: String
            switch native.type {
            case .setup: kind = "setup"
            case .import: kind = "import"
            case .export: kind = "export"
            @unknown default: kind = "unknown"
            }
            let snapshot = V01NativeEvent(identifier: native.identifier, kind: kind, started: native.startDate,
                                         finished: native.endDate, succeeded: native.succeeded,
                                         storeIdentifier: native.storeIdentifier,
                                         error: native.error.map(v01ErrorCode))
            Task { @MainActor in event(snapshot) }
        }
        let tracker = V01StoreLoadTracker(keys: stores.map(\.key))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            owner.loadPersistentStores { description, error in
                // loadPersistentStores calls back once per description, potentially off main.
                Task { @MainActor in
                    guard let key = stores.first(where: { $0.url.standardizedFileURL == description.url?.standardizedFileURL })?.key else { return }
                    let loadedStore = owner.persistentStoreCoordinator.persistentStores.first { $0.url?.standardizedFileURL == description.url?.standardizedFileURL }
                    let complete = tracker.record(key: key, error: error, storeIdentifier: loadedStore?.identifier,
                                                  localFile: description.url?.lastPathComponent)
                    self.loadResults = tracker.results.values.sorted { $0.storeKey < $1.storeKey }
                    if complete {
                        if let error = tracker.firstError { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
        }
    }

    func insert(_ rows: [V01Row]) async throws { try await insert(rows, into: "main") }

    func insert(_ rows: [V01Row], into storeKey: String) async throws {
        guard let url = storeURLs[storeKey], let container else { throw V01Error.notOpen }
        let context = container.newBackgroundContext()
        try await context.perform {
            defer { context.reset() }
            guard let store = container.persistentStoreCoordinator.persistentStores.first(where: { $0.url?.standardizedFileURL == url }) else { throw V01Error.notOpen }
            for row in rows {
                let item = NSEntityDescription.insertNewObject(forEntityName: "V01ProbeItem", into: context)
                context.assign(item, to: store)
                item.setValue(row.runID, forKey: "runID")
                item.setValue(row.logicalGraphID, forKey: "logicalGraphID")
                item.setValue(row.itemID, forKey: "itemID")
                item.setValue(row.value, forKey: "value")
            }
            try context.save()
        }
    }

    func snapshot(runID: UUID) async throws -> V01Snapshot { try await snapshot(runID: runID, in: "main") }

    func snapshot(runID: UUID, in storeKey: String) async throws -> V01Snapshot {
        guard let url = storeURLs[storeKey], let container else { throw V01Error.notOpen }
        let context = container.newBackgroundContext()
        return try await context.perform {
            defer { context.reset() }
            let request = NSFetchRequest<NSManagedObject>(entityName: "V01ProbeItem")
            request.predicate = NSPredicate(format: "runID == %@", runID.uuidString)
            guard let store = container.persistentStoreCoordinator.persistentStores.first(where: { $0.url?.standardizedFileURL == url }) else { throw V01Error.notOpen }
            request.affectedStores = [store]
            let objects = try context.fetch(request)
            let rows = objects.map { item in
                V01Row(runID: item.value(forKey: "runID") as? String,
                       logicalGraphID: item.value(forKey: "logicalGraphID") as? String,
                       itemID: item.value(forKey: "itemID") as? String, value: item.value(forKey: "value") as? String)
            }.sorted { $0.sortKey < $1.sortKey }
            let mappings = objects.map { item in
                // Optional observational lookup only: no save/permanent-ID request/export trigger.
                let record = (container as? NSPersistentCloudKitContainer)?.recordID(for: item.objectID)
                return V01Mapping(itemID: item.value(forKey: "itemID") as? String,
                                  recordName: record?.recordName, zoneName: record?.zoneID.zoneName)
            }
            return V01Snapshot(rows: rows, mappings: mappings,
                               storeIdentifier: store.identifier)
        }
    }

    func close() async throws {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let container else { return }
        let context = container.newBackgroundContext()
        try await context.perform {
            context.reset()
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
        self.container = nil
        // Store detachment is not a mirroring shutdown acknowledgement. Restart is still required.
    }
}

enum V01Error: LocalizedError {
    case notOpen, restartRequired, freshPathRequired, missingConfiguration, accountUnavailable
    var errorDescription: String? {
        switch self {
        case .notOpen: return "The V01 store is not open."
        case .restartRequired: return "One stage per process. Restart directly into the laboratory for the next stage."
        case .freshPathRequired: return "The stage requires a new local SQLite path."
        case .missingConfiguration: return "A verified Development configuration and a physical device are required."
        case .accountUnavailable: return "The configured CloudKit account is unavailable."
        }
    }
}
