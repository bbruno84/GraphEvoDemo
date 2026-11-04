import Foundation
import Testing
import GraphEvo
@testable import PublicV2DemoModel

@MainActor @Suite struct PublicV2ViewModelTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("PublicV2Demo-" + UUID().uuidString) }

    @Test func cloudPreferencesSurviveRestartAndWorkspaceChangesWithoutOpeningTransport() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try PublicV2ViewModel(baseURL: root, defaultContainer: "iCloud.example.bundled")
        #expect(model.suggestedCloudContainer == "iCloud.example.bundled")
        try model.rememberCloudConfiguration(container: " iCloud.example.saved ", environment: .production)
        try await model.newWorkspace()
        let reopened = try PublicV2ViewModel(baseURL: root)
        #expect(reopened.suggestedCloudContainer == "iCloud.example.saved")
        #expect(reopened.suggestedCloudEnvironment == .production)
        #expect(reopened.cloudState == nil)
        try reopened.stageNativeInvitation(url: URL(string: "https://www.icloud.com/share/fixture")!, container: "iCloud.example.invited")
        #expect(reopened.suggestedCloudContainer == "iCloud.example.invited")
        #expect(reopened.suggestedCloudEnvironment == .development)
        #expect(reopened.cloudPreferences?.container == "iCloud.example.saved")
    }
    @Test func invalidCloudPreferencesDoNotOverwriteSavedConfiguration() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try PublicV2ViewModel(baseURL: root)
        try model.rememberCloudConfiguration(container: "iCloud.example.valid", environment: .development)
        #expect(throws: (any Error).self) { try model.rememberCloudConfiguration(container: "  ", environment: .production) }
        #expect(throws: (any Error).self) { try model.rememberCloudConfiguration(container: String(repeating: "x", count: 4097), environment: .production) }
        let reopened = try PublicV2ViewModel(baseURL: root)
        #expect(reopened.cloudPreferences == model.cloudPreferences)
    }

    @Test func corruptCloudSettingsDoNotBlockLocalOpeningOrEraseExistingFiles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try PublicV2ViewModel(baseURL: root)
        try await first.create(); try await first.addNote(); try await first.close()
        let settings = root.appendingPathComponent("cloud-preferences.json"), corrupt = Data([0, 1, 2])
        try corrupt.write(to: settings)
        let second = try PublicV2ViewModel(baseURL: root)
        #expect(second.cloudPreferences == nil)
        #expect(second.message.contains("Local workspace is available"))
        try await second.open()
        #expect(second.notes.count == 1 && second.cloudState == nil)
        #expect(try Data(contentsOf: settings) == corrupt)
        try await second.close()
    }

    @Test func copiedSupportStatusExcludesInvitationURLsAndErrorPayloads() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try PublicV2ViewModel(baseURL: root)
        let url = URL(string: "https://www.icloud.com/share/private-capability")!
        try model.stageNativeInvitation(url: url, container: "iCloud.example.fixture")
        model.recordFailure(NSError(domain: "Fixture", code: 7, userInfo: [NSLocalizedDescriptionKey: "private-error-payload"]))
        #expect(model.supportSummary.contains("Fixture:7"))
        #expect(!model.supportSummary.contains(url.absoluteString))
        #expect(!model.supportSummary.contains("private-error-payload"))
    }

    @Test func reopeningKeepsTheWorkspaceIdentityAndLocalNotes() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try PublicV2ViewModel(baseURL: root)
        let id = first.graphID, directory = first.directory
        try await first.create(); try await first.addNote()
        #expect(first.notes.count == 1)
        try await first.close()
        let descriptor = try Data(contentsOf: directory.appendingPathComponent("workspace.json"))
        let second = try PublicV2ViewModel(baseURL: root)
        #expect(second.graphID == id && second.directory == directory)
        #expect(try Data(contentsOf: directory.appendingPathComponent("workspace.json")) == descriptor)
        try await second.open()
        #expect(second.notes.count == 1)
        try await second.close()
    }

    @Test func accountIsolationClearsDetachedPresentationValuesImmediately() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try PublicV2ViewModel(baseURL: root)
        try await model.create(); try await model.addNote()
        #expect(!model.notes.isEmpty)
        model.applyAccountState(.isolated(.differentAccount))
        #expect(model.notes.isEmpty && !model.canRead)
        try await model.close()
    }

    @Test func openingMissingStoreDoesNotCreateOneAndNewWorkspacePreservesOldFiles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try PublicV2ViewModel(baseURL: root), previous = model.directory
        let previousContext = model.context
        await #expect(throws: GraphStoreError.self) { try await model.open() }
        #expect(!FileManager.default.fileExists(atPath: previous.appendingPathComponent("Graph.sqlite").path))
        try await model.create(); try await model.addNote(); try await model.newWorkspace()
        #expect(model.directory != previous)
        #expect(model.context !== previousContext)
        #expect(FileManager.default.fileExists(atPath: previous.appendingPathComponent("Graph.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: model.directory.appendingPathComponent("Graph.sqlite").path))
        #expect(model.notes.isEmpty)
    }

    @Test func conversionNeedsStoppedWriterConfirmationAndAnExactSourceFilename() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try PublicV2ViewModel(baseURL: root)
        await #expect(throws: PublicV2DemoError.self) {
            try await model.convertV1(sourceDirectory: root, sqliteName: "Source.sqlite", stoppedWritersConfirmed: false)
        }
        await #expect(throws: PublicV2DemoError.self) {
            try await model.convertV1(sourceDirectory: root, sqliteName: "../Source.sqlite", stoppedWritersConfirmed: true)
        }
        #expect(!FileManager.default.fileExists(atPath: model.directory.appendingPathComponent("Graph.sqlite").path))
    }

    @Test func duplicateOpenDoesNotReplaceTheLiveGraph() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try PublicV2ViewModel(baseURL: root)
        try await model.create(); try await model.addNote()
        await #expect(throws: PublicV2DemoError.self) { try await model.open() }
        try await model.refreshNotes()
        #expect(model.notes.count == 1)
        try await model.close()
    }
    @Test func anotherFeatureUpdatesTheNotesObservationWithoutSharingItsHandle() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try PublicV2ViewModel(baseURL: root)
        try await model.create()
        let feature = try await model.context.openGraph(id: model.graphID, at: model.directory.appendingPathComponent("Graph.sqlite"))
        try await feature.insert(PublicV2Note(title: "Independent feature"))
        for _ in 0..<1000 {
            if model.notes.contains(where: { $0.title == "Independent feature" }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.notes.map(\.title) == ["Independent feature"])
        try await feature.close(); try await model.close()
    }

    @Test func droppingTheViewModelCancelsObserversAndClosesItsLeases() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var model: PublicV2ViewModel? = try PublicV2ViewModel(baseURL: root)
        let id = model!.graphID, url = model!.directory.appendingPathComponent("Graph.sqlite")
        try await model!.create()
        weak var weakModel = model
        model = nil
        #expect(weakModel == nil)
        let next = GraphContext()
        var reopened: GraphStore?
        for _ in 0..<1000 {
            do { reopened = try await next.openGraph(id: id, at: url); break }
            catch GraphStoreError.ownershipConflict { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(reopened != nil)
        try await reopened?.close()
    }

    @Test func nativeInvitationsSurviveRestartWithoutTouchingAnExistingGraph() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try PublicV2ViewModel(baseURL: root)
        try await first.create(); try await first.addNote()
        let url = URL(string: "https://www.icloud.com/share/demo")!
        try first.stageNativeInvitation(url: url, container: "iCloud.demo")
        try first.stageNativeInvitation(url: url, container: "iCloud.demo")
        #expect(first.incomingInvitations.count == 1)
        let graphID = first.graphID
        try await first.close()
        let second = try PublicV2ViewModel(baseURL: root)
        #expect(second.incomingInvitations.count == 1 && second.graphID == graphID)
        try await second.open(); #expect(second.notes.count == 1)
        try await second.newWorkspace()
        #expect(second.incomingInvitations.count == 1)
        #expect(throws: PublicV2DemoError.self) { try second.stageNativeInvitation(url: URL(string: "http://invalid.example")!, container: "iCloud.demo") }
        try await second.close()
    }
}
