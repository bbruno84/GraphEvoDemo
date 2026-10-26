import Foundation
import Testing
@testable import DocumentProbe

private func observationURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvo-Observation-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("probe.sqlite")
}

@MainActor
@Test func nativeFetchedResultsTracksInsertValueOrderAndDelete() async throws {
    let url = try observationURL(), probe = try await ObservationProbe.open(url), observer = try probe.observe()
    #expect(observer.latest.isEmpty)
    try await probe.write(id: "a", title: "A", rank: 2); await probe.settle()
    try await probe.write(id: "b", title: "B", rank: 1); await probe.settle()
    #expect(observer.latest.map(\.id) == ["b", "a"])
    try await probe.write(id: "a", title: "Updated", rank: 0); await probe.settle()
    #expect(observer.latest.map(\.id) == ["a", "b"])
    #expect(observer.latest.first?.title == "Updated")
    try await probe.delete(id: "a"); await probe.settle()
    #expect(observer.latest.map(\.id) == ["b"])
    observer.cancel(); try probe.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@MainActor
@Test func slowConsumerUsesBoundedLatestStateInsteadOfDurableEvents() async throws {
    let url = try observationURL(), probe = try await ObservationProbe.open(url), observer = try probe.observe(capacity: 1)
    for index in 0..<10 { try await probe.write(id: String(index), title: "Item", rank: Int64(index)); await probe.settle() }
    #expect(observer.latest.count == 10); #expect(observer.droppedBatches > 0)
    var iterator = observer.stream.makeAsyncIterator()
    let latest = try await iterator.next(); #expect(latest?.count == 10)
    print("OBSERVATION_BUFFER publications=\(observer.publicationCount) dropped=\(observer.droppedBatches)")
    observer.cancel(); try probe.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@MainActor
@Test func cancellingStreamConsumerStopsObservationAndResubscriptionFetchesCurrentState() async throws {
    let url = try observationURL(), probe = try await ObservationProbe.open(url), observer = try probe.observe()
    let stream = observer.stream
    let consumer = Task { for try await _ in stream { } }
    await Task.yield(); consumer.cancel(); _ = await consumer.result; await probe.settle()
    #expect(observer.cancelled)
    let count = observer.publicationCount
    try await probe.write(id: "later", title: "After cancellation", rank: 1); await probe.settle()
    #expect(observer.publicationCount == count)
    let replacement = try probe.observe(); #expect(replacement.latest.map(\.id) == ["later"])
    replacement.cancel(); try probe.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@MainActor
@Test func relationshipDependentMembershipIsComparedWithFreshSQL() async throws {
    let url = try observationURL(), probe = try await ObservationProbe.open(url)
    try await probe.write(id: "root", title: "Root", rank: 1)
    try await probe.write(id: "child", title: "wanted", rank: 2, parentID: "root"); await probe.settle()
    let observer = try probe.observe(childTitle: "wanted")
    #expect(observer.latest.map(\.id) == ["root"])
    try await probe.write(id: "child", title: "other", rank: 2, parentID: "root"); await probe.settle()
    for _ in 0..<25 { try await Task.sleep(nanoseconds: 10_000_000); await probe.settle() }
    let fresh = try await probe.fresh(childTitle: "wanted"); #expect(fresh.isEmpty)
    // Record native behavior rather than silently adding an invalidation workaround.
    print("OBSERVATION_RELATIONSHIP freshCount=\(fresh.count) observedCount=\(observer.latest.count) publications=\(observer.publicationCount)")
    observer.cancel(); try probe.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}
