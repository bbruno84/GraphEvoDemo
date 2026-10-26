import XCTest
import UIKit
@testable import GraphEvoDemo

@MainActor
final class LaboratoryTests: XCTestCase {
    func testLocalHarnessRetainsEvidenceAndCleansOnlyStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LaboratorySession(root: root)
        var states: [LaboratorySession.State] = []
        let token = session.observeChanges { states.append(session.state) }
        defer { session.removeObserver(token) }
        XCTAssertEqual(session.state, .notRun)
        await session.runLocalCheck()
        XCTAssertEqual(states, [.running, .passed])
        XCTAssertFalse(session.canRun)
        let workspace = try XCTUnwrap(session.workspaceURL)
        let reportURL = try XCTUnwrap(session.reportURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("A.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("B.sqlite").path))
        XCTAssertEqual(session.report?.observations.count, 2)
        XCTAssertEqual(session.report?.configuration["cloudCompletion"], "Not tested")
        XCTAssertEqual(session.report?.experiment, "V00-local-harness")
        XCTAssertEqual(session.shareableReportURL, reportURL)
        XCTAssertEqual(try session.completedReportURLs(), [reportURL])

        // A second run must not replace an uncleaned workspace or its report.
        await session.runLocalCheck()
        XCTAssertEqual(session.workspaceURL, workspace)
        let interrupted = root.appendingPathComponent("Stores/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        let unrelated = root.appendingPathComponent("Stores/keep-this")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try session.cleanStores()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
        XCTAssertTrue((json["cleanup"] as? String)?.contains("reports retained") == true)
        XCTAssertTrue(session.canRun)
        await session.runLocalCheck()
        XCTAssertNotEqual(session.workspaceURL, workspace)
        XCTAssertEqual(session.state, .passed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        try session.cleanStores()
    }

    func testFailureIsVisibleWhenWorkspaceCannotBeCreated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("blocking file".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LaboratorySession(root: root)
        await session.runLocalCheck()
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(session.report?.outcome.contains("Inconclusive") == true)
        XCTAssertTrue(session.message.contains("Report could not be retained"))
        XCTAssertFalse(session.canRun)
    }

    func testTwoConsumersReceiveChangesUntilIndividuallyRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LaboratorySession(root: root)
        var firstStates: [LaboratorySession.State] = []
        var secondStates: [LaboratorySession.State] = []
        let first = session.observeChanges { firstStates.append(session.state) }
        let second = session.observeChanges { secondStates.append(session.state) }
        await session.runLocalCheck()
        XCTAssertEqual(firstStates, [.running, .passed])
        XCTAssertEqual(secondStates, [.running, .passed])

        session.removeObserver(first)
        try session.cleanStores()
        await session.runLocalCheck()
        XCTAssertEqual(firstStates, [.running, .passed])
        XCTAssertEqual(secondStates, [.running, .passed, .passed, .running, .passed])
        session.removeObserver(second)
        try session.cleanStores()
        XCTAssertEqual(secondStates.count, 5)
    }

    func testFinalWriteFailureMakesMemoryInconclusiveAndExcludesInitialFileFromSharing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var writes = 0
        var rejectedOutcome: String?
        let session = LaboratorySession(root: root) { data, url in
            writes += 1
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if writes == 2 {
                rejectedOutcome = json["outcome"] as? String
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        }
        await session.runLocalCheck()
        XCTAssertEqual(writes, 2)
        XCTAssertTrue(rejectedOutcome?.hasPrefix("Observed:") == true)
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(session.report?.outcome.hasPrefix("Inconclusive:") == true)
        XCTAssertTrue(session.readableReport.contains("final report could not be retained"))
        XCTAssertEqual(session.report?.observations.filter { $0.contains("exact sorted keys verified") }.count, 2)
        XCTAssertNotNil(session.report?.finished)
        XCTAssertNil(session.shareableReportURL)
        XCTAssertTrue(try session.completedReportURLs().isEmpty)

        // The initial atomic write still exists; it must not be offered as a final result,
        // including after a new session is created for the same report directory.
        let url = try XCTUnwrap(session.reportURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["outcome"] as? String, "Running")
        XCTAssertNil(json["finished"])
        XCTAssertTrue(try LaboratorySession(root: root).completedReportURLs().isEmpty)

        // A later successful cleanup can retain the explicitly inconclusive report.
        try session.cleanStores()
        XCTAssertEqual(session.shareableReportURL, url)
        XCTAssertEqual(try session.completedReportURLs(), [url])
        let retained = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertTrue((retained["outcome"] as? String)?.hasPrefix("Inconclusive:") == true)
    }

    func testLaunchCanEnterLaboratoryAndShowPendingExperiments() {
        let launch = LaunchViewController(style: .insetGrouped)
        let navigation = UINavigationController(rootViewController: launch)
        launch.loadViewIfNeeded()
        launch.tableView(launch.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        let laboratory = navigation.topViewController as? LaboratoryViewController
        XCTAssertNotNil(laboratory)
        laboratory?.loadViewIfNeeded()
        if let laboratory {
            let v02 = laboratory.tableView(laboratory.tableView, cellForRowAt: IndexPath(row: 4, section: 0))
            XCTAssertTrue(v02.detailTextLabel?.text?.contains("smoke instrumented via CLI") == true)
            for row in 5..<11 {
                let cell = laboratory.tableView(laboratory.tableView, cellForRowAt: IndexPath(row: row, section: 0))
                XCTAssertTrue(cell.detailTextLabel?.text?.hasPrefix("Not run") == true)
            }
        }
    }

    func testCatalogDistinguishesInitialInstrumentationFromPlannedExperiments() {
        XCTAssertEqual(LaboratoryExperiment.catalog.map(\.id), (1...8).map { String(format: "V%02d", $0) })
        XCTAssertEqual(LaboratoryExperiment.catalog.filter(\.hasInstrumentation).map(\.id), ["V01", "V02"])
    }
}
