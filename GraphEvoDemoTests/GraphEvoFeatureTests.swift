import XCTest
import GraphEvo

final class GraphEvoFeatureTests: XCTestCase {

    func testDomainModelSupportsTagsGroupsRelationshipsAndActions() throws {
        let graph = try makeInMemoryGraph()
        let author = Entity("User", graph: graph)
        let note = Entity("Note", graph: graph)

        author.add(tags: "active")
        author.add(to: "authors")
        author.is(relationship: "writes").of(note)
        author.will(action: "reviews").add(objects: note)
        graph.sync()

        XCTAssertTrue(author.has(tags: "active"))
        XCTAssertTrue(author.member(of: "authors"))
        XCTAssertEqual(author.relationship(types: "writes").count, 1)
        XCTAssertEqual(author.action(types: "reviews").count, 1)
        XCTAssertEqual(Search<Entity>(graph: graph).where(.type("Note")).sync().count, 1)
    }

    func testCompoundPredicatesFilterTheDemoDataModel() throws {
        let graph = try makeInMemoryGraph()
        let favorite = Entity("Note", graph: graph)
        favorite[dynamicMember: "title"] = "Favorite"
        favorite.add(tags: "favorite")

        let ordinary = Entity("Note", graph: graph)
        ordinary[dynamicMember: "title"] = "Ordinary"
        graph.sync()

        let predicate = .type("Note") && .has(tags: "favorite")
        let results = Search<Entity>(graph: graph).where(predicate).sync()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?[dynamicMember: "title"] as? String, "Favorite")
        XCTAssertFalse(ordinary.has(tags: "favorite"))
    }

    func testAsyncSearchReturnsPersistedEntities() throws {
        let graph = try makeInMemoryGraph()
        let note = Entity("Note", graph: graph)
        note[dynamicMember: "title"] = "Async note"
        graph.sync()

        let expectation = expectation(description: "Async search completes")
        Search<Entity>(graph: graph)
            .where(.type("Note"))
            .async { results in
                XCTAssertEqual(results.count, 1)
                XCTAssertEqual(results.first?[dynamicMember: "title"] as? String, "Async note")
                expectation.fulfill()
            }

        wait(for: [expectation], timeout: 2)
    }

    func testWatcherReceivesLocalEntityChangesAfterResume() throws {
        let graph = try makeInMemoryGraph()
        let delegate = EntityChangeDelegate()
        let watcher = Watch<Entity>(graph: graph).where(.type("Note"))
        watcher.delegate = delegate
        watcher.resume()

        let expectation = expectation(description: "Watcher receives insertion")
        delegate.onInsert = { entity in
            XCTAssertEqual(entity.type, "Note")
            expectation.fulfill()
        }

        let note = Entity("Note", graph: graph)
        note[dynamicMember: "title"] = "Watched note"
        graph.sync()

        wait(for: [expectation], timeout: 2)
        watcher.pause()
    }

    private func makeInMemoryGraph() throws -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.name = "GraphEvoDemoTests-\(UUID().uuidString)"
        configuration.backend = .inMemory

        let graph = Graph(configuration: configuration)
        let expectation = expectation(description: "Graph becomes ready")
        var openingResult: Result<Graph, GraphStoreOpeningError>?
        graph.whenReady { result in
            openingResult = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        guard case .success(let readyGraph) = openingResult else {
            throw TestError.graphDidNotOpen
        }
        return readyGraph
    }
}

private final class EntityChangeDelegate: GraphEntityDelegate {
    var onInsert: ((Entity) -> Void)?

    func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) {
        onInsert?(entity)
    }
}

private enum TestError: Error {
    case graphDidNotOpen
}
