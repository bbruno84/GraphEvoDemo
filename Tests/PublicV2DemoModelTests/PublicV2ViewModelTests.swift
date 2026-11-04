import Foundation
import Testing
import GraphEvo
@testable import PublicV2DemoModel

@MainActor @Suite struct PublicV2ViewModelTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("PublicV2Demo-" + UUID().uuidString) }

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
        await #expect(throws: GraphStoreError.self) { try await model.open() }
        #expect(!FileManager.default.fileExists(atPath: previous.appendingPathComponent("Graph.sqlite").path))
        try await model.create(); try await model.addNote(); try await model.newWorkspace()
        #expect(model.directory != previous)
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
