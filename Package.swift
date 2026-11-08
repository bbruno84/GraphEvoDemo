// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The override permits local verification before the reviewed library revision is published.
let localLibrary = ProcessInfo.processInfo.environment["GRAPHEVO_DEMO_LIBRARY_PATH"]
let dependency: Package.Dependency = localLibrary.map { .package(path: $0) }
    ?? .package(url: "https://github.com/bbruno84/GraphEvo.git", revision: "0229766c9d91096eded07ee3abc904417d57b151")
let identity = localLibrary.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() } ?? "graphevo"
let package = Package(name: "PublicV2DemoModel", platforms: [.iOS("17.6"), .macOS(.v14)],
    dependencies: [dependency], targets: [
        .target(name: "PublicV2DemoModel", dependencies: [.product(name: "GraphEvo", package: identity)],
                path: "GraphEvoDemo/PublicV2", exclude: ["PublicV2ViewController.swift", "DemoLaunchViewController.swift"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "NotesDemoModel", dependencies: [.product(name: "GraphEvo", package: identity)],
                path: "GraphEvoDemo/Notes/Model", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "NotesDemoModelTests", dependencies: ["NotesDemoModel"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "PublicV2DemoModelTests", dependencies: ["PublicV2DemoModel"], swiftSettings: [.swiftLanguageMode(.v6)])])
