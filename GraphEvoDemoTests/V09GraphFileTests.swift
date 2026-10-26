import CoreData
import XCTest
@testable import GraphEvoDemo

final class V09GraphFileTests: XCTestCase {
    func testGraphRelationshipsAndBinarySurviveSQLiteReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("V09-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")

        func open() throws -> NSPersistentContainer {
            let container = NSPersistentContainer(name: "V09LocalTest", managedObjectModel: V09Model.make())
            let description = NSPersistentStoreDescription(url: url)
            description.shouldMigrateStoreAutomatically = false
            description.shouldInferMappingModelAutomatically = false
            container.persistentStoreDescriptions = [description]
            var failure: Error?
            container.loadPersistentStores { _, error in failure = error }
            if let failure { throw failure }
            return container
        }

        var container = try open()
        let context = container.viewContext
        func insert(_ id: String, _ kind: String) -> NSManagedObject {
            let object = NSEntityDescription.insertNewObject(forEntityName: "V09Member", into: context)
            object.setValue("A", forKey: "graph")
            object.setValue(id, forKey: "memberID")
            object.setValue(kind, forKey: "kind")
            return object
        }
        let root = insert("A-root", "root")
        let first = insert("A-entity-1", "entity")
        let second = insert("A-entity-2", "entity")
        let edge = insert("A-relationship", "relationship")
        let action = insert("A-action", "action")
        let file = insert("A-file", "attachment")
        for object in [first, second, edge, action, file] { object.setValue(root, forKey: "parent") }
        edge.setValue(first, forKey: "source")
        edge.setValue(second, forKey: "target")
        action.setValue(NSSet(array: [first, second]), forKey: "subjects")
        action.setValue(NSSet(array: [second]), forKey: "objects")
        file.setValue(first, forKey: "fileOwner")
        let bytes = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })
        file.setValue(bytes, forKey: "bytes")
        file.setValue(V09GraphFileStore.digest(bytes), forKey: "checksum")
        try context.save()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        container = try open()
        let request = NSFetchRequest<NSManagedObject>(entityName: "V09Member")
        let rows = try container.viewContext.fetch(request)
        XCTAssertEqual(rows.count, 6)
        let byID = Dictionary(uniqueKeysWithValues: rows.compactMap { object -> (String, NSManagedObject)? in
            guard let id = object.value(forKey: "memberID") as? String else { return nil }
            return (id, object)
        })
        XCTAssertEqual((byID["A-relationship"]?.value(forKey: "source") as? NSManagedObject)?
            .value(forKey: "memberID") as? String, "A-entity-1")
        XCTAssertEqual((byID["A-action"]?.value(forKey: "subjects") as? Set<NSManagedObject>)?.count, 2)
        XCTAssertEqual((byID["A-file"]?.value(forKey: "bytes") as? Data), bytes)
        XCTAssertEqual((byID["A-root"]?.value(forKey: "children") as? Set<NSManagedObject>)?.count, 5)
    }

    func testFixtureRejectsMissingCloudIdentity() {
        let row = V09Row(scope: .privateStore, graph: "A", id: "A-root", kind: "root", label: "A",
                         parent: nil, source: nil, target: nil, subjects: [], objects: [],
                         fileOwner: nil, filename: nil, contentType: nil, byteCount: nil,
                         checksum: nil, checksumMatches: nil, record: nil, share: nil)
        XCTAssertFalse(V09Fixture.exact([row], owner: true, phase: .prepared))
    }

    func testCoordinatedEditRequiresExplicitStartTime() {
        let common = ["app", "--v09-role", "owner-concurrent", "--v09-run-id",
                      UUID().uuidString, "--v09-development-verified"]
        XCTAssertNil(V09Request.parse(common))
        XCTAssertNotNil(V09Request.parse(common + ["--v09-start-unix", "1800000000"]))
    }
}
