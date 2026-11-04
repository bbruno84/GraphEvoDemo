import Foundation
import CloudKit
import GraphEvo

struct PublicV2Note: GraphModel, Sendable {
    let id: UUID
    let title: String
    static let graphType = "GraphEvoDemo.PublicV2.Note.v1"
    static let graphKind = GraphNodeKind.entity
    init(id: UUID = UUID(), title: String) { self.id = id; self.title = title }
    init(graphRecord: GraphRecord) throws {
        id = graphRecord.id.rawValue; title = try graphRecord.value(for: "title")
    }
    func graphRecord(in graphID: GraphID) throws -> GraphRecord {
        try GraphRecord(id: graphNodeID(in: graphID), type: Self.graphType, properties: ["title": .string(title)])
    }
}

enum PublicV2DemoError: Error { case busy, closed, missingNote, invalidSource, invalidRoute, confirmationRequired, populatedReplica, invitationContainerMismatch }

/// The app owns this context. View controllers forward actions and render detached values.
@MainActor final class PublicV2ViewModel {
    private struct Workspace: Codable {
        var graphID: GraphID
        let operationID: UUID
        let activationID: UUID
        var sharedJoinID: UUID? = nil
        var zoneName: String
        init() {
            graphID = GraphID(); operationID = UUID(); activationID = UUID()
            zoneName = "Demo-" + UUID().uuidString
        }
    }
    struct CloudPreferences: Codable, Equatable {
        let container: String
        let environment: GraphCloudEnvironment
    }
    private(set) var cloudPreferences: CloudPreferences?
    private let defaultContainer: String?
    var suggestedCloudContainer: String? { incomingInvitations.first?.container ?? cloudPreferences?.container ?? defaultContainer }
    var suggestedCloudEnvironment: GraphCloudEnvironment {
        guard cloudPreferences?.container == suggestedCloudContainer else { return .development }
        return cloudPreferences?.environment ?? .development
    }
    func rememberCloudConfiguration(container: String, environment: GraphCloudEnvironment) throws {
        let identifier = container.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, identifier.utf8.count <= 4096 else { throw GraphCloudConnectionError.invalidConfiguration }
        let value = CloudPreferences(container: identifier, environment: environment)
        try JSONEncoder().encode(value).write(to: baseURL.appendingPathComponent("cloud-preferences.json"), options: .atomic)
        cloudPreferences = value
    }
    private(set) var context: GraphContext
    private var foregroundActive = false
    private let baseURL: URL
    private(set) var directory: URL
    private var workspace: Workspace
    private var graph: GraphStore?
    private var cloud: GraphCloudConnection?
    private var configuredContainer: String?
    private var sharing: GraphCloudSharingPresentation?
    private var sharingTask: Task<Void, Never>?
    struct IncomingInvitation: Codable, Equatable {
        let url: URL
        let container: String
    }
    private(set) var incomingInvitations: [IncomingInvitation] = []
    private(set) var invitations: [GraphCloudJoinState] = []
    private(set) var sharingDescription = "Not inspected"
    private var graphTask: Task<Void, Never>?
    private var cloudTask: Task<Void, Never>?
    private var notesTask: Task<Void, Never>?
    private var notesGeneration = UUID()
    private(set) var notes: [PublicV2Note] = []
    private(set) var accountState: GraphCloudAccountState = .localOnly
    private(set) var cloudState: GraphCloudConnectionState?
    private(set) var message = "Create a local graph or select an existing workspace."
    private(set) var isBusy = false
    private(set) var convertedNodeCount: Int?
    private(set) var lastIssueCode: String?
    var onChange: (() -> Void)?
    var accountDescription: String {
        switch accountState {
        case .localOnly: return "Local only"
        case .available: return "Account verified"
        case .temporarilyUnavailable: return "Cloud unavailable; local access retained"
        case .isolated(let reason):
            switch reason {
            case .verificationRequired: return "Identity verification required"
            case .signedOut: return "Signed out; data preserved"
            case .differentAccount: return "Different account; data preserved"
            case .restricted: return "Account restricted; data preserved"
            }
        }
    }
    var cloudDescription: String {
        guard let cloudState else { return "Disconnected" }
        switch cloudState {
        case .verifyingAccount: return "Verifying account"
        case .ready: return "Transport ready"
        case .temporarilyUnavailable: return "Temporarily unavailable"
        case .isolated: return "Account isolated"
        case .failed(let failure): return "Needs attention: " + String(describing: failure.category)
        }
    }
    var graphID: GraphID { workspace.graphID }
    var zoneName: String { workspace.zoneName }
    var zoneDescription: String { workspace.sharedJoinID == nil ? workspace.zoneName : "Shared zone from accepted Apple invitation" }
    var supportSummary: String {
        ["GraphEvo 2", "Graph: " + graphID.rawValue.uuidString,
         "Local: " + accountDescription, "Cloud: " + cloudDescription,
         "Sharing: " + sharingDescription, "Pending invitations: " + String(incomingInvitations.count),
         "Issue: " + (lastIssueCode ?? "none")].joined(separator: "\n")
    }
    var canRead: Bool {
        switch accountState { case .isolated: return false; default: return graph != nil }
    }
    private var storeURL: URL { directory.appendingPathComponent("Graph.sqlite") }
    private var descriptorURL: URL { directory.appendingPathComponent("workspace.json") }

