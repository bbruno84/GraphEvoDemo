//
//  GraphProvider.swift
//  GraphEvoDemo
//
//  Created by GraphEvoDemo contributors.
//


import Foundation
import GraphEvo

extension Notification.Name {
    static let graphProviderStateDidChange = Notification.Name("GraphEvoDemo.graphProviderStateDidChange")
}

final class GraphProvider: NSObject, GraphCloudStatusDelegate, GraphEventDelegate {
    
    static private(set) var wasInitialized = false
    static let shared = GraphProvider()
    private(set) var graph: Graph
    private(set) var readiness: GraphReadiness
    private(set) var cloudStatus: GraphCloudStatus = .unavailable
    private(set) var lastError: GraphStoreOpeningError?
    private(set) var lastEventDescription: String?

    private override init() {
        Self.wasInitialized = true
        // Must match the container enabled in entitlements and the Developer
        // Portal. Xcode/account selects the CloudKit environment.
        let configuredContainer = Bundle.main.object(forInfoDictionaryKey: "GraphEvoDemoCloudKitContainer") as? String ?? ""
        Graph.cloudKitContainerIdentifier = configuredContainer.isEmpty ? nil : configuredContainer

        var configuration = GraphStoreConfiguration()
        configuration.name = "Main"
        configuration.cloudKitContainerIdentifier = Graph.cloudKitContainerIdentifier
        graph = Graph(configuration: configuration)
        readiness = graph.readiness
        super.init()
        graph.cloudStatusDelegate = self
        graph.eventDelegate = self
        graph.whenReady { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.readiness = .ready
                self.lastError = nil
                // Persistent History must be prepared after the persistent
                // container has loaded its store and before remote changes
                // can be delivered to the demo's watchers.
                self.graph.ph_prepareOnLaunchAfterContainerReady()
                print("✅ GraphEvoDemo graph ready: \(self.graph.location.path)")
            case .failure(let error):
                self.readiness = .failed(error)
                self.lastError = error
                print("❌ GraphEvoDemo graph not ready: \(error.localizedDescription)")
            }
            self.publishStateChange()
        }
    }

    var isReady: Bool {
        if case .ready = readiness { return true }
        return false
    }

    func graphIfReady() -> Graph? {
        guard isReady else {
            print("⏳ GraphEvoDemo: graph is not ready yet")
            return nil
        }
        return graph
    }

    func graph(_ graph: Graph, iCloudStatusChanged status: GraphCloudStatus) {
        cloudStatus = status
        let description = cloudStatusDescription()
            print("☁️ GraphEvoDemo \(description)")
        publishStateChange()
    }

    func graph(_ graph: Graph, didReceive event: GraphEvent) {
        lastEventDescription = String(describing: event)
        print("📣 GraphEvo event: \(lastEventDescription ?? "unknown")")
        if case .stateChanged(.cloudImport(.finished(let event))) = event {
            self.graph(graph, didCompleteCloudImport: event)
        }
        publishStateChange()
    }

    func graph(_ graph: Graph, didCompleteCloudImport event: GraphCloudImportEvent) {
        let result = event.succeeded ? "succeeded" : "failed"
        print("☁️ CloudKit import \(result) for \(event.storeIdentifier)")
        if let error = event.error {
            print("❌ CloudKit import error: \(error.localizedDescription)")
        }
        publishStateChange()
    }

    func readinessDescription() -> String {
        switch readiness {
        case .initializing: return "Graph: opening"
        case .ready: return "Graph: ready"
        case .failed(let error): return "Graph: error — \(error.localizedDescription)"
        }
    }

    func cloudStatusDescription() -> String {
        switch cloudStatus {
        case .available: return "CloudKit: account available"
        case .unavailable: return "CloudKit: account unavailable"
        }
    }

    private func publishStateChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .graphProviderStateDidChange, object: self)
        }
    }
}
