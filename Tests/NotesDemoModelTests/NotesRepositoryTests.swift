import Foundation
import Testing
import GraphEvo
@testable import NotesDemoModel

@Suite struct NotesRepositoryTests {
    @Test func headersDoNotReturnBodiesAndDateSurvivesPatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Notes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = GraphContext.localFiles(), graph = try await context.createGraph(id: GraphID(), at: root.appendingPathComponent("Graph.sqlite"))
        let repository = NotesRepository(store: graph)
        let note = Note(title: "First", content: String(repeating: "body", count: 1024))
        try await graph.insert(note)
        let page = try await repository.headers()
        #expect(page.rows.count == 1 && page.rows[0].title == note.title)
        #expect(try await repository.note(page.rows[0].id) == note)
        try await graph.close()
    }
    @Test func headerPagesExcludeFilesAndDoNotDuplicateAcrossTheCursor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesPages-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = GraphContext.localFiles(), store = try await context.createGraph(id: GraphID(), at: root.appendingPathComponent("Graph.sqlite"))
        let notes = (0..<51).map { Note(title: String($0), content: "Body", date: Date(timeIntervalSince1970: Double($0))) }
        try await store.transaction { scope in for note in notes { try scope.insert(note) } }
        let input = root.appendingPathComponent("File.txt"); try Data([1]).write(to: input)
        _ = try await store.importFile(from: input)
        let repository = NotesRepository(store: store)
        let first = try await repository.headers(), cursor = try #require(first.next)
        let second = try await repository.headers(after: cursor)
        #expect(first.rows.count == 50 && second.rows.count == 1 && second.next == nil)
        #expect(first.rows.first?.title == "50" && second.rows.first?.title == "0")
        #expect(Set((first.rows + second.rows).map(\.id)).count == 51)
        try await store.close()
    }

}

@MainActor @Suite(.timeLimit(.minutes(1))) struct NotesApplicationTests {
    @Test func scenesShareOneStoreAndLocalDeletionLeavesTheOtherNotebook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesApp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try NotesApplicationModel(root: root)
        let first = try await app.createNotebook(name: "First", mode: .local)
        let second = try await app.createNotebook(name: "Second", mode: .local)
        let same = try await app.openNotebook(first.entryID)
        #expect(same === first)
        try await app.setSceneActive("A", active: true); try await app.setSceneActive("B", active: true)
        try await app.setSceneActive("A", active: false)
        let note = try await second.repository.createNote()
        try await app.deleteNotebook(first.entryID)
        #expect(app.notebooks.count == 1 && app.notebooks[0].id == second.entryID)
        #expect(try await second.repository.note(note) != nil)
        try await second.close(); try await app.setSceneActive("B", active: false)
    }
    @Test func fileImportLinksAtomicallyAndNoteDeletionIncludesFileAndCover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesFiles-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = GraphContext.localFiles(), store = try await context.createGraph(id: GraphID(), at: root.appendingPathComponent("Graph.sqlite"))
        let repository = NotesRepository(store: store), note = try await repository.createNote()
        let input = root.appendingPathComponent("Document.txt"), bytes = Data("Document".utf8)
        try bytes.write(to: input)
        let file = try await repository.importDocument(input, note: note, contentType: "public.text")
        try await repository.setCover(Data([9, 8, 7]), note: note)
        #expect(try await repository.files(note: note) == [file])
        #expect(try await store.withFileURL(file.id) { try Data(contentsOf: $0) } == bytes)
        let presentations = try NotesPresentationCache(root: root.appendingPathComponent("Previews"))
        let preview = try await presentations.prepare(file, in: store)
        #expect(try Data(contentsOf: preview) == bytes)
        try presentations.release(preview)
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        #expect(try await store.withFileURL(file.id) { try Data(contentsOf: $0) } == bytes)
        try await repository.deleteNote(note)
        #expect(try await store.file(file.id) == nil)
        #expect(try await repository.note(note) == nil)
        await #expect(throws: (any Error).self) { try await repository.importDocument(input, note: note, contentType: "public.text") }
        #expect(try await store.files().isEmpty)
        try await store.close()
    }
    @Test func openingCannotOverwriteRemovalRequestedByAnotherScene() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesOpening-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try NotesApplicationModel(root: root)
        let created = AsyncStream<UUID>.makeStream()
        let token = app.observe {
            if let entry = app.notebooks.first(where: { $0.creating }) { created.continuation.yield(entry.id) }
        }
        let opening = Task { try await app.createNotebook(name: "Racing removal", mode: .local) }
        var iterator = created.stream.makeAsyncIterator()
        let id = try #require(await iterator.next())
        app.removeObserver(token); created.continuation.finish()
        try await app.deleteNotebook(id)
        let result = await opening.result
        if case .success(let session) = result { #expect(session.closed) }
        #expect(app.notebooks.isEmpty)
        let directory = root.appendingPathComponent("Notebooks").appendingPathComponent(id.uuidString)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Graph.sqlite").path))
    }

    @Test func sceneDraftsRemainIndependentWhenAnotherSceneSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesScenes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try NotesApplicationModel(root: root)
        let session = try await app.createNotebook(name: "Scenes", mode: .local)
        let entry = try #require(app.notebooks.first)
        let id = try await session.repository.createNote(), note = try #require(try await session.repository.note(id))
        let firstURL = app.catalog.draftURL(for: entry, note: id, sceneID: "Scene/A")
        let secondURL = app.catalog.draftURL(for: entry, note: id, sceneID: "Scene/B")
        #expect(firstURL != secondURL)
        #expect(firstURL == app.catalog.draftURL(for: entry, note: id, sceneID: "Scene/A"))
        let first = try NoteEditor(note: note, repository: session.repository, draftURL: firstURL, delay: .seconds(60))
        let second = try NoteEditor(note: note, repository: session.repository, draftURL: secondURL, delay: .seconds(60))
        first.edit(.title, value: "First scene")
        second.edit(.title, value: "Second scene")
        await first.saveNow()
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        await second.saveNow()
        #expect(second.state == .conflict)
        try await session.repository.deleteNote(id)
        try first.acknowledgeDeletion()
        await second.reload()
        #expect(second.state == .deleted)
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        first.retire(); second.retire(); try await session.close()
    }

    @Test func catalogueUsesRelativeRoutingAndRetainsInvitationsBeforeOpeningAnyStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesCatalog-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try NotesApplicationModel(root: root)
        try app.retainInvitation(url: URL(string: "https://www.icloud.com/share/fixture")!, container: "iCloud.fixture")
        let reopened = try NotesApplicationModel(root: root)
        #expect(reopened.catalog.invitations.count == 1 && reopened.notebooks.isEmpty)
        #expect(reopened.suggestedContainer == "iCloud.fixture")
        let bytes = try Data(contentsOf: root.appendingPathComponent("catalog.json"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains(root.path))
    }
}
