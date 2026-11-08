import Foundation
import GraphEvo

/// Quick Look/export own a temporary copy; a library-scoped URL never escapes.
@MainActor final class NotesPresentationCache {
    let root: URL
    private var owned: [URL: GraphID] = [:]
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Constructed once by the application owner after the previous process ended.
        for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: item.lastPathComponent) != nil else { throw NotesError.invalidRecord }
            try FileManager.default.removeItem(at: item)
        }
    }
    func prepare(_ file: GraphFile, in store: GraphStore) async throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let destination = directory.appendingPathComponent(file.name)
        do {
            let value = try await store.withFileURL(file.id) { source in
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            }
            owned[value] = store.id; return value
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    func releaseAll(for graph: GraphID) throws {
        for (url, id) in owned where id == graph { try release(url) }
    }
    func release(_ value: URL) throws {
        guard owned[value] != nil else { return }
        try FileManager.default.removeItem(at: value.deletingLastPathComponent()); owned.removeValue(forKey: value)
    }
}
