import Foundation
import CoreData
import CryptoKit
import Testing
@testable import DocumentProbe

private func recoveryURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvo-Recovery-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("probe.sqlite")
}
private func fileDigests(_ directory: URL) throws -> [String: String] {
    let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
    let items = FileManager.default.enumerator(at: canonical, includingPropertiesForKeys: [.isRegularFileKey])!
    var result: [String: String] = [:]
    for case let file as URL in items where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        // Recovery fixtures contain only a flat SQLite file family. Reject ambiguous names.
        guard result[file.lastPathComponent] == nil else { throw DocumentError.corruptRecord }
        result[file.lastPathComponent] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }
    return result
}
@MainActor
private func incompatibleModel() -> NSManagedObjectModel {
    let model = NSManagedObjectModel(), entity = NSEntityDescription(), field = NSAttributeDescription()
    entity.name = "DifferentShape"; entity.managedObjectClassName = "NSManagedObject"
    field.name = "unrelated"; field.attributeType = .integer64AttributeType; entity.properties = [field]; model.entities = [entity]
    return model
}
@MainActor
private func nativeOpenWrongModel(_ url: URL) async throws {
    let container = NSPersistentContainer(name: "WrongModelProbe", managedObjectModel: incompatibleModel())
    let description = NSPersistentStoreDescription(url: url)
    description.shouldAddStoreAsynchronously = true; description.shouldMigrateStoreAutomatically = false
    description.shouldInferMappingModelAutomatically = false; container.persistentStoreDescriptions = [description]
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        container.loadPersistentStores { _, error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
    for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
}

@MainActor
@Test func incompatibleNativeOpenIsNotAnAutomaticMigration() async throws {
    let url = try recoveryURL(), store = try await DocumentStore.open(url)
    let original = DocumentValue(id: "retained", graph: "A", title: "Original")
    try await store.write(original); try await store.close()
    let before = try fileDigests(url.deletingLastPathComponent())
    do { try await nativeOpenWrongModel(url); Issue.record("Incompatible native open unexpectedly succeeded") }
    catch { let error = error as NSError; print("RECOVERY_INCOMPATIBLE domain=\(error.domain) code=\(error.code)") }
    let after = try fileDigests(url.deletingLastPathComponent())
    print("RECOVERY_NATIVE_FILES_UNCHANGED=\(before == after) changed=\(Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted())")
    let reopened = try await DocumentStore.open(url), value = try await reopened.read("retained")
    #expect(value == original)
    try await reopened.close(); try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@MainActor
@Test func readOnlyMetadataPreflightDetectsMismatchWithoutOpeningStore() async throws {
    let url = try recoveryURL(), store = try await DocumentStore.open(url)
    try await store.write(DocumentValue(id: "retained", graph: "A")); try await store.close()
    let before = try fileDigests(url.deletingLastPathComponent())
    let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url,
        options: [NSReadOnlyPersistentStoreOption: true])
    #expect(!incompatibleModel().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata))
    let after = try fileDigests(url.deletingLastPathComponent())
    print("RECOVERY_PREFLIGHT_FILES_UNCHANGED=\(before == after) changed=\(Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted())")
    withKnownIssue("Native read-only metadata lookup changes the SQLite SHM sidecar on this runtime; this original-files guarantee remains unsatisfied.") {
        #expect(before == after)
    }
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func invalidParentPathFailsWithoutFallbackOrReplacingTheFile() async throws {
    let url = try recoveryURL(), blocked = url.deletingLastPathComponent().appendingPathComponent("not-a-directory")
    let sentinel = Data([1, 3, 5]); try sentinel.write(to: blocked)
    do { _ = try await DocumentStore.open(blocked.appendingPathComponent("probe.sqlite")); Issue.record("A file cannot be a store's parent directory") }
    catch { let error = error as NSError; print("RECOVERY_BAD_PARENT domain=\(error.domain) code=\(error.code)") }
    #expect(try Data(contentsOf: blocked) == sentinel)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@MainActor
@Test func metadataOnClosedStoreCopyPreservesEveryOriginalFile() async throws {
    let url = try recoveryURL(), store = try await DocumentStore.open(url)
    try await store.write(DocumentValue(id: "retained", graph: "A")); try await store.close()
    let originalDirectory = url.deletingLastPathComponent()
    let shadow = originalDirectory.appendingPathExtension("inspection")
    let before = try fileDigests(originalDirectory)
    try FileManager.default.copyItem(at: originalDirectory, to: shadow)
    let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
        at: shadow.appendingPathComponent(url.lastPathComponent), options: [NSReadOnlyPersistentStoreOption: true])
    #expect(!incompatibleModel().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata))
    let after = try fileDigests(originalDirectory)
    #expect(before == after)
    print("RECOVERY_CLOSED_COPY_ORIGINAL_FILES_UNCHANGED=\(before == after)")
    try FileManager.default.removeItem(at: shadow); try FileManager.default.removeItem(at: originalDirectory)
}
