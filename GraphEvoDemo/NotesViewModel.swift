import Foundation
import UIKit
import GraphEvo

@MainActor
final class NotesViewModel: NSObject, GraphEntityDelegate {

    private let provider: GraphProvider
    private var watcher: Watch<Entity>?

    private(set) var notes: [Entity] = []
    var onNotesChanged: (() -> Void)?

    init(provider: GraphProvider) {
        self.provider = provider
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(providerStateDidChange),
            name: .graphProviderStateDidChange,
            object: provider
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        watcher?.pause()
    }

    func start() {
        refresh()
        activateWatcherIfPossible()
    }

    func refresh() {
        guard let graph = provider.graphIfReady() else {
            notes = []
            onNotesChanged?()
            return
        }

        notes = Search<Entity>(graph: graph)
            .where(.type("Note"))
            .sync()
            .sorted {
                ($0[dynamicMember: "createdAt"] as? Date ?? .distantPast)
                    > ($1[dynamicMember: "createdAt"] as? Date ?? .distantPast)
            }

        onNotesChanged?()
    }

    func addNote() {
        guard let graph = provider.graphIfReady() else { return }

        let note = Entity("Note", graph: graph)
        note[dynamicMember: "title"] = "Note at \(Date())"
        note[dynamicMember: "createdAt"] = Date()
        note.add(tags: "inbox")
        graph.sync()
    }

    func deleteNote(at index: Int) {
        guard let graph = provider.graphIfReady(), notes.indices.contains(index) else { return }

        notes[index].delete()
        graph.sync()
        refresh()
    }

    func toggleFavorite(for note: Entity) {
        if note.has(tags: "favorite") {
            note.remove(tags: "favorite")
        } else {
            note.add(tags: "favorite")
        }

        provider.graphIfReady()?.sync()
        onNotesChanged?()
    }

    private func activateWatcherIfPossible() {
        guard watcher == nil, let graph = provider.graphIfReady() else { return }

        let watcher = Watch<Entity>(graph: graph).where(.type("Note"))
        watcher.delegate = self
        // Watchers are initially stopped. Resume only after assigning the
        // delegate so the first observed change has a valid receiver.
        watcher.resume()
        self.watcher = watcher
        print("👀 NotesViewModel watcher started")
    }

    @objc private func providerStateDidChange() {
        guard provider.isReady else { return }
        refresh()
        activateWatcherIfPossible()
    }

    @objc private func applicationDidBecomeActive() {
        refresh()
    }

    func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) {
        print("📥 Inserted \(entity.type) from: \(source)")
        refresh()
    }

    func graph(_ graph: Graph, updated entity: Entity, source: GraphSource) {
        print("✏️ Updated \(entity.type) from: \(source)")
        refresh()
    }

    func graph(_ graph: Graph, deleted entity: Entity, source: GraphSource) {
        print("🗑️ Deleted \(entity.type) from: \(source)")
        refresh()
    }
}
