import UIKit
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import GraphEvo

@MainActor final class NotesEditorViewController: UITableViewController, UITextFieldDelegate, UITextViewDelegate,
    PHPickerViewControllerDelegate, UIDocumentPickerDelegate, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    private let application: NotesApplicationModel
    private let session: NotebookSession
    private let editor: NoteEditor
    private let titleField = UITextField()
    private let bodyField = UITextView()
    private let dateLabel = UILabel()
    private let statusLabel = UILabel()
    private let coverView = UIImageView()
    private var files: [GraphFile] = []
    private var previewURL: URL?
    private var observation: UUID?
    private var operationBusy = false
    private var retired = false
    private var detailGeneration = UUID()
    var onDeleted: (() -> Void)?
    init(application: NotesApplicationModel, session: NotebookSession, editor: NoteEditor) {
        self.application = application; self.session = session; self.editor = editor; super.init(style: .insetGrouped)
    }
    deinit {
        let session = session, token = observation
        Task { @MainActor in if let token { session.removeObserver(token) } }
    }
    required init?(coder: NSCoder) { fatalError("Use the note initializer") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Note"
        titleField.font = .preferredFont(forTextStyle: .title2); titleField.adjustsFontForContentSizeCategory = true
        titleField.placeholder = "Title"; titleField.delegate = self; titleField.returnKeyType = .next
        titleField.accessibilityLabel = "Note title"; titleField.accessibilityIdentifier = "noteTitle"
        titleField.addTarget(self, action: #selector(titleChanged), for: .editingChanged)
        bodyField.font = .preferredFont(forTextStyle: .body); bodyField.adjustsFontForContentSizeCategory = true; bodyField.delegate = self
        bodyField.accessibilityLabel = "Note content"; bodyField.accessibilityIdentifier = "noteContent"
        dateLabel.font = .preferredFont(forTextStyle: .caption1); dateLabel.adjustsFontForContentSizeCategory = true
        statusLabel.font = .preferredFont(forTextStyle: .footnote); statusLabel.numberOfLines = 0; statusLabel.adjustsFontForContentSizeCategory = true
        coverView.contentMode = .scaleAspectFit; coverView.accessibilityLabel = "Note cover"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(deleteNote))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Delete note"
        editor.onChange = { [weak self] in self?.render() }
        observation = session.observe { [weak self] in self?.sessionChanged() }
        render(); reloadDetails()
    }
    func retire() {
        retired = true; detailGeneration = UUID(); editor.retire(); titleField.text = ""; bodyField.text = ""; coverView.image = nil; files = []
        if let presentedViewController { presentedViewController.dismiss(animated: false) }
        releasePreview(); if isViewLoaded { tableView.reloadData() }
    }
    private func sessionChanged() {
        guard !retired else { return }
        guard !session.closed else { retire(); return }
        editor.setWritable(session.canWrite)
        if !session.canRead {
            detailGeneration = UUID(); coverView.image = nil; files = []
            if let presentedViewController { presentedViewController.dismiss(animated: false) }
            releasePreview(); render(); tableView.reloadData()
        } else {
            Task { await editor.reload() }; reloadDetails()
        }
    }
    private func render() {
        guard isViewLoaded else { return }
        let readable = session.canRead && !session.closed && !retired
        let title = readable ? editor.title : "", body = readable ? editor.content : ""
        if titleField.text != title { titleField.text = title }
        if bodyField.text != body {
            let selection = bodyField.selectedRange
            bodyField.text = body
            bodyField.selectedRange = NSRange(location: min(selection.location, (body as NSString).length), length: 0)
        }
        dateLabel.text = readable ? editor.date.formatted(date: .complete, time: .shortened) : ""
        titleField.isEnabled = session.canWrite && editor.canEdit && !operationBusy
        bodyField.isEditable = session.canWrite && editor.canEdit && !operationBusy
        navigationItem.rightBarButtonItem?.isEnabled = session.canWrite && editor.canEdit && !operationBusy
        if !readable { statusLabel.text = "This notebook is unavailable. Its data and draft are preserved."; return }
        let message: String
        switch editor.state {
        case .saved: message = "Saved on this device"
        case .pending: message = "Changes waiting to save…"
        case .saving: message = "Saving…"
        case .draftNeedsReview: message = "A retained draft needs your approval. Tap to review."
        case .conflict: message = "This note changed elsewhere. Tap to resolve the conflicting fields."
        case .deleted: message = "This note was deleted. Your draft is retained and will not recreate it."
        case .suspended: message = "Editing is suspended. A retained draft will need your approval before resuming."
        case .failed(let reason): message = reason + " Tap to retry."
        }
        let next = session.canWrite ? message : "Read only. " + message
        let changed = statusLabel.text != next
        statusLabel.text = next
        let actionable = session.canWrite && (editor.state == .conflict || editor.state == .draftNeedsReview || {
            if case .failed = editor.state { return true }; return false
        }())
        statusLabel.accessibilityTraits = actionable ? .button : .staticText
        if changed, tableView.cellForRow(at: IndexPath(row: 3, section: 0)) != nil {
            UIView.performWithoutAnimation { tableView.beginUpdates(); tableView.endUpdates() }
        }
    }
    private func reloadDetails() {
        let token = UUID(); detailGeneration = token
        Task {
            do {
                let files = try await session.repository.files(note: editor.id)
                let cover = try await session.repository.cover(editor.id)
                guard token == detailGeneration, session.canRead, !retired else { return }
                self.files = files; coverView.image = cover.flatMap { NotesCoverLoader.thumbnail($0, pixels: 480) }
                tableView.reloadSections(IndexSet([1, 2]), with: .none)
            } catch {
                guard token == detailGeneration else { return }
                navigationItem.prompt = "Some documents or the cover are unavailable. Existing content is preserved."
            }
        }
    }
    @objc private func titleChanged() { editor.edit(.title, value: titleField.text ?? "") }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { bodyField.becomeFirstResponder(); return false }
    func textViewDidChange(_ textView: UITextView) { editor.edit(.content, value: textView.text) }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 4 : (section == 1 ? 2 : files.count + 1) }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? nil : (section == 1 ? "Cover" : "Documents") }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section == 0 && indexPath.row == 1 { return 260 }
        if indexPath.section == 1 && indexPath.row == 0 { return coverView.image == nil ? 44 : 160 }
        return UITableView.automaticDimension
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let control: UIView?
        if indexPath.section == 0 { control = [titleField, bodyField, dateLabel, statusLabel][indexPath.row] }
        else if indexPath.section == 1, indexPath.row == 0 { control = coverView.image == nil ? nil : coverView }
        else { control = nil }
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false; cell.contentView.addSubview(control)
            NSLayoutConstraint.activate([control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                control.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                control.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8)])
        } else if indexPath.section == 1 {
            cell.textLabel?.text = indexPath.row == 0 ? "No cover" : "Choose or remove cover"
            cell.imageView?.image = UIImage(systemName: "photo")
        } else if indexPath.section == 2 {
            if indexPath.row < files.count {
                let file = files[indexPath.row]
                cell.textLabel?.text = file.name; cell.detailTextLabel?.text = file.byteCount.formatted(.byteCount(style: .file))
                cell.imageView?.image = UIImage(systemName: "doc"); cell.accessoryType = .disclosureIndicator
            } else { cell.textLabel?.text = "Add document"; cell.imageView?.image = UIImage(systemName: "paperclip") }
        }
        if indexPath.section == 0, indexPath.row == 3 {
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        if (indexPath.section == 1 && indexPath.row == 1) || indexPath.section == 2 {
            cell.isAccessibilityElement = true; cell.accessibilityLabel = cell.textLabel?.text
            cell.accessibilityValue = cell.detailTextLabel?.text; cell.accessibilityTraits.insert(.button)
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            if indexPath.section == 2, indexPath.row < files.count, session.canWrite {
                let file = files[indexPath.row]
                cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Delete document") { [weak self] _ in
                    guard let self else { return false }
                    run { try await self.session.repository.deleteFile(file.id, note: self.editor.id) }; return true
                }]
            }
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard session.canRead, !operationBusy else { return }
        if indexPath.section == 0, indexPath.row == 3 { reviewState(); return }
        if indexPath.section == 1, indexPath.row == 1, session.canWrite { chooseCover(); return }
        if indexPath.section == 2 {
            if indexPath.row < files.count { preview(files[indexPath.row]) }
            else if session.canWrite {
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
                picker.allowsMultipleSelection = true; picker.delegate = self; present(picker, animated: true)
            }
        }
    }
    private func reviewState() {
        guard session.canWrite else { return }
        if editor.state == .conflict, let field = editor.conflicts.sorted(by: { $0.rawValue < $1.rawValue }).first {
            let alert = UIAlertController(title: field == .title ? "Resolve title changes" : "Resolve content changes", message: "Choose which value to keep for this field. Other fields are preserved.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Keep mine", style: .default) { [weak self] _ in self?.editor.resolve(field, keepingMine: true) })
            alert.addAction(UIAlertAction(title: "Use latest", style: .default) { [weak self] _ in self?.editor.resolve(field, keepingMine: false) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
        } else if editor.state == .draftNeedsReview {
            let alert = UIAlertController(title: "Retained draft", message: "Resume your draft, or discard it and use the saved note.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Resume draft", style: .default) { [weak self] _ in self?.editor.resumeDraft() })
            alert.addAction(UIAlertAction(title: "Discard draft", style: .destructive) { [weak self] _ in
                do { try self?.editor.discardDraft() } catch { self?.application.recordFailure(error) }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
        } else { Task { await editor.saveNow() } }
    }
    private func chooseCover() {
        let alert = UIAlertController(title: "Note cover", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Choose photo", style: .default) { [weak self] _ in
            guard let self else { return }
            var config = PHPickerConfiguration(); config.filter = .images; config.selectionLimit = 1
            let picker = PHPickerViewController(configuration: config); picker.delegate = self; present(picker, animated: true)
        })
        alert.addAction(UIAlertAction(title: "Remove cover", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.run { try await self.session.repository.setCover(nil, note: self.editor.id) }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = view; alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(alert, animated: true)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard session.canWrite, let provider = results.first?.itemProvider else { return }
        run {
            let data = try await NotesCoverLoader.load(provider)
            try await self.session.repository.setCover(data, note: self.editor.id)
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard session.canWrite else { return }
        run {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.identifier ?? UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data"
                _ = try await self.session.repository.importDocument(url, note: self.editor.id, contentType: type)
            }
        }
    }
    private func preview(_ file: GraphFile) {
        guard !operationBusy, !retired, previewURL == nil else { return }
        operationBusy = true; render()
        Task {
            defer { operationBusy = false; render() }
            do {
                let url = try await application.presentations.prepare(file, in: session.store)
                guard session.canRead, !session.closed, !retired, viewIfLoaded?.window != nil else { try application.presentations.release(url); return }
                previewURL = url
                let controller = QLPreviewController(); controller.dataSource = self; controller.delegate = self
                present(controller, animated: true)
            } catch { application.recordFailure(error); navigationItem.prompt = "This document is not available yet. Retry after synchronization." }
        }
    }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { previewURL! as NSURL }
    func previewControllerDidDismiss(_ controller: QLPreviewController) { releasePreview() }
    private func releasePreview() {
        guard let url = previewURL else { return }
        do { try application.presentations.release(url); previewURL = nil }
        catch { application.recordFailure(error) }
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 2, indexPath.row < files.count, session.canWrite else { return nil }
        let file = files[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            run { try await self.session.repository.deleteFile(file.id, note: self.editor.id) }; completion(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
    @objc private func deleteNote() {
        guard session.canWrite else { return }
        let alert = UIAlertController(title: "Delete note?", message: "Delete this note, its cover, all linked documents and this scene's retained draft.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            run {
                try await self.session.repository.deleteNote(self.editor.id)
                try self.editor.acknowledgeDeletion()
                self.onDeleted?()
            }
        })
        present(alert, animated: true)
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !operationBusy, session.canWrite else { return }
        operationBusy = true; render()
        Task {
            do { try await operation() } catch { application.recordFailure(error); navigationItem.prompt = application.issue }
            operationBusy = false; render(); if !retired { reloadDetails() }
        }
    }
}
