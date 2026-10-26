import ConcurrencyProbe
import Foundation

@main
struct ConcurrencyProbeWorker {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              let count = Int(arguments[2]), (0...10_000).contains(count),
              !arguments[3].isEmpty else {
            fputs("usage: ConcurrencyProbeWorker <store.sqlite> <count> <key>\n", stderr)
            exit(64)
        }
        do {
            let store = try await ProbeStore.open(at: URL(fileURLWithPath: arguments[1]))
            var last: ProbeValue?
            for _ in 0..<count { last = try await store.increment(arguments[3]) }
            try await store.close()
            print("completed=\(count) last=\(last?.value ?? 0)")
        } catch {
            fputs("operation failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
