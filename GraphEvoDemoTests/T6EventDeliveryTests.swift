import XCTest
import CoreData
@testable import GraphEvoDemo

@MainActor
final class T6EventDeliveryTests: XCTestCase {
    func testBackgroundNotificationPostReturnsWhileMainActorIsOccupied() {
        let center = NotificationCenter()
        let owner = NotificationOwner()
        let token = T6EventDelivery.observe(owner: owner, center: center) { _ in
            XCTFail("An empty notification must not materialize a CloudKit event")
        }
        defer { center.removeObserver(token) }
        let postReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            // NotificationCenter schedules delivery before the helper can reject empty userInfo.
            // Using OperationQueue.main would hold this post until the occupied main queue returns.
            center.post(name: NSPersistentCloudKitContainer.eventChangedNotification, object: owner)
            postReturned.signal()
        }
        XCTAssertEqual(postReturned.wait(timeout: .now() + 1), .success,
                       "Native event posting must not synchronously wait for MainActor delivery")
    }
}

// Identity-only notification filter; it has no mutable state shared between queues.
private final class NotificationOwner: NSObject, @unchecked Sendable {}
