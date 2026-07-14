import Foundation

/// All reads/writes used by the app and the MCP server.
/// Mutations that matter (status/priority/due date changes, creation)
/// automatically write activity-log entries attributed to `actor`.
public final class Repository {
    public let db: SQLiteConnection

    public init(db: SQLiteConnection) {
        self.db = db
    }

    private func now() -> String { DateCoding.encode(Date()) }

    public enum RepositoryError: Error, CustomStringConvertible {
        case notFound(String)

        public var description: String {
            switch self {
            case .notFound(let m): return "not found: \(m)"
            }
        }
    }

    // MARK: - Projects

    public func listProjects(includeArchived: Bool = false) throws -> [Project] {
        let filter = includeArchived ? "" : "WHERE p.archived = 0"
        let rows = try db.query("""
            SELECT p.*,
                   (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id AND t.status != 'canceled') AS task_count,
                   (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id AND t.status = 'done') AS done_count
            FROM projects p \(filter)
            ORDER BY p.name COLLATE NOCASE
            """)
        return rows.map { r in
            Project(id: r.int("id"), name: r.string("name"), color: r.string("color"),
                    archived: r.bool("archived"), createdAt: r.date("created_at"),
                    updatedAt: r.date("updated_at"),
                    taskCount: Int(r.int("task_count")), doneCount: Int(r.int("done_count")))
        }
    }

    @discardableResult
    public func createProject(name: String, color: String = "#5E6AD2") throws -> Int64 {
        try db.execute("INSERT INTO projects (name, color, created_at, updated_at) VALUES (?, ?, ?, ?)",
                       [.text(name), .text(color), .text(now()), .text(now())])
        return db.lastInsertRowId
    }

    public func renameProject(id: Int64, name: String) throws {
        try db.execute("UPDATE projects SET name = ?, updated_at = ? WHERE id = ?",
                       [.text(name), .text(now()), .integer(id)])
    }

    public func setProjectArchived(id: Int64, archived: Bool) throws {
        try db.execute("UPDATE projects SET archived = ?, updated_at = ? WHERE id = ?",
                       [.integer(archived ? 1 : 0), .text(now()), .integer(id)])
    }

    public func deleteProject(id: Int64) throws {
        try db.execute("DELETE FROM projects WHERE id = ?", [.integer(id)])
    }

    // MARK: - Tasks

    private func taskItem(from r: SQLRow) -> TaskItem {
        TaskItem(id: r.int("id"), projectId: r.int("project_id"), title: r.string("title"),
                 details: r.string("details"),
                 status: TaskStatus(rawValue: r.string("status")) ?? .todo,
                 priority: TaskPriority(rawValue: r.string("priority")) ?? .none,
                 dueDate: r.dateOrNil("due_date"), sortOrder: r.double("sort_order"),
                 createdAt: r.date("created_at"), updatedAt: r.date("updated_at"),
                 labels: [], subtaskCount: Int(r.int("subtask_count")),
                 subtaskDoneCount: Int(r.int("subtask_done_count")),
                 documentCount: Int(r.int("document_count")),
                 attention: r.stringOrNil("attention").flatMap(TaskAttention.init(rawValue:)))
    }

    private static let taskSelect = """
        SELECT t.*,
               (SELECT COUNT(*) FROM subtasks s WHERE s.task_id = t.id) AS subtask_count,
               (SELECT COUNT(*) FROM subtasks s WHERE s.task_id = t.id AND s.done = 1) AS subtask_done_count,
               (SELECT COUNT(*) FROM documents d WHERE d.task_id = t.id) AS document_count
        FROM tasks t
        """

