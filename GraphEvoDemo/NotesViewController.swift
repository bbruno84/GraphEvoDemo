import UIKit
import GraphEvo

final class NotesViewController: UIViewController {

    private let viewModel = NotesViewModel(provider: GraphProvider.shared)
    private var tableView: UITableView!
    private let reuseIdentifier = "NoteCell"
    private let refreshControl = UIRefreshControl()

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Notes"
        view.backgroundColor = .systemBackground
        configureTableView()
        configureNavBar()

        viewModel.onNotesChanged = { [weak self] in
            self?.tableView.reloadData()
        }
        viewModel.start()
        print("🧩 NotesViewController viewDidLoad completed. Frame: \(view.frame)")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if UIDevice.current.userInterfaceIdiom == .pad {
            navigationController?.navigationBar.prefersLargeTitles = true
            navigationItem.largeTitleDisplayMode = .always
        } else {
            navigationController?.navigationBar.prefersLargeTitles = false
            navigationItem.largeTitleDisplayMode = .never
        }

        viewModel.refresh()
    }

    private func configureTableView() {
        tableView = UITableView(frame: view.bounds)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        refreshControl.addTarget(self, action: #selector(refreshNotes), for: .valueChanged)
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)
    }

    private func configureNavBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addNote)
        )
    }

    @objc private func refreshNotes() {
        viewModel.refresh()
        refreshControl.endRefreshing()
    }

    @objc private func addNote() {
        viewModel.addNote()
    }
}

extension NotesViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView,
                   numberOfRowsInSection section: Int) -> Int {
        viewModel.notes.count
    }

    func tableView(_ tableView: UITableView,
                   cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let note = viewModel.notes[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifier, for: indexPath)
        let title = note[dynamicMember: "title"] as? String ?? "Untitled"
        let isFavorite = note.has(tags: "favorite")
        cell.textLabel?.text = title + (isFavorite ? " ★" : "")
        return cell
    }
}

extension NotesViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView,
                   didSelectRowAt indexPath: IndexPath) {
        let note = viewModel.notes[indexPath.row]
        let detailVC = NoteDetailViewController(note: note)
        let nav = UINavigationController(rootViewController: detailVC)
        present(nav, animated: true)
        tableView.deselectRow(at: indexPath, animated: true)
    }

    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            viewModel.deleteNote(at: indexPath.row)
        }
    }
}
