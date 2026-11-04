// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The override permits local verification before the reviewed library revision is published.
let localLibrary = ProcessInfo.processInfo.environment["GRAPHEVO_DEMO_LIBRARY_PATH"]
let dependency: Package.Dependency = localLibrary.map { .package(path: $0) }
    ?? .package(url: "https://github.com/bbruno84/GraphEvo.git", revision: "e9ac88efaa943c2fe6db981cd81b2d8601891f07")
let identity = localLibrary.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() } ?? "graphevo"
let package = Package(name: "PublicV2DemoModel", platforms: [.iOS("17.6"), .macOS(.v14)],
    dependencies: [dependency], targets: [
        .target(name: "PublicV2DemoModel", dependencies: [.product(name: "GraphEvo", package: identity)],
                path: "GraphEvoDemo/PublicV2", exclude: ["PublicV2ViewController.swift", "DemoLaunchViewController.swift"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "PublicV2DemoModelTests", dependencies: ["PublicV2DemoModel"], swiftSettings: [.swiftLanguageMode(.v6)])])
