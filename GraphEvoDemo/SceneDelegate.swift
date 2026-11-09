import UIKit
import CloudKit

@MainActor class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var notes: NotesSplitViewController?
    private var application: NotesApplicationModel?
    private var sceneID: String?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        sceneID = session.persistentIdentifier
        if let application = (UIApplication.shared.delegate as? AppDelegate)?.notesApplication {
            self.application = application
            let controller = NotesSplitViewController(application: application, sceneID: session.persistentIdentifier)
            notes = controller; window.rootViewController = controller
        } else {
            let controller = DemoLaunchViewController()
            controller.title = "Notes workspace unavailable"
            let navigation = UINavigationController(rootViewController: controller)
            window.rootViewController = navigation
        }
        self.window = window; window.makeKeyAndVisible()
        if let metadata = connectionOptions.cloudKitShareMetadata { retainInvitation(metadata) }
        else { notes?.restoreSelection() }
    }
    func sceneDidBecomeActive(_ scene: UIScene) { setActive(true); notes?.presentPendingInvitationIfPossible() }
    func sceneWillResignActive(_ scene: UIScene) { setActive(false) }
    func sceneDidDisconnect(_ scene: UIScene) { setActive(false) }
    private func setActive(_ active: Bool) {
        guard let application, let sceneID else { return }
        let background = active ? nil : NotesBackgroundLease()
        Task {
            defer { background?.end() }
            do { try await application.setSceneActive(sceneID, active: active) }
            catch { application.recordFailure(error) }
        }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        retainInvitation(cloudKitShareMetadata)
    }
    private func retainInvitation(_ metadata: CKShare.Metadata) {
        do {
            guard let application, let url = metadata.share.url else { throw NotesError.invalidRecord }
            // Persist the incoming capability before connection or replica creation.
            try application.retainInvitation(url: url, container: metadata.containerIdentifier)
            notes?.presentPendingInvitationIfPossible()
        } catch {
            let alert = UIAlertController(title: "Invitation unavailable", message: "The invitation could not be retained. Existing files are preserved; open the original Apple invitation again after resolving local storage availability.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default)); window?.rootViewController?.present(alert, animated: true)
        }
    }
}

/// Keep the awaited transport stop within the system's finite background allowance.
@MainActor private final class NotesBackgroundLease {
    private var token = UIBackgroundTaskIdentifier.invalid
    init() { token = UIApplication.shared.beginBackgroundTask(withName: "Notes transport lifecycle") { [weak self] in self?.end() } }
    func end() {
        guard token != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token); token = .invalid
    }
}
