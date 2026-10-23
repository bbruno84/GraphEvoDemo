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
        session.onChange = { states.append(session.state) }
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

    func testLaunchCanEnterLaboratoryAndShowPendingExperiments() {
        let launch = LaunchViewController(style: .insetGrouped)
        let navigation = UINavigationController(rootViewController: launch)
        launch.loadViewIfNeeded()
        launch.tableView(launch.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        let laboratory = navigation.topViewController as? LaboratoryViewController
        XCTAssertNotNil(laboratory)
        laboratory?.loadViewIfNeeded()
        if let laboratory {
            for row in 3..<11 {
                let cell = laboratory.tableView(laboratory.tableView, cellForRowAt: IndexPath(row: row, section: 0))
                XCTAssertTrue(cell.detailTextLabel?.text?.hasPrefix("Not run") == true)
            }
        }
    }

    func testPlannedExperimentsRemainUnimplemented() {
        XCTAssertEqual(LaboratoryExperiment.planned.map(\.id), (1...8).map { String(format: "V%02d", $0) })
    }
}
