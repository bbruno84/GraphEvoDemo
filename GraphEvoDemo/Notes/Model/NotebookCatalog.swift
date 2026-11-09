import Foundation
import CryptoKit
import GraphEvo

nonisolated enum NotebookMode: String, Codable, Sendable { case local, iCloud, shared }
nonisolated struct NotebookEntry: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let graphID: GraphID
    let mode: NotebookMode
    let zoneName: String?
    let joinID: UUID?
    let cloud: NotesCloudPreferences?
    var creating: Bool
    var recovering: Bool
    var deleting: Bool = false
    var leaving: Bool = false
    var localName: String?
    init(id: UUID = UUID(), graphID: GraphID = GraphID(), mode: NotebookMode, zoneName: String? = nil,
         joinID: UUID? = nil, cloud: NotesCloudPreferences? = nil, creating: Bool = false, recovering: Bool = false, localName: String? = nil) {
        self.id = id; self.graphID = graphID; self.mode = mode; self.zoneName = zoneName; self.joinID = joinID; self.cloud = cloud
        self.creating = creating; self.recovering = recovering; self.localName = localName
    }
    var placeholderName: String { mode == .local ? (localName ?? "Notebook") : (mode == .shared ? "Shared notebook" : "iCloud notebook") }
}
nonisolated struct NotesCloudPreferences: Codable, Equatable, Sendable {
    let container: String
    let environment: GraphCloudEnvironment
}
nonisolated struct NotesInvitation: Codable, Sendable, Equatable {
    let url: URL
    let container: String
}

/// The catalogue stores routing, not canonical notebook/note content or sandbox paths.
@MainActor final class NotebookCatalog {
    private struct Document: Codable {
        var format = 1
        var entries: [NotebookEntry] = []
        var invitations: [NotesInvitation] = []
    }
    let root: URL
    private var document: Document
    private(set) var preferences: NotesCloudPreferences?
    var entries: [NotebookEntry] { document.entries }
    var invitations: [NotesInvitation] { document.invitations }
    private var url: URL { root.appendingPathComponent("catalog.json") }
    init(root: URL) throws {
        self.root = root; document = Document()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 1024 * 1024 else { throw NotesError.invalidRecord }
            document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.format == 1, document.entries.count <= 1000, document.invitations.count <= 16,
                  Set(document.entries.map(\.id)).count == document.entries.count,
                  Set(document.entries.map(\.graphID)).count == document.entries.count,
                  document.entries.allSatisfy({ entry in
                      switch entry.mode {
                      case .local: entry.zoneName == nil && entry.joinID == nil && entry.cloud == nil
                      case .iCloud: entry.zoneName?.hasPrefix("GraphEvoDemoNotes-") == true && entry.joinID == nil && entry.cloud != nil
                      case .shared: entry.joinID != nil && entry.cloud != nil
                      }
                  }), document.invitations.allSatisfy(Self.validInvitation) else { throw NotesError.invalidRecord }
        }
        let settings = root.appendingPathComponent("cloud-preferences.json")
        if let bytes = try? Data(contentsOf: settings), bytes.count <= 16 * 1024,
           let value = try? JSONDecoder().decode(NotesCloudPreferences.self, from: bytes), Self.validContainer(value.container) {
            preferences = value
        }
    }
    private static func validContainer(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 4096 }
    private static func validInvitation(_ value: NotesInvitation) -> Bool {
        value.url.scheme == "https" && value.url.host?.isEmpty == false && value.url.absoluteString.utf8.count <= 4096 && validContainer(value.container)
    }
    private func publish(_ value: Document) throws {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 1024 * 1024 else { throw NotesError.invalidRecord }
        try bytes.write(to: url, options: .atomic); document = value
    }
    func save(_ entry: NotebookEntry) throws {
        var next = document
        guard !next.entries.contains(where: { $0.id != entry.id && $0.graphID == entry.graphID }),
              next.entries.count < 1000 || next.entries.contains(where: { $0.id == entry.id }) else { throw NotesError.invalidRecord }
        if let index = next.entries.firstIndex(where: { $0.id == entry.id }) { next.entries[index] = entry }
        else { next.entries.append(entry) }
        try publish(next)
    }
    func remove(_ id: UUID) throws {
        var next = document; next.entries.removeAll { $0.id == id }; try publish(next)
    }
    func rememberCloud(container: String, environment: GraphCloudEnvironment) throws {
        let container = container.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validContainer(container) else { throw NotesError.invalidRecord }
        let value = NotesCloudPreferences(container: container, environment: environment)
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent("cloud-preferences.json"), options: .atomic)
        preferences = value
    }
    func retainInvitation(_ invitation: NotesInvitation) throws {
        guard Self.validInvitation(invitation) else { throw NotesError.invalidRecord }
        if document.invitations.contains(invitation) { return }
        guard document.invitations.count < 16 else { throw NotesError.busy }
        var next = document; next.invitations.append(invitation); try publish(next)
    }
    func consumeInvitation(_ invitation: NotesInvitation) throws {
        var next = document; next.invitations.removeAll { $0 == invitation }; try publish(next)
    }
    func directory(for entry: NotebookEntry) -> URL { root.appendingPathComponent("Notebooks").appendingPathComponent(entry.id.uuidString) }
    func storeURL(for entry: NotebookEntry) -> URL { directory(for: entry).appendingPathComponent("Graph.sqlite") }
    func draftURL(for entry: NotebookEntry, note: GraphNodeID, sceneID: String) -> URL {
        let scene = SHA256.hash(data: Data(sceneID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory(for: entry).appendingPathComponent("Drafts").appendingPathComponent(scene)
            .appendingPathComponent(note.rawValue.uuidString + ".json")
    }
}
