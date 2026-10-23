import XCTest
import CoreData
@testable import GraphEvoDemo

@MainActor
final class V01PreflightTests: XCTestCase {
    func testDuplicateCloudDestinationIsRejectedButDescriptionsWithoutCloudOptionsAreValid() throws {
        let descriptions = cloudDescriptions()
        XCTAssertThrowsError(try V01CloudStore.validateCloudDestinations(descriptions)) { error in
            XCTAssertTrue(error is V01ConfigurationError)
        }
        for description in descriptions { description.cloudKitContainerOptions = nil }
        XCTAssertNoThrow(try V01CloudStore.validateCloudDestinations(descriptions))
    }

    func testGuardMatchesBothIdentifierAndScopeWithoutRunningOtherTopologies() throws {
        let distinctScopes = cloudDescriptions()
        distinctScopes[1].cloudKitContainerOptions?.databaseScope = .shared
        XCTAssertNoThrow(try V01CloudStore.validateCloudDestinations(distinctScopes))
        let distinctIdentifiers = cloudDescriptions()
        distinctIdentifiers[1].cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.example.other")
        XCTAssertNoThrow(try V01CloudStore.validateCloudDestinations(distinctIdentifiers))
        // These are pure guard checks. Neither configuration is opened or proposed as a workaround.
    }

    func testCloudGuardRejectsBeforeConstructingMirrorOwner() async throws {
        var ownerConstructionCount = 0
        let owner = V01CloudStore(makeCloudOwner: { _ in
            ownerConstructionCount += 1
            throw CocoaError(.featureUnsupported)
        })
        do {
            try await owner.open(stores: locations(), containerIdentifier: "iCloud.example.test", event: { _ in XCTFail("No native operation expected") })
            XCTFail("Known duplicate destination must be rejected")
        } catch { XCTAssertTrue(error is V01ConfigurationError) }
        XCTAssertEqual(ownerConstructionCount, 0)
        XCTAssertTrue(owner.loadResults.isEmpty)
        try await owner.close()
    }

    func testReportDistinguishesApplicationPreflightFromPriorNativeException() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var ownerConstructionCount = 0
        let store = V01CloudStore(makeCloudOwner: { _ in
            ownerConstructionCount += 1
            throw CocoaError(.featureUnsupported)
        })
        let session = V01Session(root: root, permitSimulatorForTests: true, makeStore: { store }, accountAvailable: { _ in true })
        await session.run(role: "t1-writer", runID: UUID(), containerIdentifier: "iCloud.example.test", developmentVerified: true, windowSeconds: 0)
        XCTAssertEqual(session.report?.topologyObservation, .preflightRejected)
        XCTAssertTrue(session.report?.outcome.hasPrefix("Preflight rejected (not a new native trial):") == true)
        XCTAssertTrue(session.report?.localSaveCompleted == false)
        XCTAssertTrue(session.report?.nativeEvents.isEmpty == true)
        XCTAssertNotNil(session.report?.finished)
        XCTAssertTrue(session.finalReportRetained)
        XCTAssertEqual(ownerConstructionCount, 0)
    }

    private func locations() -> [V01StoreLocation] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return [V01StoreLocation(key: "A", url: root.appendingPathComponent("A.sqlite")),
                V01StoreLocation(key: "B", url: root.appendingPathComponent("B.sqlite"))]
    }

    private func cloudDescriptions() -> [NSPersistentStoreDescription] {
        V01CloudStore.descriptions(stores: locations(), containerIdentifier: "iCloud.example.test")
    }
}