    init(baseURL: URL, context: GraphContext = GraphContext(), defaultContainer: String? = nil) throws {
        self.baseURL = baseURL; self.context = context; self.defaultContainer = defaultContainer
        let preferences = baseURL.appendingPathComponent("cloud-preferences.json")
        if FileManager.default.fileExists(atPath: preferences.path) {
            do {
                let bytes = try Data(contentsOf: preferences)
                guard bytes.count <= 16 * 1024 else { throw GraphCloudConnectionError.invalidConfiguration }
                let value = try JSONDecoder().decode(CloudPreferences.self, from: bytes)
                guard !value.container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.container.utf8.count <= 4096 else { throw GraphCloudConnectionError.invalidConfiguration }
                cloudPreferences = value
            } catch {
                message = "Saved cloud settings are invalid. Local workspace is available; choose cloud settings again."
            }
        }
        let pending = baseURL.appendingPathComponent("incoming-invitations.json")
        if FileManager.default.fileExists(atPath: pending.path) {
            let bytes = try Data(contentsOf: pending)
            guard bytes.count <= 128 * 1024 else { throw PublicV2DemoError.invalidRoute }
            incomingInvitations = try JSONDecoder().decode([IncomingInvitation].self, from: bytes)
            guard incomingInvitations.count <= 16 else { throw PublicV2DemoError.invalidRoute }
        }
        let pointer = baseURL.appendingPathComponent("current-workspace.json")
        if FileManager.default.fileExists(atPath: pointer.path) {
            let id = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: pointer))
            directory = baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
            workspace = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: directory.appendingPathComponent("workspace.json")))
        } else {
            let id = UUID(); directory = baseURL.appendingPathComponent(id.uuidString, isDirectory: true); workspace = Workspace()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(workspace).write(to: directory.appendingPathComponent("workspace.json"), options: .atomic)
            try JSONEncoder().encode(id).write(to: pointer, options: .atomic)
        }
    }

    deinit {
        graphTask?.cancel(); cloudTask?.cancel(); notesTask?.cancel(); sharingTask?.cancel()
        let graph = graph, cloud = cloud, sharing = sharing
        Task {
            if let sharing { try? await sharing.close() }
            if let cloud { try? await cloud.close() }
            if let graph { try? await graph.close() }
        }
    }

    func create() async throws { try await perform { guard graph == nil else { throw PublicV2DemoError.busy }; try await adopt(try await context.createGraph(id: graphID, at: storeURL)) } }
    func open() async throws { try await perform { guard graph == nil else { throw PublicV2DemoError.busy }; try await adopt(try await context.openGraph(id: graphID, at: storeURL)) } }
    private func adopt(_ opened: GraphStore) async throws {
        guard graph == nil else { throw PublicV2DemoError.busy }
        graph = opened
        applyAccountState(try await opened.cloudAccountState)
        graphTask = Task { [weak self] in
            do {
                let observation = try await opened.observeCloudAccountState()
                defer { observation.cancel() }
                for await state in observation {
                    guard let self, !Task.isCancelled else { break }
                    self.applyAccountState(state)
                    if self.canRead { self.observeNotes(opened) }
                }
            } catch { self?.recordFailure(error) }
        }
        if canRead { try await refreshNotes() }
        message = "Graph opened. Local availability is shown separately from cloud state."
    }
    func refreshNotes() async throws {
        guard canRead else { throw GraphStoreError.accountIsolated }
        guard let graph else { throw PublicV2DemoError.closed }
        let query = GraphQuery<PublicV2Note>(budget: try GraphQueryBudget(maximumCandidates: 10_000))
            .sorted(by: [GraphQuerySort(.property("title"))])
        do {
            let items = try await graph.query(query).items
            guard canRead, self.graph === graph else { return }
            notes = items; onChange?()
        }
        catch { notes = []; onChange?(); throw error }
    }
    private func observeNotes(_ graph: GraphStore) {
        notesTask?.cancel(); notesGeneration = UUID()
        let generation = notesGeneration
        notesTask = Task { [weak self] in
            do {
                let query = GraphQuery<PublicV2Note>(budget: try GraphQueryBudget(maximumCandidates: 10_000))
                    .sorted(by: [GraphQuerySort(.property("title"))])
                let observation = try await graph.observe(query)
                defer { observation.cancel() }
                for await state in observation {
                    guard let self, !Task.isCancelled, self.notesGeneration == generation, self.canRead else { break }
                    switch state {
                    case .value(let result): self.notes = result.items; self.onChange?()
                    case .failure(let error): self.notes = []; self.recordFailure(error)
                    }
                }
            } catch { if !Task.isCancelled { self?.recordFailure(error) } }
        }
    }
    func applyAccountState(_ state: GraphCloudAccountState) {
        accountState = state
        if case .isolated = state { notesTask?.cancel(); notesTask = nil; notesGeneration = UUID(); notes = [] }
        onChange?()
    }
    func addNote() async throws {
        try await perform {
            guard let graph else { throw PublicV2DemoError.closed }
            try await graph.insert(PublicV2Note(title: "Note " + UUID().uuidString.prefix(8)))
            try await refreshNotes()
        }
    }
    func connect(container: String, environment: GraphCloudEnvironment) async throws {
        try await perform {
            guard cloud == nil else { throw PublicV2DemoError.busy }
            try rememberCloudConfiguration(container: container, environment: environment)
            guard let container = cloudPreferences?.container else { throw GraphCloudConnectionError.invalidConfiguration }
            cloud = try await context.connectCloud(using: .init(containerIdentifier: container, environment: environment,
                directory: directory.appendingPathComponent("CloudSession"), allowsSessionUpgradeFromV8: true))
            guard let cloud else { return }
            configuredContainer = container
            cloudTask = Task { [weak self] in
                do {
                    let observation = try await cloud.observeState()
                    defer { observation.cancel() }
                    for await state in observation {
                        guard let self, !Task.isCancelled else { break }
                        self.cloudState = state; self.onChange?()
                    }
                } catch { self?.recordFailure(error) }
            }
        }
    }
    func bindPrivate() async throws {
        try await perform {
            guard let graph, let cloud else { throw PublicV2DemoError.closed }
            try await cloud.bindPrivateGraph(graph, zoneName: zoneName)
            message = "Private binding saved; this is not proof of remote delivery."
        }
    }
    func requestSync() async throws {
        guard let cloud else { throw PublicV2DemoError.closed }
        try await cloud.requestSynchronization()
        message = "Synchronization requested."; onChange?()
    }
    func retryAccounts() async throws {
        try await context.refreshCloudAccounts()
        if let cloud { try await cloud.retry() }
    }
    func setForegroundActive(_ active: Bool) async throws { try await context.setForegroundActive(active); foregroundActive = active }

    func convertV1(sourceDirectory: URL, sqliteName: String, stoppedWritersConfirmed: Bool) async throws {
        try await perform {
            guard stoppedWritersConfirmed else { throw PublicV2DemoError.confirmationRequired }
            guard sqliteName == (sqliteName as NSString).lastPathComponent, sqliteName.lowercased().hasSuffix(".sqlite") else {
                throw PublicV2DemoError.invalidSource
            }
            guard graph == nil else { throw PublicV2DemoError.busy }
            let access = sourceDirectory.startAccessingSecurityScopedResource()
            defer { if access { sourceDirectory.stopAccessingSecurityScopedResource() } }
            let result = try await context.openGraph(convertingLocalV1: .init(sourceURL: sourceDirectory.appendingPathComponent(sqliteName),
                destinationURL: storeURL, graphID: graphID, operationID: workspace.operationID,
                backupRoot: directory.appendingPathComponent("Backups"), reason: "Explicit demo stopped-source conversion"))
            convertedNodeCount = result.conversion.receipt.nodeIDs.count
            message = result.conversion.cleanupPending ? "Conversion committed; native cleanup needs attention." : "Conversion committed; receipt retained in the store."
            try await adopt(result.opening.get())
        }
    }
    func publish(declaration: GraphCloudCutoverDeclaration) async throws {
        try await perform {
            guard let cloud else { throw PublicV2DemoError.closed }
            if try await cloud.activationStatus(for: graphID) == nil {
                _ = try await cloud.prepareActivation(for: graphID, activationID: workspace.activationID, zoneName: zoneName, declaration: declaration)
            }
            let result = try await cloud.advanceActivation(for: graphID)
            message = "Authority phase: " + result.status.phase.rawValue
            if let error = result.operationError { throw error }
        }
    }
    func recoverReplica(graphID: GraphID, zoneName: String) async throws {
        try await perform {
            guard graph == nil else { throw PublicV2DemoError.populatedReplica }
            if FileManager.default.fileExists(atPath: storeURL.path), (workspace.graphID != graphID || workspace.zoneName != zoneName) {
                throw PublicV2DemoError.populatedReplica
            }
            guard let cloud else { throw PublicV2DemoError.closed }
            workspace.graphID = graphID; workspace.zoneName = zoneName
            try JSONEncoder().encode(workspace).write(to: descriptorURL, options: .atomic)
            let result = try await cloud.openReplica(id: graphID, at: storeURL, zoneName: zoneName)
            try await adopt(result.opening.get())
        }
    }
    func importAttachment(from url: URL) async throws {
        try await perform {
            guard let graph, let owner = notes.first else { throw PublicV2DemoError.missingNote }
            let metadata = try await graph.importAttachment(from: url, ownedBy: owner.graphNodeID(in: graphID))
            message = "Imported attachment: " + metadata.fileName
        }
    }
    func close() async throws {
        graphTask?.cancel(); cloudTask?.cancel(); notesTask?.cancel(); sharingTask?.cancel(); graphTask = nil; cloudTask = nil; notesTask = nil; notesGeneration = UUID()
        if let sharing { try await sharing.close(); self.sharing = nil }
        if let cloud { try await cloud.close(); self.cloud = nil; cloudState = nil }
        if let graph { try await graph.close(); self.graph = nil }
        notes = []; invitations = []; sharingDescription = "Not inspected"; sharingTask = nil
        onChange?()
    }
    func newWorkspace() async throws {
        try await perform {
            if workspace.sharedJoinID != nil, let cloud {
                let status = try await cloud.sharingStatus(for: graphID)
                guard !status.remoteOperationPending else { throw GraphStoreError.pendingNativeOperation }
            }
            try await close()
            let nextContext = GraphContext()
            try await nextContext.setForegroundActive(foregroundActive)
            context = nextContext
            let id = UUID(); directory = baseURL.appendingPathComponent(id.uuidString, isDirectory: true); workspace = Workspace()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(workspace).write(to: descriptorURL, options: .atomic)
            try JSONEncoder().encode(id).write(to: baseURL.appendingPathComponent("current-workspace.json"), options: .atomic)
            convertedNodeCount = nil; accountState = .localOnly
            message = "New workspace selected. Previous files are preserved."
        }
    }
    func stageNativeInvitation(url: URL, container: String) throws {
        guard url.scheme == "https", url.host?.isEmpty == false, url.absoluteString.utf8.count <= 4096,
              !container.isEmpty, container.utf8.count <= 4096 else { throw PublicV2DemoError.invalidRoute }
        let value = IncomingInvitation(url: url, container: container)
        if !incomingInvitations.contains(value) {
            guard incomingInvitations.count < 16 else { throw PublicV2DemoError.busy }
            var next = incomingInvitations; next.append(value)
            let encoded = try JSONEncoder().encode(next)
            guard encoded.count <= 128 * 1024 else { throw PublicV2DemoError.busy }
            try encoded.write(to: baseURL.appendingPathComponent("incoming-invitations.json"), options: .atomic)
            incomingInvitations = next
        }
        message = "Apple invitation retained. Connect its container with the correct environment, then accept the pending invitation."
        onChange?()
    }
    func prepareNativeSharing() async throws -> GraphCloudSharingPresentation {
        guard let graph, let cloud, sharing == nil else { throw PublicV2DemoError.busy }
        let prepared = try await cloud.prepareSharing(for: graph, title: "GraphEvo Demo graph")
        sharing = prepared
        return prepared
    }
    func releaseNativeSharing() async throws {
        if let sharing { try await sharing.close(); self.sharing = nil }
    }
    func acceptPendingNativeInvitation() async throws {
        try await perform {
            guard let cloud, let pending = incomingInvitations.first else { throw PublicV2DemoError.closed }
            guard pending.container == configuredContainer else { throw PublicV2DemoError.invitationContainerMismatch }
            guard graph == nil, !FileManager.default.fileExists(atPath: storeURL.path) else { throw PublicV2DemoError.populatedReplica }
            let join = try await cloud.acceptInvitation(at: pending.url)
            let state = try await join.state
            invitations = [state]
            // Once an intent is durable, its connection journal owns restart recovery.
            let remaining = Array(incomingInvitations.dropFirst())
            try JSONEncoder().encode(remaining).write(to: baseURL.appendingPathComponent("incoming-invitations.json"), options: .atomic)
            incomingInvitations = remaining
            message = "Invitation retained: " + state.phase.rawValue + ". Choose a ready invitation to open its replica."
        }
    }
    func refreshInvitations() async throws {
        guard let cloud else { throw PublicV2DemoError.closed }
        invitations = []
        for join in try await cloud.pendingInvitations() {
            var state = try await join.state
            if [.acceptancePending, .discoveringGraph, .discarding].contains(state.phase) {
                try? await join.retry(); state = try await join.state
            }
            invitations.append(state)
        }
        onChange?()
    }
    func openSharedInvitation(_ joinID: UUID) async throws {
        try await perform {
            guard let cloud, graph == nil else { throw PublicV2DemoError.busy }
            let joins = try await cloud.pendingInvitations()
            guard let join = joins.first(where: { $0.id == joinID }), let id = try await join.state.graphID else { throw PublicV2DemoError.invalidRoute }
            let exists = FileManager.default.fileExists(atPath: storeURL.path)
            guard !exists || (workspace.sharedJoinID == joinID && workspace.graphID == id) else { throw PublicV2DemoError.populatedReplica }
            workspace.graphID = id; workspace.sharedJoinID = joinID
            try JSONEncoder().encode(workspace).write(to: descriptorURL, options: .atomic)
            try await adopt(try await cloud.openReplica(for: join, at: storeURL))
            message = "Shared replica opened. Acceptance does not certify complete import."
        }
    }
    func inspectSharing() async throws {
        guard let graph, let cloud else { throw PublicV2DemoError.closed }
        let status = try await cloud.refreshSharing(for: graph.id)
        applySharing(status)
        sharingTask?.cancel()
        sharingTask = Task { [weak self, cloud] in
            do {
                let values = try await cloud.observeSharing(for: status.graphID)
                for await value in values { guard !Task.isCancelled else { break }; self?.applySharing(value) }
            } catch { self?.recordFailure(error) }
        }
    }
    private func applySharing(_ status: GraphCloudSharingStatus) {
        sharingDescription = status.role.rawValue + " / " + status.phase.rawValue + (status.permission.map { " / " + $0.rawValue } ?? "") + (status.remoteOperationPending ? " / remote command pending" : "")
        if [.leaving, .purging, .removed].contains(status.phase) {
            notesTask?.cancel(); notes = []
        }
        onChange?()
    }
    func leaveSharing() async throws {
        guard let graph, let cloud else { throw PublicV2DemoError.closed }
        applySharing(try await cloud.leaveSharedGraph(graph))
        notesTask?.cancel(); graphTask?.cancel(); try await graph.close(); self.graph = nil
        message = "Local shared replica removed. Inspect status for a pending remote leave."; onChange?()
    }
    func stopSharing() async throws {
        guard let graph, let cloud else { throw PublicV2DemoError.closed }
        applySharing(try await cloud.stopSharing(graph))
        message = "Owner stop-sharing command recorded; owner data is retained."; onChange?()
    }
    func recordFailure(_ error: any Error) {
        let native = error as NSError
        lastIssueCode = String(native.domain.prefix(128)) + ":" + String(native.code)
        switch error {
        case GraphStoreError.accountIsolated: notes = []; message = "Local data is isolated until its account is verified."
        case GraphStoreError.readOnly, GraphStoreError.permissionDenied: message = "This graph is read-only. Ask the owner to allow changes, then refresh sharing status."
        case GraphStoreError.pendingNativeOperation: message = "A sharing operation is still pending. Refresh sharing status before switching workspace."
        case GraphStoreError.closed: message = "This graph handle is closed. Reconnect and resume its existing workspace."
        case GraphStoreError.ownershipConflict: message = "Another graph owner still reserves this identity or location. Preserve this workspace and retry after cleanup."
        case GraphStoreError.persistence(let underlying): recordFailure(underlying); return
        case GraphCloudConnectionError.operationFailed(_, let underlying): recordFailure(underlying); return
        case GraphCloudDiscoveryError.invalidInvitation: message = "Apple could not validate this invitation for the current account. Preserve it and check its sharing access."
        case GraphCloudDiscoveryError.invalidJoin: message = "This invitation cannot open the selected workspace. Resume its original invitation and workspace."
        case GraphCloudConnectionError.closed: message = "Cloud is disconnected. Reconnect using the saved configuration, then resume the invitation."
        case PublicV2DemoError.confirmationRequired: message = "Confirm that all source writers are stopped before conversion."
        case PublicV2DemoError.invalidSource: message = "Select a complete source directory and an exact SQLite filename."
        case PublicV2DemoError.invitationContainerMismatch: message = "Connect the CloudKit container used by this Apple invitation."
        case PublicV2DemoError.invalidRoute: message = "Enter the owner Graph UUID and exact private zone name."
        case PublicV2DemoError.missingNote: message = "Create a demo note before importing an attachment."
        case PublicV2DemoError.populatedReplica: message = "Use an empty workspace or resume its original replica route."
        case PublicV2DemoError.busy: message = "An operation or an existing graph already owns this workspace."
        case GraphCloudDiscoveryError.busy: message = "Cloud control is busy; retry after the current turn finishes."
        case GraphCloudDiscoveryError.graphPaused: message = "Resume synchronization for this graph before sharing."
        case GraphCloudDiscoveryError.metadataPending, GraphCloudSharingError.metadataPending: message = "Native sharing metadata is pending; retry the same operation."
        case GraphCloudDiscoveryError.invalidDescriptor, GraphCloudDiscoveryError.unsupportedDescriptor: message = "Graph identification metadata is invalid or unsupported. Preserve this workspace and use a compatible library."
        case GraphCloudConnectionError.notReady: message = "Cloud transport is not ready; check its account state."
        case GraphCloudConnectionError.invalidConfiguration: message = "Provide an entitled v2 container and its development or production environment."
        default: message = "Operation failed. Existing workspace data is preserved. Diagnostic: " + (lastIssueCode ?? "unavailable")
        }
        onChange?()
    }
    private func perform(_ body: () async throws -> Void) async throws {
        guard !isBusy else { throw PublicV2DemoError.busy }
        isBusy = true; onChange?()
        defer { isBusy = false; onChange?() }
        try await body()
    }
}
