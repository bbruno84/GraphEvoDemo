import Foundation
import CryptoKit
import GraphEvo

/// One injected application owner; scenes retain independent selection and editors.
@MainActor final class NotesApplicationModel {
    let catalog: NotebookCatalog
    let presentations: NotesPresentationCache
    let context: GraphContext
    let defaultContainer: String?
    private(set) var cloud: GraphCloudConnection?
    private var connectedPreferences: NotesCloudPreferences?
    private(set) var cloudState: GraphCloudConnectionState?
    private(set) var issue: String?
    private var sessionObservers: [UUID: UUID] = [:]
    private var sessions: [UUID: NotebookSession] = [:]
    private var openings: [UUID: Task<NotebookSession, any Error>] = [:]
    private var removals: [UUID: Task<Void, any Error>] = [:]
    private var activeScenes = Set<String>()
    private var cloudTask: Task<Void, Never>?
    private var callbacks: [UUID: () -> Void] = [:]
    private var connectionAttempt: (id: UUID, settings: NotesCloudPreferences, task: Task<Void, any Error>)?
    private var invitationPrompt: NotesInvitation?
    private var deferredInvitations: [NotesInvitation] = []
    private(set) var acceptingInvitation = false
    var notebooks: [NotebookEntry] { catalog.entries }
    var cloudReady: Bool { cloudState == .ready }
    var suggestedContainer: String { catalog.invitations.first?.container ?? catalog.preferences?.container ?? defaultContainer ?? "" }
    init(root: URL, context: GraphContext = .localFiles(), defaultContainer: String? = nil, presentationRoot: URL? = nil) throws {
        catalog = try NotebookCatalog(root: root)
        presentations = try NotesPresentationCache(root: presentationRoot ?? root.appendingPathComponent("Presentations"))
        self.context = context; self.defaultContainer = defaultContainer
    }
    deinit {
        cloudTask?.cancel()
        let cloud = cloud, sessions = Array(sessions.values)
        Task { @MainActor in
            for session in sessions { try? await session.close() }
            try? await cloud?.close()
        }
    }
    @discardableResult func observe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID(); callbacks[id] = callback; return id
    }
    func removeObserver(_ id: UUID) { callbacks.removeValue(forKey: id) }
    func changed() { for callback in callbacks.values { callback() } }
    func displayName(for entry: NotebookEntry) -> String {
        guard let session = sessions[entry.id], session.canRead else { return entry.placeholderName }
        return session.name
    }
    func recordFailure(_ error: any Error) {
        switch error {
        case NotesError.cloudNotReady: issue = "iCloud is not ready. Check the account or connection and retry; settings are available for configuration. Local notebooks remain available."
        case GraphStoreError.accountIsolated: issue = "This notebook belongs to an unavailable iCloud account. Its data is preserved."
        case GraphStoreError.permissionDenied, GraphStoreError.readOnly: issue = "This notebook is read-only. Ask its owner to allow changes."
        case NotesError.pendingDeletion: issue = "Notebook removal is still pending. Use Retry removal to continue it."
        default: issue = "The operation could not complete. Existing data and pending work are preserved; retry when access is available."
        }
        changed()
    }
    func setSceneActive(_ id: String, active: Bool) async throws {
        if active { activeScenes.insert(id) } else { activeScenes.remove(id) }
        try await context.setForegroundActive(!activeScenes.isEmpty)
        if active { for session in sessions.values { session.foreground() } }
    }
    func automaticCloudPreferences(for invitation: NotesInvitation? = nil) -> NotesCloudPreferences? {
        if let invitation {
            return NotesCloudPreferences(container: invitation.container,
                environment: catalog.preferences?.environment ?? .development)
        }
        if let remembered = catalog.preferences { return remembered }
        let container = catalog.invitations.first?.container ?? defaultContainer ?? ""
        guard !container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NotesCloudPreferences(container: container, environment: .development)
    }
    func connectAutomatically(for invitation: NotesInvitation? = nil) async throws {
        guard let settings = automaticCloudPreferences(for: invitation) else { return }
        if let attempt = connectionAttempt {
            if attempt.settings == settings { return try await attempt.task.value }
            // An explicitly accepted invitation may choose a different profile.
            _ = try? await attempt.task.value
            if connectionAttempt?.id == attempt.id { connectionAttempt = nil }
        }
        if cloud != nil, connectedPreferences == settings { return }
        try await connect(container: settings.container, environment: settings.environment)
    }
    func connect(container: String, environment: GraphCloudEnvironment) async throws {
        let settings = NotesCloudPreferences(container: container.trimmingCharacters(in: .whitespacesAndNewlines), environment: environment)
        if let attempt = connectionAttempt {
            guard attempt.settings == settings else { throw NotesError.busy }
            return try await attempt.task.value
        }
        let task = Task { try await self.performConnection(settings) }
        let id = UUID()
        connectionAttempt = (id, settings, task)
        defer { if connectionAttempt?.id == id { connectionAttempt = nil } }
        try await task.value
    }
    private func performConnection(_ settings: NotesCloudPreferences) async throws {
        let container = settings.container, environment = settings.environment
        let previous = catalog.preferences
        try catalog.rememberCloud(container: container, environment: environment)
        if previous != catalog.preferences || (cloud != nil && connectedPreferences != settings) {
            cloudTask?.cancel()
            for (id, session) in sessions where catalog.entries.first(where: { $0.id == id })?.mode != .local {
                try await session.close(); sessions.removeValue(forKey: id)
            }
            try await cloud?.close(); cloud = nil; cloudState = nil; connectedPreferences = nil
        }
        if let cloud {
            guard connectedPreferences == settings else { throw NotesError.cloudNotReady }
            try await cloud.retry(); return
        }
        guard let settings = catalog.preferences else { throw NotesError.cloudNotReady }
        let configuration = try GraphCloudConnectionConfiguration(containerIdentifier: settings.container, environment: settings.environment,
            directory: catalog.root.appendingPathComponent("Cloud-v12").appendingPathComponent(
                SHA256.hash(data: Data((settings.environment.rawValue + ":" + settings.container).utf8)).map { String(format: "%02x", $0) }.joined()))
        let cloud = try await context.connectCloud(using: configuration)
        self.cloud = cloud; connectedPreferences = settings; cloudState = try await cloud.state
        let updates = try await cloud.observeState()
        cloudTask = Task { [weak self] in
            for await value in updates {
                guard !Task.isCancelled, let self else { break }
                cloudState = value; changed()
                if value == .ready { await bindOpenNotebooks() }
            }
        }
        changed()
    }
    private func automaticReadyCloud(for invitation: NotesInvitation? = nil) async throws -> GraphCloudConnection {
        try await connectAutomatically(for: invitation)
        guard let connection = cloud else { throw NotesError.cloudNotReady }
        let settings = catalog.preferences
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let states = try await connection.observeState()
                defer { states.cancel() }
                for await state in states {
                    try Task.checkCancellation()
                    switch state {
                    case .ready: return
                    case .verifyingAccount: continue
                    default: throw NotesError.cloudNotReady
                    }
                }
                throw NotesError.cloudNotReady
            }
            group.addTask { try await Task.sleep(for: .seconds(20)); throw NotesError.cloudNotReady }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        guard cloud === connection, catalog.preferences == settings, connectedPreferences == settings else { throw NotesError.cloudNotReady }
        cloudState = try await connection.state
        guard cloudReady else { throw NotesError.cloudNotReady }
        changed()
        return connection
    }
    private func requireCloud(for entry: NotebookEntry? = nil) throws -> GraphCloudConnection {
        guard cloudReady, let cloud, connectedPreferences == catalog.preferences else { throw NotesError.cloudNotReady }
        if let entry, entry.cloud != catalog.preferences { throw NotesError.cloudNotReady }
        return cloud
    }
    private func bindOpenNotebooks() async {
        guard let cloud, connectedPreferences == catalog.preferences else { return }
        for entry in catalog.entries where entry.mode == .iCloud && entry.cloud == catalog.preferences && !entry.deleting {
            guard let session = sessions[entry.id], let zone = entry.zoneName else { continue }
            do { try await cloud.bindPrivateGraph(session.store, zoneName: zone); session.foreground() }
            catch { recordFailure(error) }
        }
    }
    func createNotebook(name: String, mode: NotebookMode) async throws -> NotebookSession {
        guard mode != .shared else { throw NotesError.invalidRecord }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 1024 else { throw NotesError.invalidRecord }
        if mode == .iCloud { _ = try await automaticReadyCloud() }
        let entry = NotebookEntry(mode: mode, zoneName: mode == .iCloud ? "GraphEvoDemoNotes-" + UUID().uuidString : nil,
            cloud: mode == .local ? nil : catalog.preferences, creating: true, localName: name)
        try catalog.save(entry); changed()
        return try await openNotebook(entry.id)
    }
    func openNotebook(_ id: UUID) async throws -> NotebookSession {
        guard let entry = catalog.entries.first(where: { $0.id == id }) else { throw NotesError.invalidRecord }
        guard !entry.deleting, !entry.leaving else { throw NotesError.pendingDeletion }
        if let session = sessions[id], !session.closed { return session }
        if let opening = openings[id] { return try await opening.value }
        let opening = Task { try await self.open(entry) }
        openings[id] = opening
        do {
            let session = try await opening.value
            guard let current = catalog.entries.first(where: { $0.id == id }),
                  !current.deleting, !current.leaving,
                  current.mode == .local || current.cloud == catalog.preferences else {
                try await session.close(); throw NotesError.pendingDeletion
            }
            sessions[id] = session
            sessionObservers[id] = session.observe { [weak self, weak session] in
                guard let self else { return }
                if let session, !session.canRead { try? presentations.releaseAll(for: session.store.id) }
                changed()
            }
            openings.removeValue(forKey: id); changed(); return session
        } catch { openings.removeValue(forKey: id); throw error }
    }
    private func open(_ original: NotebookEntry) async throws -> NotebookSession {
        var entry = original
        let url = catalog.storeURL(for: entry)
        if entry.mode != .local, entry.cloud != catalog.preferences { throw NotesError.cloudNotReady }
        if entry.mode == .iCloud, entry.creating { _ = try requireCloud(for: entry) }
        let store: GraphStore
        if entry.mode == .shared {
            let cloud = try requireCloud(for: entry)
            guard let joinID = entry.joinID,
                  let join = try await cloud.pendingInvitations().first(where: { $0.id == joinID }) else { throw NotesError.invalidRecord }
            store = try await cloud.openReplica(for: join, at: url)
        } else if entry.recovering {
            let cloud = try requireCloud(for: entry)
            let found = try await cloud.discoverPrivateGraphs(zoneNamePrefix: entry.zoneName)
            guard let reference = found.graphs.first(where: { $0.id == entry.graphID && $0.zoneName == entry.zoneName }) else { throw NotesError.invalidRecord }
            store = try await cloud.openPrivateGraph(reference, at: url)
        } else if entry.creating && !FileManager.default.fileExists(atPath: url.path) {
            store = try await context.createGraph(id: entry.graphID, at: url)
        } else { store = try await context.openGraph(id: entry.graphID, at: url) }
        do {
            if entry.creating {
                let infos = try await store.query(GraphQuery<NotebookInfo>(budget: NotesRepository.budget()).limit(2))
                guard infos.items.count <= 1 else { throw NotesError.invalidRecord }
                if infos.items.isEmpty { try await store.insert(NotebookInfo(name: entry.localName ?? "Notebook")) }
            }
            if entry.mode == .iCloud, cloudReady {
                let cloud = try requireCloud(for: entry)
                guard let zone = entry.zoneName else { throw NotesError.invalidRecord }
                try await cloud.bindPrivateGraph(store, zoneName: zone)
            }
            guard let current = catalog.entries.first(where: { $0.id == entry.id }),
                  !current.deleting, !current.leaving else { throw NotesError.pendingDeletion }
            if entry.mode != .local, entry.cloud != catalog.preferences { throw NotesError.cloudNotReady }
            entry.creating = false; entry.recovering = false
            if entry.mode != .local { entry.localName = nil }
            try catalog.save(entry)
            let session = NotebookSession(entry: entry, store: store)
            try await session.start(cloud: cloud)
            return session
        } catch {
            let original = error
            try await store.close()
            throw original
        }
    }
    func discoverNotebooks() async throws {
        let cloud = try requireCloud()
        let found = try await cloud.discoverPrivateGraphs(zoneNamePrefix: "GraphEvoDemoNotes-")
        for reference in found.graphs {
            if catalog.entries.contains(where: { $0.graphID == reference.id }) { continue }
            try catalog.save(NotebookEntry(graphID: reference.id, mode: .iCloud, zoneName: reference.zoneName,
                cloud: catalog.preferences, recovering: true))
        }
        issue = found.issues.isEmpty ? nil : "Some iCloud notebooks have unsupported or ambiguous metadata and were preserved."
        changed()
    }
    func retainInvitation(url: URL, container: String) throws {
        let invitation = NotesInvitation(url: url, container: container)
        try catalog.retainInvitation(invitation)
        deferredInvitations.removeAll { $0 == invitation }
        changed()
    }
    var hasPromptableInvitation: Bool {
        !acceptingInvitation && invitationPrompt == nil && catalog.invitations.contains { !deferredInvitations.contains($0) }
    }
    func claimInvitationPrompt() -> NotesInvitation? {
        guard !acceptingInvitation, invitationPrompt == nil,
              let invitation = catalog.invitations.first(where: { !deferredInvitations.contains($0) }) else { return nil }
        invitationPrompt = invitation
        return invitation
    }
    func finishInvitationPrompt(_ invitation: NotesInvitation, deferUntilNextLaunch: Bool) {
        guard invitationPrompt == invitation else { return }
        deferredInvitations = deferredInvitations.filter { catalog.invitations.contains($0) }
        if deferUntilNextLaunch, catalog.invitations.contains(invitation), !deferredInvitations.contains(invitation) {
            deferredInvitations.append(invitation)
        }
        invitationPrompt = nil; changed()
    }
    func acceptInvitation(_ invitation: NotesInvitation) async throws -> UUID? {
        guard !acceptingInvitation, catalog.invitations.contains(invitation) else { throw NotesError.busy }
        acceptingInvitation = true; changed()
        defer { acceptingInvitation = false; changed() }
        let cloud = try await automaticReadyCloud(for: invitation)
        let join = try await cloud.acceptInvitation(at: invitation.url)
        try catalog.consumeInvitation(invitation)
        try await resumeInvitations(using: cloud)
        let entry = catalog.entries.first(where: { $0.joinID == join.id })
        issue = entry == nil ? "The invitation is retained by iCloud. Resume it in Settings when the shared notebook is ready." : nil
        changed()
        return entry?.id
    }
    func acceptInvitations() async throws {
        guard !acceptingInvitation else { throw NotesError.busy }
        for invitation in catalog.invitations { _ = try await acceptInvitation(invitation) }
        let cloud = try await automaticReadyCloud()
        try await resumeInvitations(using: cloud)
    }
    private func resumeInvitations(using cloud: GraphCloudConnection) async throws {
        for join in try await cloud.pendingInvitations() {
            var state = try await join.state
            if [.acceptancePending, .discoveringGraph].contains(state.phase) { try await join.retry(); state = try await join.state }
            guard let graphID = state.graphID, [.ready, .joined].contains(state.phase) else { continue }
            if catalog.entries.contains(where: { $0.graphID == graphID }) { continue }
            try catalog.save(NotebookEntry(graphID: graphID, mode: .shared, joinID: join.id, cloud: catalog.preferences))
        }
        changed()
    }
    func deleteNotebook(_ id: UUID) async throws {
        guard var entry = catalog.entries.first(where: { $0.id == id }) else { throw NotesError.invalidRecord }
        if entry.mode == .shared { entry.leaving = true } else { entry.deleting = true }
        try catalog.save(entry); changed()
        try await retryRemoval(id)
    }
    func retryRemoval(_ id: UUID) async throws {
        if let removal = removals[id] { return try await removal.value }
        let removal = Task { try await self.performRemoval(id) }
        removals[id] = removal
        defer { removals.removeValue(forKey: id) }
        try await removal.value
    }
    private func performRemoval(_ id: UUID) async throws {
        // A pending open must settle before terminal lifecycle takes ownership.
        if let opening = openings[id] { _ = try? await opening.value }
        guard let entry = catalog.entries.first(where: { $0.id == id }), entry.deleting || entry.leaving else { throw NotesError.invalidRecord }
        let url = catalog.storeURL(for: entry)
        if entry.mode == .shared {
            let cloud = try requireCloud(for: entry)
            if let session = sessions[id] {
                _ = try await cloud.leaveSharedGraph(session.store)
                try await session.close(); sessions.removeValue(forKey: id)
            } else {
                let joins = try await cloud.pendingInvitations()
                guard let join = joins.first(where: { $0.id == entry.joinID }) else { throw NotesError.invalidRecord }
                let state = try await join.state
                if [.ready, .discoveringGraph, .acceptancePending, .discarded, .discarding].contains(state.phase) {
                    try await cloud.discardInvitation(join)
                    guard try await join.state.phase == .discarded else { throw NotesError.pendingDeletion }
                    try catalog.remove(id); changed(); return
                }
                let prior = try await cloud.sharingStatus(for: entry.graphID)
                if [.leaving, .purging, .removed].contains(prior.phase) {
                    try await cloud.registerSharedReplica(id: entry.graphID, at: url)
                    try await cloud.requestSynchronization()
                } else {
                    let store = try await cloud.openReplica(for: join, at: url)
                    do { _ = try await cloud.leaveSharedGraph(store); try await store.close() }
                    catch { let failure = error; try await store.close(); throw failure }
                }
            }
            let status = try await cloud.sharingStatus(for: entry.graphID)
            guard status.phase == .removed, !status.remoteOperationPending else { throw NotesError.pendingDeletion }
        } else {
            let status: GraphDeletionStatus
            if let pending = try await context.graphDeletionStatus(id: entry.graphID, at: url) {
                if entry.mode == .local { status = try await context.resumeGraphDeletion(id: entry.graphID, at: url) }
                else { status = try await requireCloud(for: entry).resumeGraphDeletion(id: entry.graphID, at: url) }
                guard status.id == pending.id else { throw NotesError.invalidRecord }
            } else if let session = sessions[id] {
                if entry.mode == .local { status = try await context.deleteGraph(session.store) }
                else { status = try await requireCloud(for: entry).deleteGraph(session.store) }
            } else {
                let store: GraphStore
                if entry.recovering {
                    let cloud = try requireCloud(for: entry)
                    let found = try await cloud.discoverPrivateGraphs(zoneNamePrefix: entry.zoneName)
                    guard let reference = found.graphs.first(where: { $0.id == entry.graphID && $0.zoneName == entry.zoneName }) else { throw NotesError.invalidRecord }
                    store = try await cloud.openPrivateGraph(reference, at: url)
                } else { store = try await context.openGraph(id: entry.graphID, at: url) }
                do {
                    if entry.mode == .local { status = try await context.deleteGraph(store) }
                    else { status = try await requireCloud(for: entry).deleteGraph(store) }
                    try await store.close()
                } catch { let failure = error; try await store.close(); throw failure }
            }
            guard status.phase == .completed else { throw NotesError.pendingDeletion }
            if let session = sessions[id] { try await session.close(); sessions.removeValue(forKey: id) }
        }
        let drafts = catalog.directory(for: entry).appendingPathComponent("Drafts")
        if FileManager.default.fileExists(atPath: drafts.path) { try FileManager.default.removeItem(at: drafts) }
        sessionObservers.removeValue(forKey: id)
        try catalog.remove(id); issue = nil; changed()
    }
    func requestSynchronization() async throws { try await requireCloud().requestSynchronization() }
}
