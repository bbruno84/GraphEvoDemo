import Foundation
import CoreData

@MainActor
enum T6EventDelivery {
    static func observe(owner: AnyObject, center: NotificationCenter = .default,
                        receive: @escaping @MainActor (V01NativeEvent) -> Void) -> NSObjectProtocol {
        // Core Data may wait for a request while posting an event from its own queue.
        // A main-queue observer would make the post wait on the caller, forming a cycle.
        center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                           object: owner, queue: nil) { notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let kind: String
            switch event.type {
            case .setup: kind = "setup"
            case .import: kind = "import"
            case .export: kind = "export"
            @unknown default: kind = "unknown"
            }
            let snapshot = V01NativeEvent(identifier: event.identifier, kind: kind, started: event.startDate,
                                          finished: event.endDate, succeeded: event.succeeded,
                                          storeIdentifier: event.storeIdentifier, error: event.error.map(v01ErrorCode))
            // UI/report ownership remains on MainActor, after returning to the native posting queue.
            Task { @MainActor in receive(snapshot) }
        }
    }
}
