import Foundation
import GraphEvo

@MainActor
final class DeveloperViewModel: NSObject {

    private let provider: GraphProvider
    var onStatusChanged: (() -> Void)?

    init(provider: GraphProvider) {
        self.provider = provider
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(providerStateDidChange),
            name: .graphProviderStateDidChange,
            object: provider
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var readinessDescription: String { provider.readinessDescription() }
    var cloudStatusDescription: String { provider.cloudStatusDescription() }
    var isReady: Bool { provider.isReady }

    func refreshStatus() {
        onStatusChanged?()
    }

    func clearToken() {
        guard let graph = readyGraph() else { return }
        print("🧹 Developer Action: Clear Token")
        graph.ph_debug_clearToken()
    }

    func printTokenStatus() {
        guard let graph = readyGraph() else { return }
        print("📄 Developer Action: Print Token Status")
        graph.ph_debug_printTokenStatus()
    }

    func printAuthorAndContext() {
        guard let graph = readyGraph() else { return }
        print("👤 Developer Action: Print Author & Context")
        graph.ph_debug_printAuthorAndContext()
    }

    func refreshCloudKitState() {
        guard let graph = readyGraph() else { return }
        graph.cloudStatusDelegate = provider
        graph.ph_debug_printAuthorAndContext()
        graph.ph_debug_printTokenStatus()
    }

    func createCloudKitProbe() {
        guard let graph = readyGraph() else { return }

        let probe = Entity("Note", graph: graph)
        probe[dynamicMember: "title"] = "CloudKit Probe \(ISO8601DateFormatter().string(from: Date()))"
        probe[dynamicMember: "createdAt"] = Date()
        graph.sync { success, error in
            print(success
                  ? "☁️ CloudKit probe saved locally and sent for sync"
                  : "❌ CloudKit probe failed: \(error?.localizedDescription ?? "unknown error")")
        }
    }

    func createActionAndGroupProbe() {
        guard let graph = readyGraph() else { return }

        let author = Entity("User", graph: graph)
        author[dynamicMember: "name"] = "Demo Author"
        author.add(to: "demo-users")

        let note = Entity("Note", graph: graph)
        note[dynamicMember: "title"] = "Action Probe"
        note.add(tags: "probe")

        author.will(action: "reviews").add(objects: note)
        graph.sync()
        print("✅ Created Action probe with grouped author and note")
    }

    func runPredicateProbe() {
        guard let graph = readyGraph() else { return }

        let predicate = .type("Note") && .has(tags: "favorite")
        let results = Search<Entity>(graph: graph).where(predicate).sync()
        print("🔎 Predicate probe returned \(results.count) favorite notes")
    }

    func createLargeAttachment() {
        guard let graph = readyGraph() else { return }
        print("📎 Create Attachment (1.5MB)")

        let entity = Entity("Attachment", graph: graph)
        entity[dynamicMember: "title"] = "Large Attachment"
        entity[dynamicMember: "object"] = Data(repeating: 0xAA, count: 1_500_000)
        graph.sync()
    }

    func clearAllTestData() {
        guard let graph = readyGraph() else { return }
        print("🧽 Clear Notes, Attachments, Relationships")
        graph.clear()
    }

    func stressTest() {
        guard let graph = readyGraph() else { return }
        print("🚀 Starting stress test")
        clearAllTestData()

        var createdNotes = 0
        var createdAttachments = 0
        var favoriteNotes = 0
        var totalAttachmentBytes = 0

        let total = Int.random(in: 90...110)
        print("🧮 Number of notes to create: \(total)")

        for index in 1...total {
            let note = Entity("Note", graph: graph)
            note[dynamicMember: "title"] = "Stress Note \(index)"
            note[dynamicMember: "createdAt"] = Date()
            createdNotes += 1

            if Int.random(in: 1...10) == 1 {
                let attachment = Entity("Attachment", graph: graph)
                attachment[dynamicMember: "title"] = "Attachment \(index)"
                let size = Int.random(in: 1_500_000...2_000_000)
                let data = Data(repeating: 0xBB, count: size)
                attachment[dynamicMember: "object"] = data

                let relationship = Relationship("NoteAttachment", graph: graph)
                relationship.object = note
                relationship.subject = attachment
                createdAttachments += 1
                totalAttachmentBytes += data.count
            }

            if Bool.random(), Int.random(in: 0...3) == 0 {
                note.add(tags: "favorite")
                favoriteNotes += 1
            }
        }

        graph.sync()
        print("🔥 Stress test completed")
        print("📒 Notes: \(createdNotes)")
        print("🔗 Attachments: \(createdAttachments)")
        print("⭐️ Favorites: \(favoriteNotes)")
        print("📦 Attachment size: \(ByteCountFormatter.string(fromByteCount: Int64(totalAttachmentBytes), countStyle: .file))")
    }

    func dumpTestSummary() {
        guard let graph = readyGraph() else { return }

        let notes = Search<Entity>(graph: graph).where(.type("Note")).sync()
        let attachments = Search<Entity>(graph: graph).where(.type("Attachment")).sync()
        let relationships = Search<Relationship>(graph: graph).where(.type("NoteAttachment")).sync()
        let favorites = notes.filter { $0.has(tags: "favorite") }
        let totalAttachmentBytes = attachments.reduce(0) { total, entity in
            total + ((entity[dynamicMember: "object"] as? Data)?.count ?? 0)
        }

        print("📊 CURRENT STATE DUMP")
        print("📒 Total notes: \(notes.count)")
        print("🔗 NoteAttachment relationships: \(relationships.count)")
        print("⭐️ Favorite notes: \(favorites.count)")
        print("📦 Total attachment size: \(ByteCountFormatter.string(fromByteCount: Int64(totalAttachmentBytes), countStyle: .file))")
    }

    private func readyGraph() -> Graph? {
        guard let graph = provider.graphIfReady() else {
            refreshStatus()
            return nil
        }
        return graph
    }

    @objc private func providerStateDidChange() {
        refreshStatus()
    }
}
