import Foundation
import Testing
import GraphEvo
@testable import NotesDemoModel

@MainActor @Suite(.timeLimit(.minutes(1)))
struct NotesCloudInteractionTests {
    @Test func automaticConnectionChoosesRememberedProfileOrBundledDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesPreferences-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try NotesApplicationModel(root: root, defaultContainer: "iCloud.bundled")
        #expect(app.automaticCloudPreferences() == NotesCloudPreferences(container: "iCloud.bundled", environment: .development))
        try app.catalog.rememberCloud(container: "iCloud.remembered", environment: .production)
        #expect(app.automaticCloudPreferences() == NotesCloudPreferences(container: "iCloud.remembered", environment: .production))
        let invitation = NotesInvitation(url: URL(string: "https://www.icloud.com/share/fixture")!, container: "iCloud.invitation")
        #expect(app.automaticCloudPreferences(for: invitation) == NotesCloudPreferences(container: "iCloud.invitation", environment: .production))
        #expect(app.catalog.preferences?.container == "iCloud.remembered")
    }
    @Test func missingCloudConfigurationDoesNotPreventLocalCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesNoCloud-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try NotesApplicationModel(root: root)
        #expect(app.automaticCloudPreferences() == nil)
        try await app.connectAutomatically()
        let session = try await app.createNotebook(name: "Local", mode: .local)
        #expect(app.cloud == nil)
        #expect(try await session.repository.notebookName() == "Local")
        try await session.close()
    }
    @Test func invitationPromptIsExclusiveAcrossScenesAndLaterRetainsItForRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesInvitations-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try NotesApplicationModel(root: root)
        let url = URL(string: "https://www.icloud.com/share/fixture")!
        try app.retainInvitation(url: url, container: "iCloud.fixture")
        let invitation = try #require(app.claimInvitationPrompt())
        #expect(app.claimInvitationPrompt() == nil)
        app.finishInvitationPrompt(invitation, deferUntilNextLaunch: true)
        #expect(app.claimInvitationPrompt() == nil)
        #expect(app.catalog.invitations == [invitation] && app.catalog.preferences == nil && app.cloud == nil)
        let restarted = try NotesApplicationModel(root: root)
        #expect(restarted.claimInvitationPrompt() == invitation)
        try app.retainInvitation(url: url, container: "iCloud.fixture")
        #expect(app.claimInvitationPrompt() == invitation)
    }
    @Test func closingOneSceneMakesItsUnansweredInvitationAvailableToAnother() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesInvitationScenes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try NotesApplicationModel(root: root)
        try app.retainInvitation(url: URL(string: "https://www.icloud.com/share/fixture")!, container: "iCloud.fixture")
        let invitation = try #require(app.claimInvitationPrompt())
        app.finishInvitationPrompt(invitation, deferUntilNextLaunch: false)
        #expect(app.claimInvitationPrompt() == invitation)
    }
}
