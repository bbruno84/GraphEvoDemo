import Foundation
import GraphEvo

nonisolated enum NoteField: String, Codable, Sendable, CaseIterable { case title, content }
nonisolated struct NoteDraft: Codable, Sendable {
    let noteID: GraphNodeID
    let title: String
    let content: String
    let baselines: [NoteField: String]
    let dirty: Set<NoteField>
}
nonisolated struct NoteEditConflict: Error, Sendable { let latest: Note }

/// Scene-owned draft. Only changed fields are patched, against current native state.
@MainActor final class NoteEditor {
    enum State: Equatable { case saved, pending, saving, draftNeedsReview, conflict, deleted, suspended, failed(String) }
    let id: GraphNodeID
    let date: Date
    private(set) var title: String
    private(set) var content: String
    private(set) var state: State = .saved
    private(set) var dirty: Set<NoteField> = []
    private(set) var conflicts: Set<NoteField> = []
    private var baselines: [NoteField: String]
    private var latest: Note
    private let repository: NotesRepository
    private let draftURL: URL
    private let delay: Duration
    private var timer: Task<Void, Never>?
    private var saving = false
    private var deleted = false
    private var retired = false
    private var writable = true
    private var draftNeedsReview = false
    var canEdit: Bool { writable && !deleted && !retired }
    var onChange: (() -> Void)?