    public func listTasks(projectId: Int64? = nil, status: TaskStatus? = nil,
                          labelName: String? = nil, attention: TaskAttention? = nil) throws -> [TaskItem] {
        var clauses: [String] = []
        var bindings: [SQLValue] = []
        if let projectId {
            clauses.append("t.project_id = ?")
            bindings.append(.integer(projectId))
        }
        if let status {
            clauses.append("t.status = ?")
            bindings.append(.text(status.rawValue))
        }
        if let labelName {
            clauses.append("""
                t.id IN (SELECT tl.task_id FROM task_labels tl
                         JOIN labels l ON l.id = tl.label_id WHERE l.name = ? COLLATE NOCASE)
                """)
            bindings.append(.text(labelName))
        }
        if let attention {
            clauses.append("t.attention = ?")
            bindings.append(.text(attention.rawValue))
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let rows = try db.query("\(Self.taskSelect) \(whereSQL) ORDER BY t.sort_order, t.id", bindings)
        var tasks = rows.map(taskItem(from:))
        try attachLabels(to: &tasks)
        return tasks
    }

    private func attachLabels(to tasks: inout [TaskItem]) throws {
        guard !tasks.isEmpty else { return }
        let ids = tasks.map { String($0.id) }.joined(separator: ",")
        let rows = try db.query("""
            SELECT tl.task_id, l.id, l.name, l.color FROM task_labels tl
            JOIN labels l ON l.id = tl.label_id WHERE tl.task_id IN (\(ids))
            ORDER BY l.name COLLATE NOCASE
            """)
        var byTask: [Int64: [Label]] = [:]
        for r in rows {
            byTask[r.int("task_id"), default: []].append(
                Label(id: r.int("id"), name: r.string("name"), color: r.string("color")))
        }
        for i in tasks.indices {
            tasks[i].labels = byTask[tasks[i].id] ?? []
        }
    }

    public func getTask(id: Int64) throws -> TaskDetail? {
        guard let row = try db.query("\(Self.taskSelect) WHERE t.id = ?", [.integer(id)]).first else {
            return nil
        }
        var tasks = [taskItem(from: row)]
        try attachLabels(to: &tasks)
        let subtasks = try db.query("SELECT * FROM subtasks WHERE task_id = ? ORDER BY sort_order, id", [.integer(id)])
            .map { Subtask(id: $0.int("id"), taskId: $0.int("task_id"), title: $0.string("title"),
                           done: $0.bool("done"), sortOrder: $0.double("sort_order")) }
        let activity = try db.query("SELECT * FROM activity WHERE task_id = ? ORDER BY id DESC", [.integer(id)])
            .map { ActivityEntry(id: $0.int("id"), taskId: $0.int("task_id"), actor: $0.string("actor"),
                                 kind: $0.string("kind"), message: $0.string("message"), createdAt: $0.date("created_at")) }
        let documents = try db.query("SELECT * FROM documents WHERE task_id = ? ORDER BY id DESC", [.integer(id)])
            .map(linkedDocument(from:))
        return TaskDetail(task: tasks[0], subtasks: subtasks, activity: activity, documents: documents)
    }

    @discardableResult
    public func createTask(projectId: Int64, title: String, details: String = "",
                           status: TaskStatus = .todo, priority: TaskPriority = .none,
                           dueDate: String? = nil, labels: [String] = [],
                           subtasks: [String] = [], actor: String = "user") throws -> Int64 {
        try db.transaction {
            let maxOrder = try db.query("SELECT COALESCE(MAX(sort_order), 0) AS m FROM tasks WHERE project_id = ?",
                                        [.integer(projectId)]).first?.double("m") ?? 0
            try db.execute("""
                INSERT INTO tasks (project_id, title, details, status, priority, due_date, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.integer(projectId), .text(title), .text(details), .text(status.rawValue),
                 .text(priority.rawValue), dueDate.map { .text($0) } ?? .null,
                 .real(maxOrder + 1), .text(now()), .text(now())])
            let taskId = db.lastInsertRowId
            for name in labels {
                try addLabel(taskId: taskId, name: name)
            }
            for (index, title) in subtasks.enumerated() {
                try db.execute("INSERT INTO subtasks (task_id, title, sort_order) VALUES (?, ?, ?)",
                               [.integer(taskId), .text(title), .real(Double(index))])
            }
            try logActivity(taskId: taskId, actor: actor, kind: "created", message: "created this task")
            return taskId
        }
    }

    public struct TaskChanges {
        public var title: String?
        public var details: String?
        public var status: TaskStatus?
        public var priority: TaskPriority?
        /// .some(nil) clears the due date; nil leaves it untouched.
        public var dueDate: String??
        public var projectId: Int64?

        public init(title: String? = nil, details: String? = nil, status: TaskStatus? = nil,
                    priority: TaskPriority? = nil, dueDate: String?? = nil, projectId: Int64? = nil) {
            self.title = title
            self.details = details
            self.status = status
            self.priority = priority
            self.dueDate = dueDate
            self.projectId = projectId
        }
    }

    /// Applies the given changes and logs human-readable activity entries.
    public func updateTask(id: Int64, changes: TaskChanges, actor: String = "user") throws {
        guard let current = try getTask(id: id)?.task else { return }
        var sets: [String] = []
        var bindings: [SQLValue] = []
        var logs: [(kind: String, message: String)] = []

        if let title = changes.title, title != current.title {
            sets.append("title = ?")
            bindings.append(.text(title))
            logs.append(("field", "renamed to “\(title)”"))
        }
        if let details = changes.details, details != current.details {
            sets.append("details = ?")
            bindings.append(.text(details))
            logs.append(("field", "updated the description"))
        }
        if let status = changes.status, status != current.status {
            sets.append("status = ?")
            bindings.append(.text(status.rawValue))
            logs.append(("status", "moved from \(current.status.displayName) to \(status.displayName)"))
        }
        if let priority = changes.priority, priority != current.priority {
            sets.append("priority = ?")
            bindings.append(.text(priority.rawValue))
            logs.append(("field", "set priority to \(priority.displayName)"))
        }
        if let dueDate = changes.dueDate {
            sets.append("due_date = ?")
            bindings.append(dueDate.map { .text($0) } ?? .null)
            logs.append(("field", dueDate.map { "set due date to \($0)" } ?? "cleared the due date"))
        }
        if let projectId = changes.projectId, projectId != current.projectId {
            sets.append("project_id = ?")
            bindings.append(.integer(projectId))
            logs.append(("field", "moved to another project"))
        }
        guard !sets.isEmpty else { return }
        sets.append("updated_at = ?")
        bindings.append(.text(now()))
        bindings.append(.integer(id))
        try db.transaction {
            try db.execute("UPDATE tasks SET \(sets.joined(separator: ", ")) WHERE id = ?", bindings)
            for log in logs {
                try logActivity(taskId: id, actor: actor, kind: log.kind, message: log.message)
            }
        }
    }

    /// Board drag & drop: move into a status column, ordered before nothing (append).
    public func moveTask(id: Int64, to status: TaskStatus, actor: String = "user") throws {
        try updateTask(id: id, changes: TaskChanges(status: status), actor: actor)
    }

    public func deleteTask(id: Int64) throws {
        try db.execute("DELETE FROM tasks WHERE id = ?", [.integer(id)])
    }

    // MARK: - Subtasks

    @discardableResult
    public func addSubtask(taskId: Int64, title: String) throws -> Int64 {
        let maxOrder = try db.query("SELECT COALESCE(MAX(sort_order), 0) AS m FROM subtasks WHERE task_id = ?",
                                    [.integer(taskId)]).first?.double("m") ?? 0
        try db.execute("INSERT INTO subtasks (task_id, title, sort_order) VALUES (?, ?, ?)",
                       [.integer(taskId), .text(title), .real(maxOrder + 1)])
        try touchTask(taskId)
        return db.lastInsertRowId
    }

    public func setSubtaskDone(id: Int64, done: Bool) throws {
        try db.execute("UPDATE subtasks SET done = ? WHERE id = ?", [.integer(done ? 1 : 0), .integer(id)])
        if let taskId = try db.query("SELECT task_id FROM subtasks WHERE id = ?", [.integer(id)]).first?.int("task_id") {
            try touchTask(taskId)
        }
    }

    public func deleteSubtask(id: Int64) throws {
        try db.execute("DELETE FROM subtasks WHERE id = ?", [.integer(id)])
    }

    private func touchTask(_ id: Int64) throws {
        try db.execute("UPDATE tasks SET updated_at = ? WHERE id = ?", [.text(now()), .integer(id)])
    }

    // MARK: - Labels

    public func listLabels() throws -> [Label] {
        try db.query("SELECT * FROM labels ORDER BY name COLLATE NOCASE").map {
            Label(id: $0.int("id"), name: $0.string("name"), color: $0.string("color"))
        }
    }

    /// Adds a label to a task, creating the label if needed.
    @discardableResult
    public func addLabel(taskId: Int64, name: String, color: String = "#8B5CF6") throws -> Int64 {
        let existing = try db.query("SELECT id FROM labels WHERE name = ? COLLATE NOCASE", [.text(name)]).first
        let labelId: Int64
        if let existing {
            labelId = existing.int("id")
        } else {
            try db.execute("INSERT INTO labels (name, color) VALUES (?, ?)", [.text(name), .text(color)])
            labelId = db.lastInsertRowId
        }
        try db.execute("INSERT OR IGNORE INTO task_labels (task_id, label_id) VALUES (?, ?)",
                       [.integer(taskId), .integer(labelId)])
        return labelId
    }

    public func removeLabel(taskId: Int64, labelId: Int64) throws {
        try db.execute("DELETE FROM task_labels WHERE task_id = ? AND label_id = ?",
                       [.integer(taskId), .integer(labelId)])
    }

    // MARK: - Activity

    @discardableResult
    public func logActivity(taskId: Int64, actor: String, kind: String, message: String) throws -> Int64 {
        try db.execute("INSERT INTO activity (task_id, actor, kind, message, created_at) VALUES (?, ?, ?, ?, ?)",
                       [.integer(taskId), .text(actor), .text(kind), .text(message), .text(now())])
        return db.lastInsertRowId
    }

    // MARK: - Documents

    private func linkedDocument(from r: SQLRow) -> LinkedDocument {
        LinkedDocument(id: r.int("id"), taskId: r.intOrNil("task_id"), projectId: r.intOrNil("project_id"),
                       path: r.string("path"), title: r.string("title"), createdAt: r.date("created_at"),
                       kind: DocumentKind(rawValue: r.string("kind")) ?? .note,
                       state: r.stringOrNil("state").flatMap(DocumentState.init(rawValue:)),
                       round: Int(r.int("round")), updatedAt: r.dateOrNil("updated_at"))
    }

    public func document(id: Int64) throws -> LinkedDocument? {
        try db.query("SELECT * FROM documents WHERE id = ?", [.integer(id)]).first.map(linkedDocument(from:))
    }

    @discardableResult
    public func attachDocument(taskId: Int64?, projectId: Int64?, path: String, title: String?,
                               kind: DocumentKind = .note) throws -> Int64 {
        let expanded = (path as NSString).expandingTildeInPath
        let resolvedTitle = title ?? (expanded as NSString).lastPathComponent
        try db.execute("""
            INSERT INTO documents (task_id, project_id, path, title, created_at, kind, round, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?)
            """,
            [taskId.map { .integer($0) } ?? .null,
             projectId.map { .integer($0) } ?? .null,
             .text(expanded), .text(resolvedTitle), .text(now()), .text(kind.rawValue), .text(now())])
        if let taskId {
            try logActivity(taskId: taskId, actor: "claude", kind: "note", message: "attached document \(resolvedTitle)")
        }
        return db.lastInsertRowId
    }

    public func removeDocument(id: Int64) throws {
        try db.execute("DELETE FROM documents WHERE id = ?", [.integer(id)])
    }

    public func documents(projectId: Int64) throws -> [LinkedDocument] {
        try db.query("""
            SELECT d.* FROM documents d
            LEFT JOIN tasks t ON t.id = d.task_id
            WHERE d.project_id = ? OR t.project_id = ?
            ORDER BY d.id DESC
            """, [.integer(projectId), .integer(projectId)]).map(linkedDocument(from:))
    }

    // MARK: - Review

    private func setAttentionColumn(taskId: Int64, _ value: String?) throws {
        try db.execute("UPDATE tasks SET attention = ?, updated_at = ? WHERE id = ?",
                       [value.map { .text($0) } ?? .null, .text(now()), .integer(taskId)])
    }

    public func setAttention(taskId: Int64, attention: TaskAttention?, actor: String = "claude") throws {
        try db.transaction {
            try setAttentionColumn(taskId: taskId, attention?.rawValue)
            try logActivity(taskId: taskId, actor: actor, kind: "review",
                            message: attention.map { "set attention to \($0.displayName)" } ?? "cleared attention")
        }
    }

    /// Registers (or re-registers) a markdown file as a proposal awaiting
    /// the user's verdict. Resubmitting the same task+path bumps the round —
    /// including after a rejection, which revives the document so the reviewer
    /// keeps the rejection and its comments in the round history. Submitting a
    /// *different* path for the task supersedes any settled proposal it replaces.
    @discardableResult
    public func submitForReview(taskId: Int64, path: String, title: String? = nil,
                                actor: String = "claude") throws -> Int64 {
        let expanded = (path as NSString).expandingTildeInPath
        let resolvedTitle = title ?? (expanded as NSString).lastPathComponent
        return try db.transaction {
            let existing = try db.query(
                "SELECT id, round, title FROM documents WHERE task_id = ? AND path = ? AND kind = 'proposal'",
                [.integer(taskId), .text(expanded)]).first
            let docId: Int64
            if let existing {
                docId = existing.int("id")
                let newRound = existing.int("round") + 1
                try db.execute(
                    "UPDATE documents SET state = 'needs_review', round = ?, title = ?, updated_at = ? WHERE id = ?",
                    [.integer(newRound), title.map { .text($0) } ?? .text(existing.string("title")),
                     .text(now()), .integer(docId)])
                try logActivity(taskId: taskId, actor: actor, kind: "review",
                                message: "resubmitted “\(resolvedTitle)” for review (round \(newRound))")
            } else {
                try db.execute("""
                    INSERT INTO documents (task_id, project_id, path, title, created_at, kind, state, round, updated_at)
                    VALUES (?, NULL, ?, ?, ?, 'proposal', 'needs_review', 1, ?)
                    """,
                    [.integer(taskId), .text(expanded), .text(resolvedTitle), .text(now()), .text(now())])
                docId = db.lastInsertRowId
                try logActivity(taskId: taskId, actor: actor, kind: "review",
                                message: "submitted “\(resolvedTitle)” for review")
            }
            try db.execute("""
                UPDATE documents SET state = 'superseded', updated_at = ?
                WHERE task_id = ? AND kind = 'proposal' AND path != ?
                  AND state IN ('approved', 'rejected')
                """,
                [.text(now()), .integer(taskId), .text(expanded)])
            try setAttentionColumn(taskId: taskId, TaskAttention.needsReview.rawValue)
            return docId
        }
    }

    private func setDocumentState(_ state: DocumentState, id: Int64) throws {
        try db.execute("UPDATE documents SET state = ?, updated_at = ? WHERE id = ?",
                       [.text(state.rawValue), .text(now()), .integer(id)])
    }

    // MARK: Annotations

    /// Comments persist immediately (crash-safe) as `open`; the verdict is
    /// what makes them actionable for Claude.
    @discardableResult
    public func addAnnotation(documentId: Int64, quote: String, prefix: String = "",
                              suffix: String = "", comment: String,
                              author: String = "user") throws -> Int64 {
        guard let doc = try document(id: documentId) else {
            throw RepositoryError.notFound("document \(documentId)")
        }
        try db.execute("""
            INSERT INTO annotations (document_id, round, quote, prefix, suffix, comment, author, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.integer(documentId), .integer(Int64(doc.round)), .text(quote), .text(prefix),
             .text(suffix), .text(comment), .text(author), .text(now())])
        return db.lastInsertRowId
    }

    public func updateAnnotation(id: Int64, comment: String) throws {
        try db.execute("UPDATE annotations SET comment = ? WHERE id = ?",
                       [.text(comment), .integer(id)])
    }

    public func deleteAnnotation(id: Int64) throws {
        try db.execute("DELETE FROM annotations WHERE id = ?", [.integer(id)])
    }

    public func annotations(documentId: Int64) throws -> [Annotation] {
        try db.query("SELECT * FROM annotations WHERE document_id = ? ORDER BY round, id",
                     [.integer(documentId)]).map {
            Annotation(id: $0.int("id"), documentId: $0.int("document_id"),
                       round: Int($0.int("round")), quote: $0.string("quote"),
                       prefix: $0.string("prefix"), suffix: $0.string("suffix"),
                       comment: $0.string("comment"), author: $0.string("author"),
                       state: AnnotationState(rawValue: $0.string("state")) ?? .open,
                       reply: $0.stringOrNil("reply"), createdAt: $0.date("created_at"),
                       resolvedAt: $0.dateOrNil("resolved_at"))
        }
    }

    public func resolveAnnotation(id: Int64, reply: String, actor: String = "claude") throws {
        guard let row = try db.query("SELECT document_id FROM annotations WHERE id = ?",
                                     [.integer(id)]).first else {
            throw RepositoryError.notFound("annotation \(id)")
        }
        let documentId = row.int("document_id")
        try db.transaction {
            try db.execute("UPDATE annotations SET state = 'addressed', reply = ?, resolved_at = ? WHERE id = ?",
                           [.text(reply), .text(now()), .integer(id)])
            if let doc = try document(id: documentId), let taskId = doc.taskId {
                try logActivity(taskId: taskId, actor: actor, kind: "review",
                                message: "addressed a review comment on “\(doc.title)”")
            }
        }
    }

    // MARK: Verdicts

    public enum ReviewVerdict: String, Sendable {
        case approve
        case requestChanges = "request_changes"
        case reject
    }

    /// Single transaction per spec: a crash can never leave
    /// doc-approved-but-task-unflagged states.
    public func applyVerdict(_ verdict: ReviewVerdict, documentId: Int64, actor: String = "user") throws {
        guard let doc = try document(id: documentId) else {
            throw RepositoryError.notFound("document \(documentId)")
        }
        guard let taskId = doc.taskId, let task = try getTask(id: taskId)?.task else {
            throw RepositoryError.notFound("task for document \(documentId)")
        }
        try db.transaction {
            switch verdict {
            case .approve:
                try setDocumentState(.approved, id: documentId)
                try setAttentionColumn(taskId: taskId, TaskAttention.readyToExecute.rawValue)
                try logActivity(taskId: taskId, actor: actor, kind: "review",
                                message: "approved “\(doc.title)” — ready to execute")
            case .requestChanges:
                try setDocumentState(.changesRequested, id: documentId)
                try setAttentionColumn(taskId: taskId, TaskAttention.changesRequested.rawValue)
                try logActivity(taskId: taskId, actor: actor, kind: "review",
                                message: "requested changes on “\(doc.title)” (round \(doc.round))")
            case .reject:
                try setDocumentState(.rejected, id: documentId)
                try setAttentionColumn(taskId: taskId, nil)
                if task.status != .todo {
                    try db.execute("UPDATE tasks SET status = 'todo', updated_at = ? WHERE id = ?",
                                   [.text(now()), .integer(taskId)])
                    try logActivity(taskId: taskId, actor: actor, kind: "status",
                                    message: "moved from \(task.status.displayName) to \(TaskStatus.todo.displayName)")
                }
                try logActivity(taskId: taskId, actor: actor, kind: "review",
                                message: "rejected “\(doc.title)”")
            }
        }
    }

    // MARK: Queue

    public struct ReviewQueueItem: Identifiable, Sendable {
        public let document: LinkedDocument
        public let taskId: Int64
        public let taskTitle: String
        public let projectId: Int64
        public let projectName: String
        public var id: Int64 { document.id }
    }

    /// Proposals awaiting a verdict, newest activity first.
    public func reviewQueue() throws -> [ReviewQueueItem] {
        try db.query("""
            SELECT d.*, t.title AS task_title, p.id AS p_id, p.name AS project_name
            FROM documents d
            JOIN tasks t ON t.id = d.task_id
            JOIN projects p ON p.id = t.project_id
            WHERE d.kind = 'proposal' AND d.state = 'needs_review'
            ORDER BY COALESCE(d.updated_at, d.created_at) DESC, d.id DESC
            """).map { r in
            ReviewQueueItem(document: linkedDocument(from: r), taskId: r.int("task_id"),
                            taskTitle: r.string("task_title"), projectId: r.int("p_id"),
                            projectName: r.string("project_name"))
        }
    }

    // MARK: - Stats

    public struct DayCount: Identifiable, Sendable {
        public var id: String { day }
        public let day: String
        public let count: Int
    }

    /// Tasks moved to Done per day over the trailing `days` window,
    /// derived from activity-log status entries.
    public func completionsByDay(days: Int = 14) throws -> [DayCount] {
        let rows = try db.query("""
            SELECT substr(created_at, 1, 10) AS day, COUNT(DISTINCT task_id) AS c
            FROM activity
            WHERE kind = 'status' AND message LIKE '%to Done'
              AND created_at >= datetime('now', ?)
            GROUP BY day ORDER BY day
            """, [.text("-\(days) days")])
        return rows.map { DayCount(day: $0.string("day"), count: Int($0.int("c"))) }
    }

    public struct StatusCount: Sendable {
        public let status: TaskStatus
        public let count: Int
    }

    public func countsByStatus(projectId: Int64? = nil) throws -> [StatusCount] {
        let filter = projectId != nil ? "WHERE project_id = ?" : ""
        let bindings: [SQLValue] = projectId.map { [.integer($0)] } ?? []
        let rows = try db.query("SELECT status, COUNT(*) AS c FROM tasks \(filter) GROUP BY status", bindings)
        return rows.compactMap { r in
            TaskStatus(rawValue: r.string("status")).map { StatusCount(status: $0, count: Int(r.int("c"))) }
        }
    }
}
