import Foundation
import os

nonisolated enum T6TracePhase: String, Codable, Sendable {
    case runStarted, mainActorHeartbeat, checkpointFailed
    case rootFetchStarted, rootFetchFinished
    case shareCallEntered, shareCallReturned, shareCallbackEntered, shareCallbackFailed
    case shareContinuationResumed, metadataReadStarted, metadataReadFinished
    case objectLookupStarted, objectLookupFinished
    case persistCallEntered, persistCallReturned, persistCallbackEntered
    case persistContinuationResumed, shareFinished, runFinished
    case purgeCallEntered, purgeCallReturned, purgeCallbackEntered
}

nonisolated struct T6TraceEntry: Codable, Sendable {
    let sequence: Int
    let timestamp: Date
    let phase: T6TracePhase
    let graph: String?
    let mainThread: Bool
}

/// The lock covers only bounded diagnostic file writes. It never encloses Core Data or a callback.
/// Synchronization makes this recorder usable before returning to the MainActor.
nonisolated final class T6Trace: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let logger = Logger(subsystem: "com.example.GraphEvoDemo", category: "T6Sharing")
    private var sequence = 0
    private var failures = 0
    private var dropped = 0
    private let limit: Int

    init(url: URL, limit: Int = 512) throws {
        self.limit = limit
        guard !FileManager.default.fileExists(atPath: url.path) else { throw V01Error.freshPathRequired }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    func record(_ phase: T6TracePhase, graph: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard sequence < limit else { dropped += 1; return }
        sequence += 1
        let entry = T6TraceEntry(sequence: sequence, timestamp: Date(), phase: phase,
                                 graph: graph, mainThread: Thread.isMainThread)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(entry)
            data.append(0x0A)
            try handle.write(contentsOf: data)
            logger.notice("T6 phase=\(phase.rawValue, privacy: .public) sequence=\(entry.sequence) main=\(entry.mainThread)")
        } catch {
            failures += 1
            logger.error("T6 diagnostic trace write failed")
        }
    }

    var counts: (writtenOrAttempted: Int, failures: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (sequence, failures, dropped)
    }
}