    init(note: Note, repository: NotesRepository, draftURL: URL, delay: Duration = .milliseconds(750)) throws {
        id = note.graphNodeID(in: repository.store.id); date = note.date; title = note.title; content = note.content
        baselines = [.title: note.title, .content: note.content]; latest = note
        self.repository = repository; self.draftURL = draftURL; self.delay = delay
        if FileManager.default.fileExists(atPath: draftURL.path) {
            let bytes = try Data(contentsOf: draftURL)
            guard bytes.count <= 32 * 1024 * 1024 else { throw NotesError.invalidRecord }
            let draft = try JSONDecoder().decode(NoteDraft.self, from: bytes)
            guard draft.noteID == id, Set(draft.baselines.keys) == Set(NoteField.allCases) else { throw NotesError.invalidRecord }
            title = draft.title; content = draft.content; baselines = draft.baselines; dirty = draft.dirty
            if !dirty.isEmpty { draftNeedsReview = true; state = .draftNeedsReview }
        }
    }
    deinit { timer?.cancel() }
    func value(_ field: NoteField) -> String { field == .title ? title : content }
    private func set(_ value: String, for field: NoteField) {
        if field == .title { title = value } else { content = value }
    }
    private func value(_ field: NoteField, in note: Note) -> String { field == .title ? note.title : note.content }
    func edit(_ field: NoteField, value: String) {
        guard writable, !deleted, !retired else { return }
        set(value, for: field)
        if value == baselines[field] { dirty.remove(field); conflicts.remove(field) } else { dirty.insert(field) }
        do { try persistDraft() } catch { state = .failed("The draft could not be saved on this device."); onChange?(); return }
        schedule(); onChange?()
    }
    private func persistDraft() throws {
        if dirty.isEmpty {
            if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
        } else {
            try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let draft = NoteDraft(noteID: id, title: title, content: content, baselines: baselines, dirty: dirty)
            try JSONEncoder().encode(draft).write(to: draftURL, options: .atomic)
        }
    }
    private func updateState() {
        if deleted { state = .deleted }
        else if retired || !writable { state = .suspended }
        else if !conflicts.isEmpty { state = .conflict }
        else if draftNeedsReview { state = .draftNeedsReview }
        else if saving { state = .saving }
        else { state = dirty.isEmpty ? .saved : .pending }
    }
    private func schedule() {
        timer?.cancel(); updateState()
        guard writable, !draftNeedsReview, !deleted, !retired, conflicts.isEmpty, !dirty.isEmpty else { return }
        let delay = delay
        timer = Task { [weak self] in
            do { try await Task.sleep(for: delay); guard !Task.isCancelled else { return }; await self?.saveNow() }
            catch { }
        }
    }
    func reload() async {
        guard !deleted, !retired else { return }
        do { receive(try await repository.note(id)) }
        catch { state = .failed("The current note could not be read. Your draft is retained."); onChange?() }
    }
    func receive(_ note: Note?) {
        guard let note else { deleted = true; timer?.cancel(); state = .deleted; writable = false; onChange?(); return }
        if saving { return }
        latest = note
        for field in NoteField.allCases {
            let remote = value(field, in: note)
            if dirty.contains(field) {
                if remote != baselines[field] && remote != value(field) { conflicts.insert(field) }
            } else { set(remote, for: field); baselines[field] = remote }
        }
        if !conflicts.isEmpty { timer?.cancel() }
        updateState(); onChange?()
    }
    /// Explicit approval is required before a retained draft can resume after reopening.
    func resumeDraft() {
        guard writable, !deleted, !retired else { return }
        draftNeedsReview = false; receive(latest); schedule(); onChange?()
    }
    func resolve(_ field: NoteField, keepingMine: Bool) {
        guard conflicts.contains(field) else { return }
        let remote = value(field, in: latest)
        baselines[field] = remote; conflicts.remove(field)
        if !keepingMine { set(remote, for: field); dirty.remove(field) }
        do { try persistDraft(); schedule() }
        catch { state = .failed("The conflict choice could not be saved. Your text is retained.") }
        onChange?()
    }
    func discardDraft() throws {
        timer?.cancel(); dirty = []; conflicts = []; draftNeedsReview = false
        title = latest.title; content = latest.content; baselines = [.title: title, .content: content]
        try persistDraft(); state = writable ? .saved : .suspended; onChange?()
    }
    func setWritable(_ allowed: Bool) {
        guard !deleted, !retired, writable != allowed else { return }
        writable = allowed
        if !allowed { timer?.cancel(); if !dirty.isEmpty { draftNeedsReview = true } }
        updateState(); onChange?()
    }
    func acknowledgeDeletion() throws {
        deleted = true; writable = false; timer?.cancel(); updateState(); onChange?()
        if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
    }
    func retire() {
        retired = true; writable = false; timer?.cancel(); state = .suspended; onChange?()
    }
    func saveNow() async {
        guard !saving, writable, !deleted, !retired, !draftNeedsReview, conflicts.isEmpty, !dirty.isEmpty else { return }
        saving = true; state = .saving; onChange?()
        let fields = dirty, baseline = baselines, id = id
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0, value($0)) })
        do {
            let saved: Note = try await repository.store.transaction { scope in
                guard let current = try scope.fetch(id, as: Note.self) else { throw NotesError.missingNote }
                for field in fields {
                    let currentValue = field == .title ? current.title : current.content
                    guard currentValue == baseline[field] || currentValue == values[field] else { throw NoteEditConflict(latest: current) }
                }
                let changes = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, GraphPropertyChange.set(.string($0.value))) })
                return try scope.patch(GraphRecordPatch(id: id, properties: changes), as: Note.self)
            }
            guard !retired, !deleted else { saving = false; updateState(); onChange?(); return }
            latest = saved
            for field in fields {
                baselines[field] = field == .title ? saved.title : saved.content
                if value(field) == values[field] { dirty.remove(field) }
            }
            try persistDraft()
            state = dirty.isEmpty ? .saved : .pending
        } catch let conflict as NoteEditConflict { saving = false; receive(conflict.latest); state = .conflict }
        catch NotesError.missingNote { deleted = true; state = .deleted; writable = false; timer?.cancel() }
        catch { state = .failed("The note could not be saved. Your draft is retained; retry when access is available.") }
        saving = false
        if deleted || retired || !writable { updateState() }
        if state == .saved || state == .pending {
            await reload()
            if state == .pending { schedule() }
        }
        onChange?()
    }
}
