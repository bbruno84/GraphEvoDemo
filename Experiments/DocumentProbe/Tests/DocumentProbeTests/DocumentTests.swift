import Foundation
import Testing
@testable import DocumentProbe

private func fixture() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvo-Document-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("probe.sqlite")
}
private struct ApplicationNote: DocumentModel, Equatable {
    let document: DocumentValue
    init(document: DocumentValue) throws {
        guard document.title?.isEmpty == false else { throw DocumentError.invalidValue }
        self.document = document
    }
}

@Test func applicationProtocolRoundTripPreservesIdentityAndOptionals() async throws {
    let url = try fixture(), store = try await DocumentStore.open(url)
    let note = try ApplicationNote(document: DocumentValue(id: "A-1", graph: "A", title: "Mapped", rank: 9))
    try await store.write(note)
    let returned = try await store.read("A-1", as: ApplicationNote.self)
    #expect(returned == note)
    let optional = DocumentValue(id: "A-2", graph: "A")
    try await store.write(optional)
    let nilTitle = try await store.read("A-2")
    #expect(nilTitle == optional)
    do { _ = try await store.read("A-2", as: ApplicationNote.self); Issue.record("Application decoding must fail explicitly") }
    catch { #expect(error as? DocumentError == .invalidValue) }
    try await store.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func externalBinaryAllowedRoundTripAndWholeDirectoryBackup() async throws {
    let url = try fixture(), store = try await DocumentStore.open(url)
    let bytes = Data((0..<(10 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
    let value = DocumentValue(id: "file", graph: "A", bytes: bytes, filename: "fixture.bin", contentType: "application/octet-stream")
    try await store.write(value); try await store.close()
    let backup = url.deletingLastPathComponent().appendingPathExtension("backup")
    try FileManager.default.copyItem(at: url.deletingLastPathComponent(), to: backup)
    let restored = try await DocumentStore.open(backup.appendingPathComponent(url.lastPathComponent))
    let recovered = try await restored.read("file")
    #expect(recovered == value)
    try await restored.close()
    try FileManager.default.removeItem(at: url.deletingLastPathComponent()); try FileManager.default.removeItem(at: backup)
}

@Test func binaryReplacementAndDeletionRollback() async throws {
    let url = try fixture(), store = try await DocumentStore.open(url)
    let original = DocumentValue(id: "file", graph: "A", bytes: Data(repeating: 3, count: 512), filename: "small.bin", contentType: "application/octet-stream")
    try await store.write(original)
    var replacement = original; replacement.bytes = Data(repeating: 9, count: 1024 * 1024)
    do { try await store.write(replacement, rollback: true); Issue.record("Replacement rollback must throw") }
    catch { #expect(error as? DocumentError == .rollback) }
    let unchanged = try await store.read("file"); #expect(unchanged == original)
    try await store.write(replacement)
    do { try await store.delete("file", rollback: true); Issue.record("Deletion rollback must throw") }
    catch { #expect(error as? DocumentError == .rollback) }
    let retained = try await store.read("file"); #expect(retained == replacement)
    try await store.delete("file"); let absent = try await store.read("file"); #expect(absent == nil)
    try await store.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func missingAttachmentMetadataIsADecodingError() async throws {
    let url = try fixture(), store = try await DocumentStore.open(url)
    try await store.write(DocumentValue(id: "file", graph: "A", bytes: Data([1,2,3]), filename: "a.bin", contentType: "application/octet-stream"))
    try await store.removeAttachmentMetadataForFixture("file")
    do { _ = try await store.read("file"); Issue.record("Malformed stored metadata must fail decoding") }
    catch { #expect(error as? DocumentError == .invalidAttachment) }
    try await store.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func keysetPaginationHandlesTiesAndInterveningInsert() async throws {
    let url = try fixture(), store = try await DocumentStore.open(url)
    for id in ["a", "b", "c", "d"] { try await store.write(DocumentValue(id: id, graph: "A", rank: 1)) }
    let first = try await store.page(graph: "A", limit: 2)
    #expect(first.map(\.id) == ["a", "b"])
    try await store.write(DocumentValue(id: "aa", graph: "A", rank: 1))
    let second = try await store.page(graph: "A", after: DocumentCursor(rank: 1, id: "b"), limit: 2)
    #expect(second.map(\.id) == ["c", "d"])
    // This is moving-current-state pagination: inserts before the cursor are not a frozen snapshot.
    let current = try await store.page(graph: "A")
    #expect(current.map(\.id) == ["a", "aa", "b", "c", "d"])
    try await store.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func relationshipPredicateAndSQLAggregatesStayInGraph() async throws {
    let url = try fixture(), store = try await DocumentStore.open(url)
    try await store.write(DocumentValue(id: "A-root", graph: "A", title: "Root", rank: 10))
    try await store.write(DocumentValue(id: "A-child", graph: "A", title: "Child", rank: 2, parentID: "A-root"))
    try await store.write(DocumentValue(id: "B-root", graph: "B", title: "Root", rank: 100))
    let parents = try await store.parents(graph: "A", childTitle: "Child")
    #expect(parents.map(\.id) == ["A-root"])
    let summary = try await store.summary(graph: "A")
    #expect(summary.count == 2); #expect(summary.sum == 12)
    #expect(summary.titles.map(\.id) == ["A-child", "A-root"])
    do { try await store.write(DocumentValue(id: "bad", graph: "B", parentID: "A-root")); Issue.record("Cross-graph links must be rejected by the candidate mapping") }
    catch { #expect(error as? DocumentError == .crossGraph) }
    let absent = try await store.read("bad"); #expect(absent == nil)
    try await store.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func deletingParentNullifiesTheSavedInverseRelationship() async throws {
    let url = try fixture(), store = try await DocumentStore.open(url)
    try await store.write(DocumentValue(id: "root", graph: "A"))
    try await store.write(DocumentValue(id: "child", graph: "A", parentID: "root"))
    try await store.delete("root")
    let child = try await store.read("child"); #expect(child?.parentID == nil)
    try await store.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}
