import Foundation
import Testing
import GraphEvo
@testable import NotesDemoModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct NoteEditorTests {
    struct Fixture {
        let root: URL
        let context: GraphContext
        let store: GraphStore
        let repository: NotesRepository
        let note: Note
        var draft: URL { root.appendingPathComponent("draft.json") }
    }
    func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteEditor-" + UUID().uuidString)
        let context = GraphContext.localFiles(), store = try await context.createGraph(id: GraphID(), at: root.appendingPathComponent("Graph.sqlite"))
        let note = Note(title: "Title", content: "Body")
        try await store.insert(note)
        return Fixture(root: root, context: context, store: store, repository: NotesRepository(store: store), note: note)
    }
    @Test func autosavePatchesOnlyDirtyFieldsAndPreservesDateAndCover() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = f.note.graphNodeID(in: f.store.id)
        try await f.repository.setCover(Data([1, 2, 3]), note: id)
        let editor = try NoteEditor(note: f.note, repository: f.repository, draftURL: f.draft, delay: .milliseconds(15))
        let changes = AsyncStream<NoteEditor.State>.makeStream()
        editor.onChange = { [weak editor] in if let editor { changes.continuation.yield(editor.state) } }
        editor.edit(.title, value: "Changed")
        #expect(editor.state == .pending)
        for await state in changes.stream {
            if state == .saved { break }
            if case .failed = state { Issue.record("Autosave failed"); break }
        }
        editor.onChange = nil; changes.continuation.finish()
        let note = try #require(try await f.repository.note(id))
        #expect(note.title == "Changed" && note.content == "Body" && note.date == f.note.date)
        #expect(try await f.repository.cover(id) == Data([1, 2, 3]))
        #expect(editor.state == .saved && !FileManager.default.fileExists(atPath: f.draft.path))
        try await f.store.close()
    }
    @Test func currentTransactionDetectsConflictEvenWithoutObservationAndRequiresExplicitChoice() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = f.note.graphNodeID(in: f.store.id)
        let editor = try NoteEditor(note: f.note, repository: f.repository, draftURL: f.draft, delay: .seconds(60))
        editor.edit(.title, value: "Mine")
        _ = try await f.store.patch(GraphRecordPatch(id: id, properties: ["title": .set(.string("Theirs"))]), as: Note.self)
        await editor.saveNow()
        #expect(editor.state == .conflict && editor.conflicts == [.title])
        #expect(try await f.repository.note(id)?.title == "Theirs")
        editor.resolve(.title, keepingMine: true)
        await editor.saveNow()
        #expect(try await f.repository.note(id)?.title == "Mine")
        #expect(editor.state == .saved)
        try await f.store.close()
    }
    @Test func unrelatedFieldEditsMergeAndRemoteDeletionCannotBeReinserted() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = f.note.graphNodeID(in: f.store.id)
        let editor = try NoteEditor(note: f.note, repository: f.repository, draftURL: f.draft, delay: .seconds(60))
        editor.edit(.title, value: "Mine")
        _ = try await f.store.patch(GraphRecordPatch(id: id, properties: ["content": .set(.string("Remote body"))]), as: Note.self)
        await editor.saveNow()
        #expect(try await f.repository.note(id)?.content == "Remote body")
        editor.edit(.content, value: "Unsaved draft")
        try await f.repository.deleteNote(id)
        await editor.saveNow()
        #expect(editor.state == .deleted)
        editor.setWritable(false); editor.setWritable(true); editor.edit(.content, value: "Must not return")
        await editor.saveNow()
        #expect(editor.state == .deleted)
        #expect(try await f.repository.note(id) == nil)
        #expect(FileManager.default.fileExists(atPath: f.draft.path))
        try await f.store.close()
    }
    @Test func retainedDraftNeedsReviewAndCannotWriteWhileSuspended() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = f.note.graphNodeID(in: f.store.id)
        var editor: NoteEditor? = try NoteEditor(note: f.note, repository: f.repository, draftURL: f.draft, delay: .seconds(60))
        editor?.edit(.content, value: "Retained"); editor = nil
        let restored = try NoteEditor(note: f.note, repository: f.repository, draftURL: f.draft, delay: .seconds(60))
        #expect(restored.state == .draftNeedsReview && restored.content == "Retained")
        await restored.saveNow()
        #expect(try await f.repository.note(id)?.content == "Body")
        restored.setWritable(false); restored.resumeDraft(); await restored.saveNow()
        #expect(try await f.repository.note(id)?.content == "Body")
        restored.setWritable(true); restored.resumeDraft(); await restored.saveNow()
        #expect(try await f.repository.note(id)?.content == "Retained")
        try await f.store.close()
    }
    @Test func readOnlyEditorRereadsRemoteTextWithoutAllowingEdits() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = f.note.graphNodeID(in: f.store.id)
        let editor = try NoteEditor(note: f.note, repository: f.repository, draftURL: f.draft)
        editor.setWritable(false)
        _ = try await f.store.patch(GraphRecordPatch(id: id, properties: ["title": .set(.string("Remote title"))]), as: Note.self)
        await editor.reload()
        #expect(editor.title == "Remote title" && !editor.canEdit)
        editor.edit(.title, value: "Refused")
        #expect(editor.title == "Remote title")
        try await f.store.close()
    }

}
