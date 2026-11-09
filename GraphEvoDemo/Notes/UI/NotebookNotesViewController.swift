import UIKit
import GraphEvo

@MainActor private final class NotebookNoteCell: UITableViewCell {
    var representedID: GraphNodeID?
    var coverTask: Task<Void, Never>?
    override func prepareForReuse() { super.prepareForReuse(); coverTask?.cancel(); representedID = nil }
    deinit { coverTask?.cancel() }
}

@MainActor final class NotebookNotesViewController: UITableViewController {
    nonisolated private enum Row: Hashable, Sendable { case note(GraphNodeID), more }
    let session: NotebookSession
    private let application: NotesApplicationModel
    private var observation: UUID?
    private var presentation: GraphCloudSharingPresentation?
    private var source: UITableViewDiffableDataSource<Int, Row>!
    private var selectedID: GraphNodeID?
    var onSelect: ((GraphNodeID) -> Void)?
    init(application: NotesApplicationModel, session: NotebookSession) {
        self.application = application; self.session = session; super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError("Use the notebook initializer") }
    deinit {
        let session = session, token = observation
        Task { @MainActor in if let token { session.removeObserver(token) } }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(NotebookNoteCell.self, forCellReuseIdentifier: "note")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "more")
        source = UITableViewDiffableDataSource<Int, Row>(tableView: tableView) { [weak self] _, index, item in self?.cell(for: item, at: index) }
        navigationItem.rightBarButtonItems = [UIBarButtonItem(barButtonSystemItem: .compose, target: self, action: #selector(addNote)),
            UIBarButtonItem(image: UIImage(systemName: "person.crop.circle.badge.plus"), style: .plain, target: self, action: #selector(share))]
        navigationItem.rightBarButtonItems?[0].accessibilityLabel = "New note"
        navigationItem.rightBarButtonItems?[0].accessibilityUserInputLabels = ["New note", "Compose"]
        navigationItem.rightBarButtonItems?[1].accessibilityLabel = "Share notebook"
        navigationItem.rightBarButtonItems?[1].accessibilityUserInputLabels = ["Share notebook", "Share"]
        refreshControl = UIRefreshControl(); refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        observation = session.observe { [weak self] in self?.render() }; render()
    }
    func markSelected(_ id: GraphNodeID) {
        selectedID = id
        if let index = source?.indexPath(for: .note(id)) { tableView.selectRow(at: index, animated: false, scrollPosition: .none) }
    }
    private func render() {
        guard isViewLoaded, source != nil else { return }
        title = session.name
        navigationItem.prompt = session.issue ?? (session.canWrite ? nil : (session.canRead ? "Read only" : "Notebook unavailable; data preserved"))
        navigationItem.rightBarButtonItems?[0].isEnabled = session.canWrite
        navigationItem.rightBarButtonItems?[1].isEnabled = application.cloudReady && session.canRead && session.mode == .iCloud
        let old = Set(source.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>(); snapshot.appendSections([0])
        snapshot.appendItems(session.headers.map { .note($0.id) })
        if session.hasMore { snapshot.appendItems([.more]) }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { old.contains($0) })
        // Stable row identities preserve selection and assistive focus during live refresh.
        source.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, let selectedID else { return }; markSelected(selectedID)
        }
        if session.headers.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty(); empty.image = UIImage(systemName: "note.text")
            empty.text = session.canRead ? "No notes yet" : "Notebook unavailable"
            empty.secondaryText = session.canWrite ? "Create your first note." : "Waiting for available data or access."
            contentUnavailableConfiguration = empty
        } else { contentUnavailableConfiguration = nil }
    }
    private func cell(for item: Row, at index: IndexPath) -> UITableViewCell {
        guard case .note(let id) = item, let header = session.headers.first(where: { $0.id == id }) else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "more", for: index); cell.textLabel?.text = "Load more notes"; cell.accessibilityTraits.insert(.button); return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "note", for: index) as! NotebookNoteCell
        cell.coverTask?.cancel(); cell.representedID = header.id
        var configuration = cell.defaultContentConfiguration()
        configuration.text = header.displayTitle
        configuration.secondaryText = header.date.formatted(date: .abbreviated, time: .shortened)
        configuration.image = UIImage(systemName: "note.text"); configuration.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        cell.contentConfiguration = configuration; cell.accessoryType = .disclosureIndicator
        cell.isAccessibilityElement = true; cell.accessibilityTraits.insert(.button)
        cell.accessibilityLabel = "Note " + String(index.row + 1) + ", " + header.displayTitle
        cell.accessibilityValue = configuration.secondaryText
        cell.accessibilityUserInputLabels = ["Note " + String(index.row + 1), header.displayTitle]
        cell.accessibilityIdentifier = "note-" + header.id.rawValue.uuidString
        cell.coverTask = Task { [weak self, weak cell] in
            guard let self else { return }
            do {
                guard let bytes = try await session.cover(for: header.id), !Task.isCancelled,
                      cell?.representedID == header.id, let image = NotesCoverLoader.thumbnail(bytes, pixels: 160) else { return }
                var updated = cell?.contentConfiguration as? UIListContentConfiguration
                updated?.image = image; cell?.contentConfiguration = updated
            } catch { if !Task.isCancelled { navigationItem.prompt = "Some covers are unavailable; note text is preserved." } }
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) { (cell as? NotebookNoteCell)?.coverTask?.cancel() }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch source.itemIdentifier(for: indexPath) {
        case .note(let id): markSelected(id); onSelect?(id)
        case .more: Task { await session.loadMore() }
        default: break
        }
    }
    @objc private func addNote() {
        guard session.canWrite else { return }
        Task {
            do { let id = try await session.repository.createNote(); await session.refresh(); onSelect?(id) }
            catch { application.recordFailure(error); render() }
        }
    }
    @objc private func refresh() { Task { session.foreground(); await session.refresh(); refreshControl?.endRefreshing() } }
    @objc private func share() {
        Task {
            do {
                guard let cloud = application.cloud, application.cloudReady else { throw NotesError.cloudNotReady }
                if let presentation { try await presentation.close(); self.presentation = nil }
                let prepared = try await cloud.prepareSharing(for: session.store, title: session.name)
                presentation = prepared; try prepared.present(from: self)
            } catch { application.recordFailure(error); render() }
        }
    }
}
