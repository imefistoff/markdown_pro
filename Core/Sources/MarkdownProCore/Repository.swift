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
                 documentCount: Int(r.int("document_count")))
    }

    private static let taskSelect = """
        SELECT t.*,
               (SELECT COUNT(*) FROM subtasks s WHERE s.task_id = t.id) AS subtask_count,
               (SELECT COUNT(*) FROM subtasks s WHERE s.task_id = t.id AND s.done = 1) AS subtask_done_count,
               (SELECT COUNT(*) FROM documents d WHERE d.task_id = t.id) AS document_count
        FROM tasks t
        """

    public func listTasks(projectId: Int64? = nil, status: TaskStatus? = nil, labelName: String? = nil) throws -> [TaskItem] {
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
            .map { LinkedDocument(id: $0.int("id"), taskId: $0.intOrNil("task_id"), projectId: $0.intOrNil("project_id"),
                                  path: $0.string("path"), title: $0.string("title"), createdAt: $0.date("created_at")) }
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

    @discardableResult
    public func attachDocument(taskId: Int64?, projectId: Int64?, path: String, title: String?) throws -> Int64 {
        let expanded = (path as NSString).expandingTildeInPath
        let resolvedTitle = title ?? (expanded as NSString).lastPathComponent
        try db.execute("INSERT INTO documents (task_id, project_id, path, title, created_at) VALUES (?, ?, ?, ?, ?)",
                       [taskId.map { .integer($0) } ?? .null,
                        projectId.map { .integer($0) } ?? .null,
                        .text(expanded), .text(resolvedTitle), .text(now())])
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
            """, [.integer(projectId), .integer(projectId)]).map {
            LinkedDocument(id: $0.int("id"), taskId: $0.intOrNil("task_id"), projectId: $0.intOrNil("project_id"),
                           path: $0.string("path"), title: $0.string("title"), createdAt: $0.date("created_at"))
        }
    }

    // MARK: - Import

    /// A free project name: `desired`, else "desired (imported)", "desired (imported 2)", …
    /// Import never merges into an existing project, so a collision becomes a new,
    /// visibly-named project rather than a silent overwrite.
    public func availableProjectName(_ desired: String) throws -> String {
        func isTaken(_ name: String) throws -> Bool {
            try db.query("SELECT 1 FROM projects WHERE name = ? COLLATE NOCASE LIMIT 1",
                         [.text(name)]).isEmpty == false
        }
        guard try isTaken(desired) else { return desired }
        let first = "\(desired) (imported)"
        guard try isTaken(first) else { return first }
        var suffix = 2
        while true {
            let candidate = "\(desired) (imported \(suffix))"
            if try !isTaken(candidate) { return candidate }
            suffix += 1
        }
    }

    /// Inserts a whole exported project, preserving timestamps, sort order and
    /// activity history verbatim — unlike `createTask`, which stamps its own
    /// `created_at` and logs a synthetic "created" entry.
    ///
    /// `documentPathResolver` decides where each document should point (a live file
    /// or a restored copy); returning nil skips that document.
    ///
    /// Runs in one transaction: a failure part-way leaves the board untouched.
    @discardableResult
    public func insertImportedProject(_ project: ExportedProject,
                                      name: String,
                                      documentPathResolver: (ExportedDocument) -> String?) throws -> Int64 {
        try db.transaction {
            try db.execute("""
                INSERT INTO projects (name, color, archived, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                [.text(name), .text(project.color), .integer(project.archived ? 1 : 0),
                 .text(project.createdAt), .text(project.updatedAt)])
            let projectId = db.lastInsertRowId

            for document in project.documents {
                try insertImportedDocument(document, taskId: nil, projectId: projectId,
                                           resolver: documentPathResolver)
            }

            for task in project.tasks {
                try db.execute("""
                    INSERT INTO tasks (project_id, title, details, status, priority, due_date,
                                       sort_order, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.integer(projectId), .text(task.title), .text(task.details),
                     .text(task.status), .text(task.priority),
                     task.dueDate.map { .text($0) } ?? .null,
                     .real(task.sortOrder), .text(task.createdAt), .text(task.updatedAt)])
                let taskId = db.lastInsertRowId

                // addLabel opens no transaction of its own, and already merges by
                // name while keeping an existing label's colour — exactly what we want.
                for label in task.labels {
                    try addLabel(taskId: taskId, name: label.name, color: label.color)
                }

                for subtask in task.subtasks {
                    try db.execute("INSERT INTO subtasks (task_id, title, done, sort_order) VALUES (?, ?, ?, ?)",
                                   [.integer(taskId), .text(subtask.title),
                                    .integer(subtask.done ? 1 : 0), .real(subtask.sortOrder)])
                }

                for entry in task.activity {
                    try db.execute("""
                        INSERT INTO activity (task_id, actor, kind, message, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        [.integer(taskId), .text(entry.actor), .text(entry.kind),
                         .text(entry.message), .text(entry.createdAt)])
                }

                for document in task.documents {
                    try insertImportedDocument(document, taskId: taskId, projectId: nil,
                                               resolver: documentPathResolver)
                }
            }

            return projectId
        }
    }

    /// Raw document insert. Unlike `attachDocument` it logs no activity — imported
    /// history comes from the bundle, not from the act of importing.
    private func insertImportedDocument(_ document: ExportedDocument,
                                        taskId: Int64?,
                                        projectId: Int64?,
                                        resolver: (ExportedDocument) -> String?) throws {
        guard let path = resolver(document) else { return }
        try db.execute("INSERT INTO documents (task_id, project_id, path, title, created_at) VALUES (?, ?, ?, ?, ?)",
                       [taskId.map { .integer($0) } ?? .null,
                        projectId.map { .integer($0) } ?? .null,
                        .text(path), .text(document.title), .text(now())])
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
