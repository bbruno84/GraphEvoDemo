// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DocumentProbe", platforms: [.macOS(.v12)],
    products: [.library(name: "DocumentProbe", targets: ["DocumentProbe"])],
    targets: [.target(name: "DocumentProbe", swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
              .testTarget(name: "DocumentProbeTests", dependencies: ["DocumentProbe"])],
    swiftLanguageModes: [.v6])
