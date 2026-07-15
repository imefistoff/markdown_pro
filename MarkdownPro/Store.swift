import Foundation
import SwiftUI
import MarkdownProCore

/// Single source of truth for the UI. Wraps the shared Repository and
/// polls SQLite's data_version so writes made by the MCP server
/// (Claude Code) show up in the app within ~1.5 seconds.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var tasks: [TaskItem] = []
    @Published var errorMessage: String?
    /// Set when another view asks the reader to open a file.
    @Published var pendingReaderURL: URL?
    /// Which modal the app is showing, if any. Set by the File menu and the
    /// sidebar context menu; consumed by ContentView.
    @Published var activeSheet: ActiveSheet?
    @Published private(set) var reviewQueue: [Repository.ReviewQueueItem] = []
    /// One-shot in-app notification ("Proposal ready: …").
    @Published var toast: String?
    /// Project ids that have a repo path set — gates the Launch button's enabled state.
    @Published private(set) var launchableProjects: Set<Int64> = []

    /// Review-doc ids seen by the last refresh; nil until the first load
    /// so launch never toasts.
    private var knownReviewDocIds: Set<Int64>?

    enum ActiveSheet: Identifiable {
        case export(preselected: Set<Int64>)
        case importBundle(ImportPreview, URL)
        case projectSettings(Int64)
        case launch(LaunchRequest)

        var id: String {
            switch self {
            case .export: return "export"
            case .importBundle(_, let url): return "import:\(url.path)"
            case .projectSettings(let id): return "settings:\(id)"
            case .launch(let req): return "launch:\(req.script.taskId)"
            }
        }
    }

    struct LaunchRequest {
        let script: LaunchScript
        let taskTitle: String
        let warpAvailable: Bool
    }

    private(set) var repo: Repository?
    private let launcher: TerminalLauncher = WarpLauncher()
    private var lastDataVersion: Int64 = 0
    private var timer: Timer?

    /// The folder both Macs point at (Dropbox/Syncthing/etc.). Persisted.
    @Published private(set) var syncFolderPath: String?
    @Published private(set) var adoptable: [SyncEngine.AdoptableProject] = []
    private var syncEngine: SyncEngine?
    private var syncDebounce: Timer?
    private var isSyncing = false
    private let syncFolderKey = "MarkdownProSyncFolder"
    private let syncTransportKey = "MarkdownProSyncTransport"   // "folder" | "github"
    private let ghOwnerKey = "MarkdownProGitHubOwner"
    private let ghRepoKey = "MarkdownProGitHubRepo"
    @Published private(set) var syncTargetLabel: String?

    init() {
        do {
            let db = try Database.open()
            let repo = Repository(db: db)
            self.repo = repo
            lastDataVersion = db.dataVersion()
            if try repo.listProjects(includeArchived: true).isEmpty {
                try seedFirstRun(repo)
            }
            refresh()
        } catch {
            errorMessage = "Could not open database: \(error)"
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollForExternalChanges()
            }
        }
        loadSyncEngine()
        syncNow() // launch
        // Sync is synchronous on the main actor (see `syncNow()`), so the quit
        // hook can just call it directly and let the app terminate right after.
        SyncQuitHook.shared = { [weak self] in
            self?.syncNow()
        }
    }

    /// A tiny starter project so the very first launch isn't a blank screen.
    private func seedFirstRun(_ repo: Repository) throws {
        let projectId = try repo.createProject(name: "Getting Started", color: "#5E6AD2")
        try repo.createTask(projectId: projectId,
                            title: "Connect Claude Code via MCP",
                            details: "Run the command from the README, then ask Claude to `list_projects`.",
                            status: .todo, priority: .high,
                            labels: ["setup"],
                            subtasks: ["Build mcp-server with swift build",
                                       "claude mcp add markdownpro",
                                       "Ask Claude to create a task"])
        try repo.createTask(projectId: projectId,
                            title: "Open a markdown folder in the reader",
                            details: "Sidebar → Documents → Add Folder. Try the bundled `docs/samples`.",
                            status: .todo, priority: .medium,
                            labels: ["setup"])
        try repo.createTask(projectId: projectId,
                            title: "Drag this card to Done",
                            status: .inProgress, priority: .low)
    }

    private func pollForExternalChanges() {
        guard let repo else { return }
        let version = repo.db.dataVersion()
        if version != lastDataVersion {
            lastDataVersion = version
            refresh()
            scheduleDebouncedSync()
        }
    }

    func refresh() {
        guard let repo else { return }
        do {
            projects = try repo.listProjects()
            tasks = try repo.listTasks()
            let queue = try repo.reviewQueue()
            if let known = knownReviewDocIds,
               let fresh = queue.first(where: { !known.contains($0.id) }) {
                toast = "Proposal ready: \(fresh.document.title)"
            }
            knownReviewDocIds = Set(queue.map(\.id))
            reviewQueue = queue
            launchableProjects = (try? repo.projectIdsWithRepoPath()) ?? []
        } catch {
            errorMessage = "\(error)"
        }
    }

    func tasks(projectId: Int64) -> [TaskItem] {
        tasks.filter { $0.projectId == projectId }
    }

    private func perform(_ body: (Repository) throws -> Void) {
        guard let repo else { return }
        do {
            try body(repo)
            refresh()
            scheduleDebouncedSync()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Sync

    private func loadSyncEngine() {
        guard let repo else { return }
        // Backward compatibility: a user who configured folder sync before this
        // change has syncFolderKey set but no syncTransportKey — treat as folder.
        let type = UserDefaults.standard.string(forKey: syncTransportKey)
            ?? (UserDefaults.standard.string(forKey: syncFolderKey).map { _ in "folder" })
        do {
            let deviceId = try repo.syncState().deviceId
            switch type {
            case "folder":
                guard let path = UserDefaults.standard.string(forKey: syncFolderKey), !path.isEmpty else { return }
                syncFolderPath = path
                syncTargetLabel = "Folder: \((path as NSString).lastPathComponent)"
                syncEngine = SyncEngine(repo: repo, transport: FolderTransport(root: URL(fileURLWithPath: path), deviceId: deviceId))
            case "github":
                guard let owner = UserDefaults.standard.string(forKey: ghOwnerKey),
                      let name = UserDefaults.standard.string(forKey: ghRepoKey),
                      let token = KeychainTokenStore.load() else { return }
                syncTargetLabel = "GitHub: \(owner)/\(name)"
                syncEngine = SyncEngine(repo: repo, transport:
                    GitHubTransport(owner: owner, repo: name, token: token, deviceId: deviceId))
            default:
                syncEngine = nil
            }
        } catch {
            errorMessage = "Could not start sync: \(error)"
        }
    }

    func setSyncFolder(_ url: URL) {
        let switching = UserDefaults.standard.string(forKey: syncTransportKey) != "folder"
            || UserDefaults.standard.string(forKey: syncFolderKey) != url.path
        UserDefaults.standard.set("folder", forKey: syncTransportKey)
        UserDefaults.standard.set(url.path, forKey: syncFolderKey)
        if switching { perform { try $0.resetSyncCursors() } }
        loadSyncEngine()
        syncNow()
    }

    /// Verifies access, stores the token in the Keychain, switches the target to
    /// GitHub, and syncs. Returns nil on success or a user-facing error message.
    @discardableResult
    func connectGitHub(owner: String, repo: String, token: String) -> String? {
        guard let store = self.repo else { return "No database" }
        do {
            let deviceId = try store.syncState().deviceId
            let probe = GitHubTransport(owner: owner, repo: repo, token: token, deviceId: deviceId)
            guard try probe.verifyAccess() else { return "Repo \(owner)/\(repo) not found or no access." }
        } catch {
            return "Could not verify: \(error)"
        }
        KeychainTokenStore.save(token)
        UserDefaults.standard.set("github", forKey: syncTransportKey)
        UserDefaults.standard.set(owner, forKey: ghOwnerKey)
        UserDefaults.standard.set(repo, forKey: ghRepoKey)
        perform { try $0.resetSyncCursors() }
        loadSyncEngine()
        syncNow()
        return nil
    }

    func disconnectSync() {
        KeychainTokenStore.delete()
        UserDefaults.standard.removeObject(forKey: syncTransportKey)
        syncEngine = nil
        syncTargetLabel = nil
        syncFolderPath = nil
        adoptable = []
    }

    func setProjectSynced(id: Int64, synced: Bool) {
        perform { try $0.setProjectSynced(id: id, synced: synced) }
        syncNow()
    }

    func adopt(_ project: SyncEngine.AdoptableProject) {
        perform { try $0.adoptProject(remoteUUID: project.uuid, name: project.name) }
        syncNow()
    }

    /// Snapshot of the last-known adoption catalog. Refreshed after every sync;
    /// see the `adoptable` published property for the live value views should bind to.
    func availableToAdopt() -> [SyncEngine.AdoptableProject] {
        adoptable
    }

    /// Runs a sync synchronously on the main actor. Store is @MainActor and the
    /// Repository/SQLite connection is single-threaded, so this is the only
    /// safe way to drive the engine without racing user edits or the poll timer.
    func syncNow() {
        guard let syncEngine, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try syncEngine.sync()
        } catch {
            errorMessage = "Sync failed: \(error)"
        }
        refresh()
        adoptable = (try? syncEngine.availableToAdopt()) ?? []
    }

    private func scheduleDebouncedSync() {
        guard syncEngine != nil else { return }
        syncDebounce?.invalidate()
        syncDebounce = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncNow() }
        }
    }

    // MARK: - Projects

    func createProject(name: String, color: String) {
        perform { try $0.createProject(name: name, color: color) }
    }

    func renameProject(id: Int64, name: String) {
        perform { try $0.renameProject(id: id, name: name) }
    }

    func deleteProject(id: Int64) {
        perform { try $0.deleteProject(id: id) }
    }

    // MARK: - Tasks

    func createTask(projectId: Int64, title: String, details: String,
                    status: TaskStatus, priority: TaskPriority, dueDate: Date?) {
        perform {
            try $0.createTask(projectId: projectId, title: title, details: details,
                              status: status, priority: priority,
                              dueDate: dueDate.map(DateCoding.encodeDay))
        }
    }

    func updateTask(id: Int64, changes: Repository.TaskChanges) {
        perform { try $0.updateTask(id: id, changes: changes) }
    }

    func moveTask(id: Int64, to status: TaskStatus) {
        perform { try $0.moveTask(id: id, to: status) }
    }

    func deleteTask(id: Int64) {
        perform { try $0.deleteTask(id: id) }
    }

    func taskDetail(id: Int64) -> TaskDetail? {
        guard let repo else { return nil }
        return try? repo.getTask(id: id)
    }

    // MARK: - Subtasks / labels / notes / documents

    func addSubtask(taskId: Int64, title: String) {
        perform { try $0.addSubtask(taskId: taskId, title: title) }
    }

    func setSubtaskDone(id: Int64, done: Bool) {
        perform { try $0.setSubtaskDone(id: id, done: done) }
    }

    func deleteSubtask(id: Int64) {
        perform { try $0.deleteSubtask(id: id) }
    }

    func addLabel(taskId: Int64, name: String, color: String = "#8B5CF6") {
        perform { try $0.addLabel(taskId: taskId, name: name, color: color) }
    }

    func removeLabel(taskId: Int64, labelId: Int64) {
        perform { try $0.removeLabel(taskId: taskId, labelId: labelId) }
    }

    func allLabels() -> [MarkdownProCore.Label] {
        guard let repo else { return [] }
        return (try? repo.listLabels()) ?? []
    }

    func addNote(taskId: Int64, message: String) {
        perform { try $0.logActivity(taskId: taskId, actor: "user", kind: "note", message: message) }
    }

    func attachDocument(taskId: Int64?, projectId: Int64?, path: String) {
        perform { try $0.attachDocument(taskId: taskId, projectId: projectId, path: path, title: nil) }
    }

    func removeDocument(id: Int64) {
        perform { try $0.removeDocument(id: id) }
    }

    // MARK: - Review

    func annotations(documentId: Int64) -> [MarkdownProCore.Annotation] {
        guard let repo else { return [] }
        return (try? repo.annotations(documentId: documentId)) ?? []
    }

    func addAnnotation(documentId: Int64, quote: String, prefix: String, suffix: String, comment: String) {
        perform { try $0.addAnnotation(documentId: documentId, quote: quote, prefix: prefix,
                                       suffix: suffix, comment: comment, author: "user") }
    }

    func deleteAnnotation(id: Int64) {
        perform { try $0.deleteAnnotation(id: id) }
    }

    func updateAnnotation(id: Int64, comment: String) {
        perform { try $0.updateAnnotation(id: id, comment: comment) }
    }

    func applyVerdict(_ verdict: Repository.ReviewVerdict, documentId: Int64) {
        perform { try $0.applyVerdict(verdict, documentId: documentId, actor: "user") }
    }

    // MARK: - Launch

    func projectLaunchSettings(_ projectId: Int64) -> ProjectLaunchSettings? {
        guard let repo else { return nil }
        return try? repo.projectLaunchSettings(projectId)
    }

    func saveProjectLaunchSettings(_ settings: ProjectLaunchSettings) {
        perform { try $0.setProjectLaunchSettings(settings) }
    }

    /// Compose the script for a ready-to-execute task and present the confirm sheet.
    func beginLaunch(task: TaskItem) {
        guard let repo else { return }
        do {
            let settings = try repo.projectLaunchSettings(task.projectId)
            guard let document = try repo.latestApprovedDocument(taskId: task.id) else {
                errorMessage = "No approved document to launch for this task."
                return
            }
            let script = try LaunchScriptBuilder.script(task: task, document: document, settings: settings)
            activeSheet = .launch(LaunchRequest(script: script, taskTitle: task.title,
                                                warpAvailable: WarpLauncher.isAvailable))
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Run the composed script and record the launch (attention → executing).
    func confirmLaunch(_ request: LaunchRequest) {
        guard let repo else { return }
        do {
            try launcher.launch(request.script)
            try repo.recordLaunch(taskId: request.script.taskId, kind: request.script.kind)
            activeSheet = nil
            refresh()
        } catch {
            errorMessage = "Launch failed: \(error)"
        }
    }

    func clearAttention(taskId: Int64) {
        perform { try $0.setAttention(taskId: taskId, attention: nil, actor: "user") }
    }

    // MARK: - Stats

    func completionsByDay(days: Int = 14) -> [Repository.DayCount] {
        guard let repo else { return [] }
        return (try? repo.completionsByDay(days: days)) ?? []
    }

    /// Ask the reader tab to show a file.
    func openInReader(path: String) {
        pendingReaderURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    // MARK: - Export / import

    /// The export picker lists archived projects too (unchecked by default),
    /// so `projects` — which hides them — is not enough.
    func allProjectsIncludingArchived() -> [Project] {
        guard let repo else { return [] }
        return (try? repo.listProjects(includeArchived: true)) ?? []
    }

    func exportProjects(ids: [Int64], to url: URL) {
        guard let repo else { return }
        do {
            let data = try ProjectExporter.export(projectIds: ids, repo: repo)
            try data.write(to: url)
        } catch {
            errorMessage = "Export failed: \(error)"
        }
    }

    /// Reads and validates a bundle, then opens the import sheet. Writes nothing.
    func beginImport(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let preview = try ProjectImporter.preview(data)
            guard !preview.projects.isEmpty else {
                errorMessage = "That export contains no projects."
                return
            }
            activeSheet = .importBundle(preview, url)
        } catch {
            errorMessage = "Could not read that export: \(error)"
        }
    }

    func finishImport(url: URL, selecting indices: [Int]) {
        guard let repo else { return }
        do {
            let data = try Data(contentsOf: url)
            try ProjectImporter.import(data, selecting: indices, repo: repo)
            refresh()
        } catch {
            errorMessage = "Import failed: \(error)"
        }
    }
}
