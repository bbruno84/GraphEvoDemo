import UIKit
import GraphEvo

@MainActor final class NotesSplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    let application: NotesApplicationModel
    private let sceneID: String
    private let notebooks: NotebooksViewController
    private var notebookID: UUID?
    private var noteID: GraphNodeID?
    private var notes: NotebookNotesViewController?
    private var editor: NotesEditorViewController?
    private var observation: UUID?
    private var selectionGeneration = UUID()
    private var invitationRetry: Task<Void, Never>?
    private var activeInvitation: NotesInvitation?
    private var waitingToRestoreCloudSelection = false
    init(application: NotesApplicationModel, sceneID: String) {
        self.application = application; self.sceneID = sceneID
        notebooks = NotebooksViewController(application: application)
        super.init(style: .tripleColumn)
        delegate = self; preferredDisplayMode = .twoBesideSecondary
        minimumPrimaryColumnWidth = 240; maximumPrimaryColumnWidth = 340
        minimumSupplementaryColumnWidth = 260; maximumSupplementaryColumnWidth = 400
        preferredPrimaryColumnWidthFraction = 0.28; preferredSupplementaryColumnWidthFraction = 0.32
        setViewController(UINavigationController(rootViewController: notebooks), for: .primary)
        setViewController(UINavigationController(rootViewController: empty("Choose a notebook", symbol: "folder")), for: .supplementary)
        setViewController(UINavigationController(rootViewController: empty("Choose a note", symbol: "note.text")), for: .secondary)
        notebooks.onSelect = { [weak self] id in Task { await self?.selectNotebook(id) } }
        observation = application.observe { [weak self] in self?.applicationChanged() }
    }
    deinit {
        invitationRetry?.cancel()
        let application = application, token = observation, invitation = activeInvitation
        Task { @MainActor in
            if let token { application.removeObserver(token) }
            if let invitation { application.finishInvitationPrompt(invitation, deferUntilNextLaunch: false) }
        }
    }
    required init?(coder: NSCoder) { fatalError("Use the injected application initializer") }
    private func empty(_ title: String, symbol: String) -> UIViewController {
        let controller = UIViewController(); controller.view.backgroundColor = .systemBackground
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: symbol); configuration.text = title
        controller.contentUnavailableConfiguration = configuration; return controller
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentPendingInvitationIfPossible()
    }
    func presentPendingInvitationIfPossible() {
        guard invitationRetry == nil, application.hasPromptableInvitation,
              viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else { return }
        guard !hasPresentedController(self) else {
            // A form or native picker must finish before another modal is shown.
            invitationRetry = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                self?.invitationRetry = nil
                self?.presentPendingInvitationIfPossible()
            }
            return
        }
        guard let invitation = application.claimInvitationPrompt() else { return }
        activeInvitation = invitation
        let alert = UIAlertController(title: "Shared notebook invitation",
            message: "Accept this invitation to connect to iCloud and add the shared notebook? You can also accept it later in Settings.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Later", style: .cancel) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) {
                self?.activeInvitation = nil
                self?.application.finishInvitationPrompt(invitation, deferUntilNextLaunch: true)
            }
        })
        alert.addAction(UIAlertAction(title: "Accept", style: .default) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) {
                guard let self else { return }
                Task {
                    defer {
                        self.activeInvitation = nil
                        self.application.finishInvitationPrompt(invitation, deferUntilNextLaunch: true)
                    }
                    do {
                        if let id = try await self.application.acceptInvitation(invitation) { await self.selectNotebook(id) }
                    } catch { self.application.recordFailure(error); self.showInvitations() }
                }
            }
        })
        present(alert, animated: true)
    }
    private func hasPresentedController(_ controller: UIViewController) -> Bool {
        controller.presentedViewController != nil || controller.children.contains { hasPresentedController($0) }
    }
    func showInvitations() {
        selectionGeneration = UUID()
        show(.primary)
        if let navigation = viewController(for: .primary) as? UINavigationController {
            navigation.popToRootViewController(animated: false)
            navigation.pushViewController(NotesSettingsViewController(application: application), animated: false)
        }
    }
    func restoreSelection() {
        let values = UserDefaults.standard.stringArray(forKey: "NotesSelection." + sceneID) ?? []
        guard let first = values.first, let id = UUID(uuidString: first),
              let entry = application.notebooks.first(where: { $0.id == id }) else { return }
        if (entry.mode == .shared || entry.creating || entry.recovering), entry.mode != .local, !application.cloudReady {
            waitingToRestoreCloudSelection = true
            return
        }
        waitingToRestoreCloudSelection = false
        Task {
            await selectNotebook(id, showColumn: false)
            guard notebookID == id else { return }
            if values.count == 2, let note = UUID(uuidString: values[1]), let session = notes?.session {
                await selectNote(GraphNodeID(graphID: session.store.id, rawValue: note), session: session, showColumn: false)
            }
            if editor != nil { show(.secondary) }
            else if notes != nil { show(.supplementary) }
        }
    }
    private func saveSelection() {
        guard let notebookID else { UserDefaults.standard.removeObject(forKey: "NotesSelection." + sceneID); return }
        var value = [notebookID.uuidString]
        if let noteID { value.append(noteID.rawValue.uuidString) }
        UserDefaults.standard.set(value, forKey: "NotesSelection." + sceneID)
    }
    private func applicationChanged() {
        presentPendingInvitationIfPossible()
        if waitingToRestoreCloudSelection, application.cloudReady { restoreSelection() }
        guard let notebookID else { return }
        guard let entry = application.notebooks.first(where: { $0.id == notebookID }), !entry.deleting, !entry.leaving else {
            selectionGeneration = UUID(); editor?.retire(); editor = nil; notes = nil; self.notebookID = nil; noteID = nil; saveSelection()
            setViewController(UINavigationController(rootViewController: empty("Choose a notebook", symbol: "folder")), for: .supplementary)
            setViewController(UINavigationController(rootViewController: empty("Choose a note", symbol: "note.text")), for: .secondary)
            show(.primary); return
        }
        if notes?.session.closed == true {
            selectionGeneration = UUID(); editor?.retire(); editor = nil; notes = nil; self.notebookID = nil; noteID = nil; saveSelection()
            setViewController(UINavigationController(rootViewController: empty("Choose a notebook", symbol: "folder")), for: .supplementary)
            setViewController(UINavigationController(rootViewController: empty("Choose a note", symbol: "note.text")), for: .secondary)
            show(.primary)
        }
    }
    func selectNotebook(_ id: UUID, showColumn: Bool = true) async {
        waitingToRestoreCloudSelection = false
        let generation = UUID(); selectionGeneration = generation
        do {
            let session = try await application.openNotebook(id)
            guard !Task.isCancelled, selectionGeneration == generation else { return }
            editor?.retire(); editor = nil; noteID = nil; notebookID = id; notebooks.markSelected(id); saveSelection()
            let controller = NotebookNotesViewController(application: application, session: session)
            controller.onSelect = { [weak self, weak session] note in
                guard let session else { return }
                Task { await self?.selectNote(note, session: session) }
            }
            notes = controller
            setViewController(UINavigationController(rootViewController: controller), for: .supplementary)
            setViewController(UINavigationController(rootViewController: empty("Choose a note", symbol: "note.text")), for: .secondary)
            if showColumn { show(.supplementary) }
        } catch { application.recordFailure(error) }
    }
    private func selectNote(_ id: GraphNodeID, session: NotebookSession, showColumn: Bool = true) async {
        let generation = UUID(); selectionGeneration = generation
        do {
            guard session.canRead, let note = try await session.repository.note(id),
                  let entry = application.notebooks.first(where: { $0.id == session.entryID && !$0.deleting && !$0.leaving }) else { throw NotesError.missingNote }
            guard selectionGeneration == generation, notebookID == session.entryID,
                  notes?.session === session, session.canRead else { return }
            editor?.retire()
            let model = try NoteEditor(note: note, repository: session.repository, draftURL: application.catalog.draftURL(for: entry, note: id, sceneID: sceneID))
            let controller = NotesEditorViewController(application: application, session: session, editor: model)
            controller.onDeleted = { [weak self] in
                guard let self else { return }
                self.editor = nil; self.noteID = nil; self.saveSelection()
                self.setViewController(UINavigationController(rootViewController: self.empty("Choose a note", symbol: "note.text")), for: .secondary)
                self.show(.supplementary)
            }
            editor = controller; noteID = id; notes?.markSelected(id); saveSelection()
            setViewController(UINavigationController(rootViewController: controller), for: .secondary)
            if showColumn { show(.secondary) }
        } catch { application.recordFailure(error) }
    }
    func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        editor != nil ? .secondary : (notes != nil ? .supplementary : .primary)
    }
}
