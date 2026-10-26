// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConcurrencyProbe",
    platforms: [.macOS(.v12)],
    products: [.library(name: "ConcurrencyProbe", targets: ["ConcurrencyProbe"])],
    targets: [
        .target(name: "ConcurrencyProbe", swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
        .testTarget(name: "ConcurrencyProbeTests", dependencies: ["ConcurrencyProbe"])
    ],
    swiftLanguageModes: [.v6]
)
