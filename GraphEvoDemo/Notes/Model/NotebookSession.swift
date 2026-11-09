import Foundation
import GraphEvo

/// Application-owned store lease and bounded catalogue view, shared across scenes.
@MainActor final class NotebookSession {
    let entryID: UUID
    let repository: NotesRepository
    private(set) var name: String
    private(set) var headers: [NoteHeader] = []
    private(set) var account: GraphCloudAccountState = .localOnly
    private(set) var sharing: GraphCloudSharingStatus?
    private(set) var issue: String?
    private(set) var hasMore = false
    private(set) var closed = false
    let mode: NotebookMode
    private var cursor: GraphQueryCursor?
    private var feed: GraphObservation<GraphChangeSignal>?
    private var changesTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var sharingTask: Task<Void, Never>?
    private var callbacks: [UUID: () -> Void] = [:]
    private var generation = UUID()
    private var covers: [GraphNodeID: Data] = [:]
    private var coverOrder: [GraphNodeID] = []
    var store: GraphStore { repository.store }
    var canRead: Bool {
        guard !closed else { return false }
        if case .isolated = account { return false }
        if let sharing, [.leaving, .purging, .removed].contains(sharing.phase) { return false }
        return true
    }
    var canWrite: Bool {
        guard canRead else { return false }
        return mode != .shared || (sharing?.phase == .active && sharing?.permission == .readWrite)
    }
    init(entry: NotebookEntry, store: GraphStore) {
        entryID = entry.id; repository = NotesRepository(store: store); mode = entry.mode; name = entry.placeholderName
    }
    deinit { changesTask?.cancel(); accountTask?.cancel(); sharingTask?.cancel(); feed?.cancel() }
    @discardableResult func observe(_ callback: @escaping () -> Void) -> UUID {
        let token = UUID(); callbacks[token] = callback; return token
    }
    func removeObserver(_ token: UUID) { callbacks.removeValue(forKey: token) }
    private func changed() { for callback in callbacks.values { callback() } }
    func start(cloud: GraphCloudConnection?) async throws {
        // Register before the first projection so a racing commit queues a rescan.
        let feed = try await store.changes(); self.feed = feed
        let accountFeed = try await store.observeCloudAccountState()
        account = try await store.cloudAccountState
        accountTask = Task { [weak self] in
            for await value in accountFeed {
                guard !Task.isCancelled, let self else { break }
                guard account != value else { continue }
                account = value
                if !canRead { clearVisibleData() }
                else { self.feed?.refresh() }
                changed()
            }
        }
        if mode == .shared, let cloud {
            do {
                // Keep the subscription even if the concurrent automatic refresh is busy.
                let updates = try await cloud.observeSharing(for: store.id)
                sharingTask = Task { [weak self] in
                    for await value in updates {
                        guard !Task.isCancelled, let self else { break }
                        sharing = value
                        if !canRead { clearVisibleData() }
                        changed()
                    }
                }
                // Observation is the sole publisher of permission state. A transient
                // verification refusal must not prevent later permission updates.
                _ = try await cloud.refreshSharing(for: store.id)
            } catch { issue = "Sharing status could not be verified. Local access follows GraphEvo permissions." }
        }
        changesTask = Task { [weak self] in
            for await _ in feed {
                guard !Task.isCancelled, let self else { break }
                await refresh()
            }
        }
        await refresh()
    }
    private func clearVisibleData() {
        generation = UUID(); headers = []; cursor = nil; hasMore = false
        covers = [:]; coverOrder = []; name = mode == .shared ? "Shared notebook" : "iCloud notebook"
    }
    func refresh() async {
        generation = UUID(); let expected = generation
        covers = [:]; coverOrder = []
        guard canRead else { clearVisibleData(); changed(); return }
        do {
            let name = try await repository.notebookName()
            let page = try await repository.headers()
            guard expected == generation, canRead, !Task.isCancelled else { return }
            self.name = name; headers = page.rows; cursor = page.next; hasMore = page.next != nil; issue = nil
        } catch {
            guard expected == generation else { return }
            if case GraphStoreError.accountIsolated = error { clearVisibleData() }
            issue = "This notebook could not be read. Its data is preserved; retry after resolving access or query limits."
        }
        changed()
    }
    func loadMore() async {
        guard let cursor, canRead else { return }
        let expected = generation
        do {
            let page = try await repository.headers(after: cursor)
            guard expected == generation, canRead else { return }
            let existing = Set(headers.map(\.id)); headers += page.rows.filter { !existing.contains($0.id) }
            self.cursor = page.next; hasMore = page.next != nil
        } catch { issue = "The next notes could not be read. Refresh the notebook to start a new page." }
        changed()
    }
    func cover(for id: GraphNodeID) async throws -> Data? {
        guard canRead else { return nil }
        if let value = covers[id] { return value }
        let expected = generation, value = try await repository.cover(id)
        guard expected == generation, canRead else { return nil }
        if let value {
            covers[id] = value; coverOrder.removeAll { $0 == id }; coverOrder.append(id)
            while covers.count > 20 || covers.values.reduce(0, { $0 + $1.count }) > 8 * 1024 * 1024 {
                covers.removeValue(forKey: coverOrder.removeFirst())
            }
        }
        return value
    }
    func foreground() { feed?.refresh() }
    func close() async throws {
        changesTask?.cancel(); accountTask?.cancel(); sharingTask?.cancel(); feed?.cancel()
        try await store.close(); closed = true; clearVisibleData(); changed()
    }
}
