// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConcurrencyProbe",
    platforms: [.iOS(.v16), .macOS(.v12)],
    products: [
        .library(name: "ConcurrencyProbe", targets: ["ConcurrencyProbe"]),
        .executable(name: "ConcurrencyProbeWorker", targets: ["ConcurrencyProbeWorker"])
    ],
    targets: [
        .target(name: "ConcurrencyProbe", swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
        .executableTarget(name: "ConcurrencyProbeWorker", dependencies: ["ConcurrencyProbe"],
                          swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
        .testTarget(name: "ConcurrencyProbeTests", dependencies: ["ConcurrencyProbe"])
    ],
    swiftLanguageModes: [.v6]
)
