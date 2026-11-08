import Foundation
import GraphEvo

nonisolated enum NotesError: Error { case invalidRecord, missingNote, conflictingEdit, ambiguousFileOwner, tooManyFiles, busy, cloudNotReady, pendingDeletion }

nonisolated struct NotebookInfo: GraphModel, Sendable {
    let id: UUID
    let name: String
    static let graphType = "GraphEvoDemo.Notes.Notebook.v1"
    static let graphKind = GraphNodeKind.entity
    init(name: String) { id = UUID(); self.name = name }
    init(graphRecord: GraphRecord) throws { id = graphRecord.id.rawValue; name = try graphRecord.value(for: "name") }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord {
        try GraphRecord(id: graphNodeID(in: graphID), type: Self.graphType, properties: ["name": .string(name)])
    }
}

nonisolated struct Note: GraphModel, Sendable, Equatable {
    let id: UUID
    let title: String
    let content: String
    let date: Date
    static let graphType = "GraphEvoDemo.Notes.Note.v1"
    static let graphKind = GraphNodeKind.entity
    init(id: UUID = UUID(), title: String = "", content: String = "", date: Date = Date()) {
        self.id = id; self.title = title; self.content = content; self.date = date
    }
    init(graphRecord: GraphRecord) throws {
        id = graphRecord.id.rawValue
        title = try graphRecord.value(for: "title"); content = try graphRecord.value(for: "content"); date = try graphRecord.value(for: "date")
    }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord {
        try GraphRecord(id: graphNodeID(in: graphID), type: Self.graphType,
            properties: ["title": .string(title), "content": .string(content), "date": .date(date)])
    }
}

nonisolated struct NoteHeader: Sendable, Identifiable {
    let id: GraphNodeID
    let title: String
    let date: Date
    init(_ row: GraphQueryProjection) throws {
        guard case .string(let title) = row.values["title"], case .date(let date) = row.values["date"] else { throw NotesError.invalidRecord }
        self.id = row.id; self.title = title; self.date = date
    }
    var displayTitle: String { title.isEmpty ? "Untitled note" : title }
}

nonisolated struct NoteFileLink: GraphModel, Sendable {
    let id: UUID
    let note: GraphNodeID
    let file: GraphNodeID
    static let graphType = "GraphEvoDemo.Notes.NoteFile.v1"
    static let graphKind = GraphNodeKind.relationship
    init(id: UUID = UUID(), note: GraphNodeID, file: GraphNodeID) { self.id = id; self.note = note; self.file = file }
    init(graphRecord: GraphRecord) throws {
        guard case .relationship(let subject, let object) = graphRecord.endpoints, let subject, let object else { throw NotesError.invalidRecord }
        id = graphRecord.id.rawValue; note = subject; file = object
    }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord {
        try GraphRecord(id: graphNodeID(in: graphID), type: Self.graphType, endpoints: .relationship(subject: note, object: file))
    }
}

nonisolated struct NotesRepository: Sendable {
    let store: GraphStore
    static func budget() throws -> GraphQueryBudget { try GraphQueryBudget(maximumCandidates: 10_000) }
    static func noteQuery() throws -> GraphQuery<Note> {
        GraphQuery<Note>(budget: try budget()).sorted(by: [GraphQuerySort(.property("date"), direction: .descending)]).limit(50)
    }
    func headers(after cursor: GraphQueryCursor? = nil) async throws -> (rows: [NoteHeader], next: GraphQueryCursor?) {
        var query = try Self.noteQuery()
        if let cursor { query = query.after(cursor) }
        let result = try await store.project(query, properties: ["title", "date"])
        return (try result.rows.map(NoteHeader.init), result.nextCursor)
    }
    func notebookName() async throws -> String {
        let result = try await store.query(GraphQuery<NotebookInfo>(budget: Self.budget()).limit(2))
        guard result.items.count == 1 else { throw NotesError.invalidRecord }
        return result.items[0].name
    }
    func note(_ id: GraphNodeID) async throws -> Note? { try await store.read { try $0.fetch(id, as: Note.self) } }
    func createNote() async throws -> GraphNodeID { try await store.insert(Note()) }
    func cover(_ id: GraphNodeID) async throws -> Data? {
        let values = try await store.attachments(ownedBy: id)
        guard let metadata = values.first(where: { $0.propertyKey == "cover" }) else { return nil }
        return try await store.attachment(metadata.id)?.data
    }
    func setCover(_ data: Data?, note id: GraphNodeID) async throws {
        let change: GraphAttachmentChange = data.map { .set(GraphAttachmentValue(data: $0)) } ?? .remove
        try await store.transaction { scope in
            guard try scope.fetch(id, as: Note.self) != nil else { throw NotesError.missingNote }
            _ = try scope.patch(GraphRecordPatch(id: id, attachments: ["cover": change]))
        }
    }
    func importDocument(_ url: URL, note: GraphNodeID, contentType: String) async throws -> GraphFile {
        let edge = store.makeNodeID()
        return try await store.importFile(from: url, contentType: contentType) { scope, file in
            guard try scope.fetch(note, as: Note.self) != nil else { throw NotesError.missingNote }
            try scope.insert(GraphRecord(id: edge, type: NoteFileLink.graphType, endpoints: .relationship(subject: note, object: file.id)))
        }
    }
    static func links(in scope: GraphReadScope, note: GraphNodeID) throws -> [NoteFileLink] {
        let result = try scope.query(GraphQuery<NoteFileLink>(budget: budget()).where(.subject(note)).limit(10_000))
        guard result.nextCursor == nil, result.items.count <= 10_000 else { throw NotesError.tooManyFiles }
        return result.items
    }
    func files(note: GraphNodeID) async throws -> [GraphFile] {
        try await store.read { scope in
            try Self.links(in: scope, note: note).map { edge in
                guard let file = try scope.file(edge.file) else { throw NotesError.invalidRecord }
                return file
            }
        }
    }
    static func requireExclusiveFile(_ file: GraphNodeID, note: GraphNodeID, in scope: GraphReadScope) throws {
        let result = try scope.query(GraphQuery<NoteFileLink>(budget: budget()).where(.object(file)).limit(2))
        guard result.items.count == 1, result.items[0].note == note, result.nextCursor == nil else { throw NotesError.ambiguousFileOwner }
    }
    func deleteNote(_ id: GraphNodeID) async throws {
        try await store.transaction { scope in
            guard try scope.fetch(id, as: Note.self) != nil else { throw NotesError.missingNote }
            let links = try Self.links(in: scope, note: id)
            for edge in links { try Self.requireExclusiveFile(edge.file, note: id, in: scope) }
            for edge in links { try scope.delete(edge.file) }
            // Node deletion includes incident links and keyed attachments.
            try scope.delete(id)
        }
    }
    func deleteFile(_ file: GraphNodeID, note: GraphNodeID) async throws {
        try await store.transaction { scope in
            try Self.requireExclusiveFile(file, note: note, in: scope)
            try scope.delete(file)
        }
    }
}
