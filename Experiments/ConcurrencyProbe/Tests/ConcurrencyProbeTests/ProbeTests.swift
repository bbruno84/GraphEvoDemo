import Foundation
import Testing
@testable import ConcurrencyProbe

private func fixture() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvo-V03-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("probe.sqlite")
}

@Test func concurrentReadModifySaveHasNoLostUpdates() async throws {
    let url = try fixture()
    let store = try await ProbeStore.open(at: url)
    let values = try await withThrowingTaskGroup(of: ProbeValue.self, returning: [ProbeValue].self) { group in
        for _ in 0..<100 { group.addTask { try await store.increment("counter") } }
        var values: [ProbeValue] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(Set(values.map(\.value)) == Set((1...100).map(Int64.init)))
    #expect(values.allSatisfy { !$0.executedOnMainThread })
    let final = try await store.value(for: "counter")
    #expect(final?.value == 100)
    try await store.close()
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func registryCoalescesCanonicalAliasesAndConcurrentOpen() async throws {
    let url = try fixture()
    let registry = ProbeRegistry()
    async let first = registry.open(at: url)
    async let second = registry.open(at: url.deletingLastPathComponent().appendingPathComponent("./probe.sqlite"))
    let (a, b) = try await (first, second)
    #expect(a === b)
    _ = try await a.increment("same")
    let value = try await b.value(for: "same")
    #expect(value?.value == 1)
    try await registry.close()
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func independentStoreOwnersDoNotCombineData() async throws {
    let aURL = try fixture(), bURL = try fixture()
    let registry = ProbeRegistry()
    let a = try await registry.open(at: aURL), b = try await registry.open(at: bURL)
    #expect(a !== b)
    _ = try await a.increment("only-A")
    let absent = try await b.value(for: "only-A")
    #expect(absent == nil)
    try await registry.close()
    try FileManager.default.removeItem(at: aURL.deletingLastPathComponent())
    try FileManager.default.removeItem(at: bURL.deletingLastPathComponent())
}

@Test func thrownOperationRollsBackAndNextOperationIsClean() async throws {
    let url = try fixture(), store = try await ProbeStore.open(at: url)
    _ = try await store.increment("counter")
    do {
        _ = try await store.increment("counter", rollback: true)
        Issue.record("A deliberate operation failure must propagate")
    } catch { #expect(error as? ProbeError == .deliberateRollback) }
    let value = try await store.value(for: "counter")
    #expect(value?.value == 1)
    let next = try await store.increment("counter")
    #expect(next.value == 2)
    try await store.close()
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func persistedValuesSurviveCloseAndNewOwner() async throws {
    let url = try fixture(), first = try await ProbeStore.open(at: url)
    _ = try await first.increment("durable")
    try await first.close()
    do { _ = try await first.increment("durable"); Issue.record("Closed owners must reject writes") }
    catch { #expect(error as? ProbeError == .closed) }
    let second = try await ProbeStore.open(at: url)
    let value = try await second.value(for: "durable")
    #expect(value?.value == 1)
    try await second.close()
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func cancellationCheckedBeforeEnqueuePreventsWrite() async throws {
    let url = try fixture(), store = try await ProbeStore.open(at: url)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await store.increment("cancelled")
    }
    do { _ = try await task.value; Issue.record("Pre-enqueue cancellation must propagate") }
    catch { #expect(error is CancellationError) }
    let value = try await store.value(for: "cancelled")
    #expect(value == nil)
    try await store.close()
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func nativePerformDoesNotAutomaticallyCancelOrRollback() async throws {
    let url = try fixture(), store = try await ProbeStore.open(at: url)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await store.increment("native", checkCancellation: false)
    }
    let result = try await task.value
    #expect(result.value == 1)
    let persisted = try await store.value(for: "native")
    #expect(persisted?.value == 1)
    try await store.close()
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func cancellationAfterDurableCommitDoesNotUndoData() async throws {
    let url = try fixture(), store = try await ProbeStore.open(at: url)
    let task = Task {
        let committed = try await store.increment("committed")
        withUnsafeCurrentTask { $0?.cancel() }
        return committed
    }
    let result = try await task.value
    #expect(task.isCancelled)
    #expect(result.value == 1)
    let persisted = try await store.value(for: "committed")
    #expect(persisted?.value == 1)
    try await store.close()
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}
