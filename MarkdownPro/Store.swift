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
    @Published private(set) var reviewQueue: [Repository.ReviewQueueItem] = []
    /// One-shot in-app notification ("Proposal ready: …").
    @Published var toast: String?

    /// Review-doc ids seen by the last refresh; nil until the first load
    /// so launch never toasts.
    private var knownReviewDocIds: Set<Int64>?

    private(set) var repo: Repository?
    private var lastDataVersion: Int64 = 0
    private var timer: Timer?

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
        } catch {
            errorMessage = "\(error)"
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

    func applyVerdict(_ verdict: Repository.ReviewVerdict, documentId: Int64) {
        perform { try $0.applyVerdict(verdict, documentId: documentId, actor: "user") }
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
}
