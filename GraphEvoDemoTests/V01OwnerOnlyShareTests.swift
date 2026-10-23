import XCTest
import CoreData
import CloudKit
@testable import GraphEvoDemo

@MainActor
final class V01OwnerOnlyShareTests: XCTestCase {
    func testModelPreservesProbeAndUsesOptionalInverseRelationships() throws {
        let model = V01OwnerOnlyShareTrial.model()
        let original = V01CloudStore.makeModel()
        for entity in original.entities {
            XCTAssertEqual(model.entitiesByName[try XCTUnwrap(entity.name)]?.versionHash, entity.versionHash)
        }
        let member = try XCTUnwrap(model.entitiesByName["V01T6Member"])
        XCTAssertTrue(member.properties.allSatisfy(\.isOptional))
        XCTAssertTrue(member.uniquenessConstraints.isEmpty)
        let parent = try XCTUnwrap(member.relationshipsByName["parent"])
        let children = try XCTUnwrap(member.relationshipsByName["children"])
        XCTAssertTrue(parent.inverseRelationship === children)
        XCTAssertTrue(children.inverseRelationship === parent)
        XCTAssertEqual(parent.maxCount, 1)
        XCTAssertTrue(children.isToMany)
        XCTAssertFalse(children.isOrdered)
    }

