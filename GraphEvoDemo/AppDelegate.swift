import UIKit
import CloudKit
import GraphEvo

@main
@MainActor class AppDelegate: UIResponder, UIApplicationDelegate {
    private(set) var notesApplication: NotesApplicationModel?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let configured = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainerIdentifier") as? String
            let container = configured.flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
            let notes = try NotesApplicationModel(root: support.appendingPathComponent("GraphEvoDemo-Notes-v1"),
                defaultContainer: container, presentationRoot: cache.appendingPathComponent("GraphEvoDemo-Notes-Presentations-v1"))
            notesApplication = notes
            Task { do { try await notes.connectRememberedCloud() } catch { notes.recordFailure(error) } }
        } catch {
            // Preserve malformed/unavailable files. Scene bootstrap presents recovery guidance.
            notesApplication = nil
        }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let notes = notesApplication, let cloud = notes.cloud,
              let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.containerIdentifier == notes.catalog.preferences?.container else { completionHandler(.noData); return }
        let nativeScope = (notification as? CKDatabaseNotification)?.databaseScope ?? (notification as? CKRecordZoneNotification)?.databaseScope
        let scope: GraphCloudScope? = nativeScope == .shared ? .shared : (nativeScope == .private ? .private : nil)
        Task {
            do {
                if let scope { try await cloud.notifyRemoteChanges(in: scope) }
                else { try await cloud.requestSynchronization() }
                // A scheduling hint does not certify that new application data was imported.
                completionHandler(.noData)
            } catch { completionHandler(.failed) }
        }
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
