import Foundation
import CoreData
import UIKit

struct LaboratoryExperiment {
    let id: String
    let title: String

    static let planned = [
        LaboratoryExperiment(id: "V01", title: "Cloud separation of independent graphs"),
        LaboratoryExperiment(id: "V02", title: "Sharing between separate accounts"),
        LaboratoryExperiment(id: "V03", title: "Concurrency and local transactions"),
        LaboratoryExperiment(id: "V04", title: "Typed application models"),
        LaboratoryExperiment(id: "V05", title: "Native attachments"),
        LaboratoryExperiment(id: "V06", title: "Query capability and cost"),
        LaboratoryExperiment(id: "V07", title: "Observation"),
        LaboratoryExperiment(id: "V08", title: "Lifecycle and recovery")
    ]
}

struct LaboratoryReport: Codable {
    let runID: UUID
    let experiment: String
    let started: Date
    var finished: Date?
    var outcome: String
    let environment: [String: String]
    let configuration: [String: String]
    var observations: [String]
    var cleanup: String

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// Owns only the local V00 harness check. No GraphProvider or cloud resources.
@MainActor
final class LaboratorySession {
    static let shared = LaboratorySession()
    enum State: String {
        case notRun = "Not run"
        case running = "Running"
        case passed = "Passed (local harness only)"
        case failed = "Failed"
    }

    private(set) var state: State = .notRun
    private(set) var report: LaboratoryReport?
    private(set) var reportURL: URL?
    private(set) var workspaceURL: URL?
    private(set) var message = "V01–V08 are not implemented and have not run."
    var onChange: (() -> Void)?
    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerificationLaboratory", isDirectory: true)
    }

    var canRun: Bool { state != .running && workspaceURL == nil }

    func runLocalCheck() async {
        guard canRun else { return }
        state = .running
        let runID = UUID()
        let workspace = root.appendingPathComponent("Stores/\(runID.uuidString)", isDirectory: true)
        workspaceURL = workspace
        reportURL = root.appendingPathComponent("Reports/\(runID.uuidString).json")
        report = LaboratoryReport(
            runID: runID, experiment: "V00-local-harness", started: Date(), outcome: "Running",
            environment: [
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "deviceClass": UIDevice.current.model,
                "execution": Self.executionEnvironment,
                "demoRevision": Self.buildValue("LaboratoryDemoRevision"),
                "graphEvoRevision": Self.buildValue("LaboratoryGraphEvoRevision"),
                "toolchain": Self.buildValue("LaboratoryToolchain"),
                "sourceState": Self.buildValue("LaboratorySourceState")
            ],
            configuration: ["boundary": "Direct Core Data; no GraphEvo integration",
                            "backend": "Two local SQLite stores; no CloudKit options",
                            "model": "HarnessItem-v1: optional string key",
                            "fixture": "A: A-001, A-002; B: B-001",
                            "cloudCompletion": "Not tested"],
            observations: [], cleanup: "Pending explicit cleanup")
        onChange?()
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try persistReport()
            for (name, keys) in [("A", ["A-001", "A-002"]), ("B", ["B-001"])] {
                let storeURL = workspace.appendingPathComponent("\(name).sqlite")
                try await LocalHarnessStore.write(keys, to: storeURL)
                let readBack = try await LocalHarnessStore.read(from: storeURL)
                guard readBack == keys else { throw HarnessError.fixtureMismatch }
                report?.observations.append("\(name): saved, closed, reopened; exact sorted keys verified (\(keys.count) rows).")
            }
            state = .passed
            report?.outcome = "Observed: local fixture persistence and isolation passed"
            message = "Local save and reopen verified. Cloud synchronization was not tested."
        } catch {
            state = .failed
            report?.outcome = "Inconclusive: harness failed"
            report?.observations.append("Error: \(error.localizedDescription)")
            message = "Harness failed: \(error.localizedDescription)"
        }
        report?.finished = Date()
        do { try persistReport() }
        catch {
            state = .failed
            message = "Report could not be retained: \(error.localizedDescription)"
        }
        onChange?()
    }

    /// All stores have been detached before this boundary is reachable.
    func cleanStores() throws {
        guard state != .running else { throw HarnessError.running }
        let stores = root.appendingPathComponent("Stores", isDirectory: true)
        if FileManager.default.fileExists(atPath: stores.path) {
            // Remove only UUID run directories in the laboratory's private namespace.
            for url in try FileManager.default.contentsOfDirectory(at: stores, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: url.lastPathComponent) != nil else { continue }
                try FileManager.default.removeItem(at: url)
            }
        }
        workspaceURL = nil
        report?.cleanup = "Local laboratory store directories removed; reports retained; no remote cleanup"
        try persistReport()
        message = "Temporary laboratory stores removed. Reports retained."
        onChange?()
    }

    var readableReport: String {
        guard let report, let data = try? report.encoded() else { return message }
        return String(decoding: data, as: UTF8.self)
    }

    private func persistReport() throws {
        guard let report, let reportURL else { return }
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.encoded().write(to: reportURL, options: .atomic)
    }

    private static func buildValue(_ key: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        return value.isEmpty ? "Unrecorded; supply build metadata before retaining experiment evidence" : value
    }

    private static var executionEnvironment: String {
        #if targetEnvironment(simulator)
        return "Simulator (not physical-device evidence)"
        #else
        return "Physical device"
        #endif
    }
}

private enum HarnessError: LocalizedError {
    case fixtureMismatch, running
    var errorDescription: String? {
        switch self {
        case .fixtureMismatch: return "Reopened fixture differs from expected keys."
        case .running: return "Cleanup is unavailable while the check is running."
        }
    }
}

/// This tiny model is a harness fixture, not a proposed GraphEvo 2 model.
private enum LocalHarnessStore {
    nonisolated static func write(_ keys: [String], to url: URL) async throws {
        _ = try await withStore(at: url) { context in
            for key in keys {
                let item = NSEntityDescription.insertNewObject(forEntityName: "HarnessItem", into: context)
                item.setValue(key, forKey: "key")
            }
            try context.save()
            return []
        }
    }

    nonisolated static func read(from url: URL) async throws -> [String] {
        try await withStore(at: url) { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "HarnessItem")
            request.sortDescriptors = [NSSortDescriptor(key: "key", ascending: true)]
            return try context.fetch(request).compactMap { $0.value(forKey: "key") as? String }
        }
    }

    nonisolated private static func withStore(at url: URL, body: @escaping (NSManagedObjectContext) throws -> [String]) async throws -> [String] {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        return try await context.perform {
            let model = NSManagedObjectModel()
            let entity = NSEntityDescription()
            entity.name = "HarnessItem"
            entity.managedObjectClassName = "NSManagedObject"
            let key = NSAttributeDescription()
            key.name = "key"
            key.attributeType = .stringAttributeType
            key.isOptional = true
            entity.properties = [key]
            model.entities = [entity]
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
            context.persistentStoreCoordinator = coordinator
            let result: Result<[String], Error>
            do { result = .success(try body(context)) }
            catch { result = .failure(error) }
            context.reset()
            // Detach on success and failure; retain files for explicit cleanup.
            try coordinator.remove(store)
            context.persistentStoreCoordinator = nil
            return try result.get()
        }
    }
}