    func testRealSQLiteFixtureHasTwoDisconnectedRootsAndThreeInverseChildren() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: V01OwnerOnlyShareTrial.model())
        let store = try coordinator.addPersistentStore(type: .sqlite, at: directory.appendingPathComponent("fixture.sqlite"))
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let run = UUID()
        try V01OwnerOnlyShareTrial.insertFixture(runID: run, context: context)
        context.reset()
        let request = NSFetchRequest<NSManagedObject>(entityName: "V01T6Member")
        request.predicate = NSPredicate(format: "runID == %@", run.uuidString)
        let objects = try context.fetch(request)
        XCTAssertEqual(objects.count, 5)
        XCTAssertEqual(objects.filter { $0.value(forKey: "kind") as? String == "root" }.count, 2)
        XCTAssertEqual(objects.filter { $0.value(forKey: "kind") as? String == "item" }.count, 3)
        for object in objects {
            let graph = try XCTUnwrap(object.value(forKey: "graph") as? String)
            let children = object.value(forKey: "children") as? Set<NSManagedObject> ?? []
            if object.value(forKey: "kind") as? String == "root" {
                XCTAssertNil(object.value(forKey: "parent"))
                XCTAssertEqual(children.count, graph == "A" ? 2 : 1)
                for child in children {
                    XCTAssertEqual(child.value(forKey: "graph") as? String, graph)
                    XCTAssertTrue(child.value(forKey: "parent") as? NSManagedObject === object)
                }
            } else {
                let parent = try XCTUnwrap(object.value(forKey: "parent") as? NSManagedObject)
                XCTAssertEqual(parent.value(forKey: "node") as? String, graph + "-root")
                XCTAssertEqual(parent.value(forKey: "runID") as? String, run.uuidString)
                XCTAssertTrue(children.isEmpty)
            }
        }
        request.predicate = NSPredicate(format: "runID == %@", UUID().uuidString)
        XCTAssertTrue(try context.fetch(request).isEmpty)
    }

    func testParserRequiresT6RoleRunConfirmationAndBoundedWindow() {
        let run = UUID()
        for role in ["t6-writer", "t6-reader"] {
            let args = ["--v01-role", role, "--v01-run-id", run.uuidString]
            XCTAssertNil(V01OwnerOnlyShareTrial.parse(args))
            let valid = args + ["--v01-development-verified"]
            XCTAssertEqual(V01OwnerOnlyShareTrial.parse(valid)?.role, role)
            XCTAssertEqual(V01OwnerOnlyShareTrial.parse(valid)?.runID, run)
            XCTAssertEqual(V01OwnerOnlyShareTrial.parse(valid)?.window, 120)
            for window in ["0", "601", "invalid"] {
                XCTAssertNil(V01OwnerOnlyShareTrial.parse(valid + ["--v01-window", window]))
            }
            XCTAssertNotNil(V01OwnerOnlyShareTrial.parse(valid + ["--v01-window", "1"]))
            XCTAssertNotNil(V01OwnerOnlyShareTrial.parse(valid + ["--v01-window", "600"]))
            XCTAssertNil(V01LaunchRequest.parse(valid))
        }
        XCTAssertNil(V01OwnerOnlyShareTrial.parse(["--v01-development-verified", "--v01-role", "reader", "--v01-run-id", run.uuidString]))
        XCTAssertNil(V01OwnerOnlyShareTrial.parse(["--v01-development-verified", "--v01-role", "t6-reader", "--v01-run-id", "invalid"]))
    }

    func testExactFixtureChecksFullMultisetValuesAndClosure() throws {
        let members = try fixture()
        XCTAssertTrue(V01OwnerOnlyShareTrial.exactFixture(members.reversed()))
        XCTAssertFalse(V01OwnerOnlyShareTrial.exactFixture(Array(members.dropLast())))
        XCTAssertFalse(V01OwnerOnlyShareTrial.exactFixture(members + [members[0]]))
        XCTAssertFalse(V01OwnerOnlyShareTrial.exactFixture([members[0]] + members.dropLast()))
        for (key, value) in [("value", "wrong"), ("parent", "B-root"), ("graph", "B")] {
            var altered = members
            altered[1] = try replacing(altered[1], key: key, value: value)
            XCTAssertFalse(V01OwnerOnlyShareTrial.exactFixture(altered), key)
        }
        var altered = members
        altered[0] = try replacing(altered[0], key: "children", value: ["A-001", "B-001"])
        XCTAssertFalse(V01OwnerOnlyShareTrial.exactFixture(altered))
    }

    func testDistinctZonesMayUseTheSameShareRecordName() throws {
        XCTAssertTrue(V01OwnerOnlyShareTrial.separatedOwnerOnlyShares(try fixture(sameShareName: true)))
    }

    func testShareValidationRejectsMissingMappingsMixedMembershipAndPublicParticipants() throws {
        let members = try fixture()
        XCTAssertTrue(V01OwnerOnlyShareTrial.separatedOwnerOnlyShares(members))
        for (key, value) in [("share", NSNull() as Any), ("recordName", NSNull() as Any), ("zoneName", "wrong-zone" as Any)] {
            var altered = members
            altered[1] = try replacing(altered[1], key: key, value: value)
            XCTAssertFalse(V01OwnerOnlyShareTrial.separatedOwnerOnlyShares(altered), key)
        }
        for (key, value) in [("ownerCount", 0), ("nonOwnerCount", 1), ("publicPermission", CKShare.ParticipantPermission.readOnly.rawValue)] {
            var altered = members
            for index in altered.indices {
                var json = try dictionary(altered[index])
                var share = try XCTUnwrap(json["share"] as? [String: Any])
                share[key] = value
                json["share"] = share
                altered[index] = try decode(json)
            }
            XCTAssertFalse(V01OwnerOnlyShareTrial.separatedOwnerOnlyShares(altered), key)
        }
        var unified = members
        for index in unified.indices {
            var json = try dictionary(unified[index])
            json["share"] = try dictionary(members[0])["share"]
            json["zoneName"] = "zone-A"
            unified[index] = try decode(json)
        }
        XCTAssertFalse(V01OwnerOnlyShareTrial.separatedOwnerOnlyShares(unified))
        var mixed = members
        var child = try dictionary(mixed[4])
        child["share"] = try dictionary(members[0])["share"]
        child["zoneName"] = "zone-A"
        mixed[4] = try decode(child)
        XCTAssertFalse(V01OwnerOnlyShareTrial.separatedOwnerOnlyShares(mixed))
    }

    private func fixture(sameShareName: Bool = false) throws -> [T6Member] {
        let values: [(String, String, String, String, String?, [String])] = [
            ("A", "A-root", "root", "A", nil, ["A-001", "A-002"]),
            ("A", "A-001", "item", "alpha", "A-root", []),
            ("A", "A-002", "item", "beta", "A-root", []),
            ("B", "B-root", "root", "B", nil, ["B-001"]),
            ("B", "B-001", "item", "gamma", "B-root", [])]
        return try values.map { graph, node, kind, value, parent, children in
            let share: [String: Any] = ["recordName": sameShareName ? "zone-share" : "share-" + graph,
                "zoneName": "zone-" + graph, "ownerCount": 1, "nonOwnerCount": 0,
                "publicPermission": CKShare.ParticipantPermission.none.rawValue]
            var json: [String: Any] = ["graph": graph, "node": node, "kind": kind, "value": value,
                "children": children, "recordName": "record-" + node, "zoneName": "zone-" + graph, "share": share]
            json["parent"] = parent
            return try decode(json)
        }
    }
    private func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func decode(_ value: [String: Any]) throws -> T6Member {
        try JSONDecoder().decode(T6Member.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func replacing(_ member: T6Member, key: String, value: Any) throws -> T6Member {
        var json = try dictionary(member)
        json[key] = value
        return try decode(json)
    }
}
