import XCTest
@testable import GraphEvoDemo

final class T6TraceTests: XCTestCase {
    func testSequentialPhasesRetainOrderAndGraphWithoutPayload() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let trace = try T6Trace(url: url)
        let phases: [T6TracePhase] = [.shareCallEntered, .shareCallReturned, .shareCallbackEntered,
                                    .shareContinuationResumed, .metadataReadStarted, .metadataReadFinished]
        for phase in phases { trace.record(phase, graph: "A") }
        let entries = try read(url)
        XCTAssertEqual(entries.map(\.sequence), Array(1...phases.count))
        XCTAssertEqual(entries.map(\.phase), phases)
        XCTAssertTrue(entries.allSatisfy { $0.graph == "A" })
        XCTAssertEqual(trace.counts.writtenOrAttempted, phases.count)
        XCTAssertEqual(trace.counts.failures, 0)
        let lines = try Data(contentsOf: url).split(separator: 0x0A)
        for line in lines {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(["sequence", "timestamp", "phase", "graph", "mainThread"]))
        }
    }

    func testConcurrentAppendsProduceCompleteOrderedJSONLinesAndBoundDrops() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let trace = try T6Trace(url: url, limit: 40)
        DispatchQueue.concurrentPerform(iterations: 120) { index in
            trace.record(.shareCallbackEntered, graph: index.isMultiple(of: 2) ? "A" : "B")
        }
        let entries = try read(url)
        XCTAssertEqual(entries.count, 40)
        XCTAssertEqual(entries.map(\.sequence), Array(1...40))
        XCTAssertTrue(entries.allSatisfy { $0.phase == .shareCallbackEntered })
        XCTAssertEqual(trace.counts.writtenOrAttempted, 40)
        XCTAssertEqual(trace.counts.dropped, 80)
        XCTAssertEqual(trace.counts.failures, 0)
        trace.record(.mainActorHeartbeat)
        XCTAssertEqual(trace.counts.dropped, 81)
        XCTAssertEqual(try read(url).count, 40)
    }

    func testExistingTraceIsRejectedWithoutOverwritingEvidence() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let evidence = Data("retained evidence\n".utf8)
        try evidence.write(to: url)
        XCTAssertThrowsError(try T6Trace(url: url)) { error in
            XCTAssertTrue(error is V01Error)
        }
        XCTAssertEqual(try Data(contentsOf: url), evidence)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("trace.jsonl")
    }
    private func read(_ url: URL) throws -> [T6TraceEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try Data(contentsOf: url).split(separator: 0x0A).map {
            try decoder.decode(T6TraceEntry.self, from: Data($0))
        }
    }
}
