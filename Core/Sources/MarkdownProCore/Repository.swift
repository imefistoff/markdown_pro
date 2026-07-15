import Foundation

/// All reads/writes used by the app and the MCP server.
/// Mutations that matter (status/priority/due date changes, creation)
/// automatically write activity-log entries attributed to `actor`.
public final class Repository {
    public let db: SQLiteConnection

    public init(db: SQLiteConnection) {
        self.db = db
    }

    private var _sync: SyncState?

    /// Lazily bootstrapped so `init(db:)` stays unchanged for the app, the MCP
    /// server, and tests. First mutation of a synced project pays the cost.
    func syncState() throws -> SyncState {
        if let s = _sync { return s }
        let s = try SyncState(db: db)
        _sync = s
        return s
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
        try db.transaction {
            let uuid = UUID().uuidString
            try db.execute("""
                INSERT INTO projects (name, color, created_at, updated_at, uuid) VALUES (?, ?, ?, ?, ?)
                """,
                [.text(name), .text(color), .text(now()), .text(now()), .text(uuid)])
            // A brand-new project defaults to synced = 0, so this records nothing
            // until setProjectSynced(true) flips it on and snapshots current state.
            return db.lastInsertRowId
        }
    }

    public func renameProject(id: Int64, name: String) throws {
        try db.transaction {
            try db.execute("UPDATE projects SET name = ?, updated_at = ? WHERE id = ?",
                           [.text(name), .text(now()), .integer(id)])
            if let uuid = try entityUUID(.project, id: id) {
                try recordUpdate(.project, uuid: uuid, projectId: id, field: "name", value: .text(name))
            }
        }
    }

    public func setProjectArchived(id: Int64, archived: Bool) throws {
        try db.transaction {
            try db.execute("UPDATE projects SET archived = ?, updated_at = ? WHERE id = ?",
                           [.integer(archived ? 1 : 0), .text(now()), .integer(id)])
            if let uuid = try entityUUID(.project, id: id) {
                try recordUpdate(.project, uuid: uuid, projectId: id,
                                 field: "archived", value: .integer(archived ? 1 : 0))
            }
        }
    }

    public func deleteProject(id: Int64) throws {
        try db.transaction {
            if let uuid = try entityUUID(.project, id: id) {
                try recordDelete(.project, uuid: uuid, projectId: id)
            }
            try db.execute("DELETE FROM projects WHERE id = ?", [.integer(id)])
        }
    }

    /// Turns sync on or off for a project. Turning it ON snapshots the project's
    /// current state into the op log (an insert + a field op per column) so a
    /// machine adopting it later can rebuild it. Turning it OFF stops emission
    /// but leaves already-published ops in place.
    public func setProjectSynced(id: Int64, synced: Bool) throws {
        try db.transaction {
            try db.execute("UPDATE projects SET synced = ?, updated_at = ? WHERE id = ?",
                           [.integer(synced ? 1 : 0), .text(now()), .integer(id)])
            guard synced, let uuid = try entityUUID(.project, id: id),
                  let row = try db.query("SELECT * FROM projects WHERE id = ?", [.integer(id)]).first else { return }
            // projectIsSynced is now true, so this snapshot records.
            try recordInsert(.project, uuid: uuid, projectId: id, parentUUID: nil, fields: [
                ("name", .text(row.string("name"))),
                ("color", .text(row.string("color"))),
                ("archived", .integer(row.int("archived")))
            ])
            try snapshotProjectContents(projectId: id)
        }
    }

    /// Emits insert+field ops for everything already inside a project when it is
    /// first synced. Extended as each entity gains recording.
    private func snapshotProjectContents(projectId: Int64) throws {
        guard let projectUUID = try entityUUID(.project, id: projectId) else { return }
        let tasks = try db.query("SELECT * FROM tasks WHERE project_id = ?", [.integer(projectId)])
        for t in tasks {
            let uuid = t.string("uuid")
            try recordInsert(.task, uuid: uuid, projectId: projectId, parentUUID: projectUUID, fields: [
                ("title", .text(t.string("title"))), ("details", .text(t.string("details"))),
                ("status", .text(t.string("status"))), ("priority", .text(t.string("priority"))),
                ("due_date", t.stringOrNil("due_date").map { .text($0) } ?? .null),
                ("sort_order", .real(t.double("sort_order")))
            ])
            let taskId = t.int("id")
            for s in try db.query("SELECT * FROM subtasks WHERE task_id = ?", [.integer(taskId)]) {
                try recordInsert(.subtask, uuid: s.string("uuid"), projectId: projectId, parentUUID: uuid, fields: [
                    ("title", .text(s.string("title"))), ("done", .integer(s.int("done"))),
                    ("sort_order", .real(s.double("sort_order")))
                ])
            }
            for l in try db.query("""
                SELECT l.uuid, l.name, l.color FROM task_labels tl
                JOIN labels l ON l.id = tl.label_id WHERE tl.task_id = ?
                """, [.integer(taskId)]) {
                try recordInsert(.label, uuid: l.string("uuid"), projectId: projectId, parentUUID: nil, fields: [
                    ("name", .text(l.string("name"))), ("color", .text(l.string("color")))
                ])
                try recordUpdate(.taskLabel, uuid: "\(uuid):\(l.string("name"))", projectId: projectId,
                                 field: "attached", value: .text("1"))
            }
            for d in try db.query("SELECT * FROM documents WHERE task_id = ?", [.integer(taskId)]) {
                try recordInsert(.document, uuid: d.string("uuid"), projectId: projectId, parentUUID: uuid, fields: [
                    ("title", .text(d.string("title"))), ("kind", .text(d.string("kind"))),
                    ("state", d.stringOrNil("state").map { .text($0) } ?? .null),
                    ("round", .integer(d.int("round")))
                ])
            }
        }
        for d in try db.query("SELECT * FROM documents WHERE project_id = ?", [.integer(projectId)]) {
            try recordInsert(.document, uuid: d.string("uuid"), projectId: projectId, parentUUID: projectUUID, fields: [
                ("title", .text(d.string("title"))), ("kind", .text(d.string("kind"))),
                ("state", d.stringOrNil("state").map { .text($0) } ?? .null),
                ("round", .integer(d.int("round")))
            ])
        }
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
            let uuid = UUID().uuidString
            try db.execute("""
                INSERT INTO tasks (project_id, title, details, status, priority, due_date, uuid, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.integer(projectId), .text(title), .text(details), .text(status.rawValue),
                 .text(priority.rawValue), dueDate.map { .text($0) } ?? .null,
                 .text(uuid), .real(maxOrder + 1), .text(now()), .text(now())])
            let taskId = db.lastInsertRowId
            if let projectUUID = try entityUUID(.project, id: projectId) {
                try recordInsert(.task, uuid: uuid, projectId: projectId, parentUUID: projectUUID, fields: [
                    ("title", .text(title)), ("details", .text(details)),
                    ("status", .text(status.rawValue)), ("priority", .text(priority.rawValue)),
                    ("due_date", dueDate.map { .text($0) } ?? .null),
                    ("sort_order", .real(maxOrder + 1))
                ])
            }
            for name in labels {
                try addLabel(taskId: taskId, name: name)
            }
            for (index, subtaskTitle) in subtasks.enumerated() {
                let subUUID = UUID().uuidString
                try db.execute("INSERT INTO subtasks (task_id, title, sort_order, uuid) VALUES (?, ?, ?, ?)",
                               [.integer(taskId), .text(subtaskTitle), .real(Double(index)), .text(subUUID)])
                if let taskUUID = try entityUUID(.task, id: taskId) {
                    try recordInsert(.subtask, uuid: subUUID, projectId: projectId, parentUUID: taskUUID, fields: [
                        ("title", .text(subtaskTitle)), ("done", .integer(0)), ("sort_order", .real(Double(index)))
                    ])
                }
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
        var syncFields: [(String, SQLValue)] = []

        if let title = changes.title, title != current.title {
            sets.append("title = ?")
            bindings.append(.text(title))
            logs.append(("field", "renamed to “\(title)”"))
            syncFields.append(("title", .text(title)))
        }
        if let details = changes.details, details != current.details {
            sets.append("details = ?")
            bindings.append(.text(details))
            logs.append(("field", "updated the description"))
            syncFields.append(("details", .text(details)))
        }
        if let status = changes.status, status != current.status {
            sets.append("status = ?")
            bindings.append(.text(status.rawValue))
            logs.append(("status", "moved from \(current.status.displayName) to \(status.displayName)"))
            syncFields.append(("status", .text(status.rawValue)))
        }
        if let priority = changes.priority, priority != current.priority {
            sets.append("priority = ?")
            bindings.append(.text(priority.rawValue))
            logs.append(("field", "set priority to \(priority.displayName)"))
            syncFields.append(("priority", .text(priority.rawValue)))
        }
        if let dueDate = changes.dueDate {
            let currentDay = current.dueDate.map(DateCoding.encodeDay)
            if dueDate != currentDay {
                sets.append("due_date = ?")
                bindings.append(dueDate.map { .text($0) } ?? .null)
                logs.append(("field", dueDate.map { "set due date to \($0)" } ?? "cleared the due date"))
                syncFields.append(("due_date", dueDate.map { .text($0) } ?? .null))
            }
        }
        if let projectId = changes.projectId, projectId != current.projectId {
            sets.append("project_id = ?")
            bindings.append(.integer(projectId))
            logs.append(("field", "moved to another project"))
            syncFields.append(("project_id", .integer(projectId)))
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
            if let uuid = try entityUUID(.task, id: id) {
                // Record against the CURRENT project (a move records under the new one).
                let owningProject = changes.projectId ?? current.projectId
                for (field, value) in syncFields {
                    try recordUpdate(.task, uuid: uuid, projectId: owningProject, field: field, value: value)
                }
            }
        }
    }

    /// Board drag & drop: move into a status column, ordered before nothing (append).
    public func moveTask(id: Int64, to status: TaskStatus, actor: String = "user") throws {
        try updateTask(id: id, changes: TaskChanges(status: status), actor: actor)
    }

    public func deleteTask(id: Int64) throws {
        try db.transaction {
            if let uuid = try entityUUID(.task, id: id),
               let projectId = try db.query("SELECT project_id FROM tasks WHERE id = ?", [.integer(id)])
                .first?.int("project_id") {
                try recordDelete(.task, uuid: uuid, projectId: projectId)
            }
            try db.execute("DELETE FROM tasks WHERE id = ?", [.integer(id)])
        }
    }

    // MARK: - Subtasks

    @discardableResult
    public func addSubtask(taskId: Int64, title: String) throws -> Int64 {
        try db.transaction {
            let maxOrder = try db.query("SELECT COALESCE(MAX(sort_order), 0) AS m FROM subtasks WHERE task_id = ?",
                                        [.integer(taskId)]).first?.double("m") ?? 0
            let uuid = UUID().uuidString
            try db.execute("INSERT INTO subtasks (task_id, title, sort_order, uuid) VALUES (?, ?, ?, ?)",
                           [.integer(taskId), .text(title), .real(maxOrder + 1), .text(uuid)])
            let subId = db.lastInsertRowId
            try touchTask(taskId)
            if let projectId = try projectId(forTask: taskId), let taskUUID = try entityUUID(.task, id: taskId) {
                try recordInsert(.subtask, uuid: uuid, projectId: projectId, parentUUID: taskUUID, fields: [
                    ("title", .text(title)), ("done", .integer(0)), ("sort_order", .real(maxOrder + 1))
                ])
            }
            return subId
        }
    }

    public func setSubtaskDone(id: Int64, done: Bool) throws {
        try db.transaction {
            try db.execute("UPDATE subtasks SET done = ? WHERE id = ?", [.integer(done ? 1 : 0), .integer(id)])
            guard let taskId = try db.query("SELECT task_id FROM subtasks WHERE id = ?", [.integer(id)])
                .first?.int("task_id") else { return }
            try touchTask(taskId)
            if let uuid = try entityUUID(.subtask, id: id), let projectId = try projectId(forTask: taskId) {
                try recordUpdate(.subtask, uuid: uuid, projectId: projectId,
                                 field: "done", value: .integer(done ? 1 : 0))
            }
        }
    }

    public func deleteSubtask(id: Int64) throws {
        try db.transaction {
            let row = try db.query("SELECT uuid, task_id FROM subtasks WHERE id = ?", [.integer(id)]).first
            if let row, let projectId = try projectId(forTask: row.int("task_id")) {
                try recordDelete(.subtask, uuid: row.string("uuid"), projectId: projectId)
            }
            try db.execute("DELETE FROM subtasks WHERE id = ?", [.integer(id)])
        }
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
    ///
    /// Deliberately transaction-free: `createTask` and `insertImportedProject`
    /// call this from inside their own `db.transaction`, and `db.transaction`
    /// (`BEGIN IMMEDIATE`) is not reentrant. When called standalone it is no
    /// more or less atomic than before; when called from a caller's
    /// transaction, the ops commit with it.
    @discardableResult
    public func addLabel(taskId: Int64, name: String, color: String = "#8B5CF6") throws -> Int64 {
        let existing = try db.query("SELECT id, uuid FROM labels WHERE name = ? COLLATE NOCASE", [.text(name)]).first
        let labelId: Int64
        let labelUUID: String
        if let existing {
            labelId = existing.int("id")
            labelUUID = existing.string("uuid")
        } else {
            labelUUID = UUID().uuidString
            try db.execute("INSERT INTO labels (name, color, uuid) VALUES (?, ?, ?)",
                           [.text(name), .text(color), .text(labelUUID)])
            labelId = db.lastInsertRowId
        }
        try db.execute("INSERT OR IGNORE INTO task_labels (task_id, label_id) VALUES (?, ?)",
                       [.integer(taskId), .integer(labelId)])
        if let projectId = try projectId(forTask: taskId), let taskUUID = try entityUUID(.task, id: taskId) {
            // Label carries its name (labels merge by name) and colour.
            try recordInsert(.label, uuid: labelUUID, projectId: projectId, parentUUID: nil, fields: [
                ("name", .text(name)), ("color", .text(color))
            ])
            try recordUpdate(.taskLabel, uuid: "\(taskUUID):\(name)", projectId: projectId,
                             field: "attached", value: .text("1"))
        }
        return labelId
    }

    public func removeLabel(taskId: Int64, labelId: Int64) throws {
        try db.transaction {
            let labelName = try db.query("SELECT name FROM labels WHERE id = ?", [.integer(labelId)]).first?.string("name")
            try db.execute("DELETE FROM task_labels WHERE task_id = ? AND label_id = ?",
                           [.integer(taskId), .integer(labelId)])
            if let labelName, let projectId = try projectId(forTask: taskId),
               let taskUUID = try entityUUID(.task, id: taskId) {
                try recordUpdate(.taskLabel, uuid: "\(taskUUID):\(labelName)", projectId: projectId,
                                 field: "attached", value: .text("0"))
            }
        }
    }

    // MARK: - Activity

    /// Deliberately transaction-free, exactly like `addLabel`: `createTask`,
    /// `updateTask`, `submitForReview`, `applyVerdict`, etc. call this from
    /// inside their own `db.transaction`, and `db.transaction` (`BEGIN
    /// IMMEDIATE`) is not reentrant.
    @discardableResult
    public func logActivity(taskId: Int64, actor: String, kind: String, message: String) throws -> Int64 {
        let uuid = UUID().uuidString
        try db.execute("INSERT INTO activity (task_id, actor, kind, message, created_at, uuid) VALUES (?, ?, ?, ?, ?, ?)",
                       [.integer(taskId), .text(actor), .text(kind), .text(message), .text(now()), .text(uuid)])
        let activityId = db.lastInsertRowId
        if let projectId = try projectId(forTask: taskId), let taskUUID = try entityUUID(.task, id: taskId) {
            try recordInsert(.activity, uuid: uuid, projectId: projectId, parentUUID: taskUUID, fields: [
                ("actor", .text(actor)), ("kind", .text(kind)), ("message", .text(message))
            ])
        }
        return activityId
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
        try db.transaction {
            let expanded = (path as NSString).expandingTildeInPath
            let resolvedTitle = title ?? (expanded as NSString).lastPathComponent
            let uuid = UUID().uuidString
            try db.execute("""
                INSERT INTO documents (task_id, project_id, path, title, created_at, kind, round, updated_at, uuid)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
                [taskId.map { .integer($0) } ?? .null, projectId.map { .integer($0) } ?? .null,
                 .text(expanded), .text(resolvedTitle), .text(now()), .text(kind.rawValue), .text(now()), .text(uuid)])
            let docId = db.lastInsertRowId
            if let taskId {
                try logActivity(taskId: taskId, actor: "claude", kind: "note", message: "attached document \(resolvedTitle)")
            }
            if let owningProject = try self.projectId(forDocument: docId),
               let parentUUID = try documentParentUUID(taskId: taskId, projectId: projectId) {
                try recordInsert(.document, uuid: uuid, projectId: owningProject, parentUUID: parentUUID, fields: [
                    ("title", .text(resolvedTitle)), ("kind", .text(kind.rawValue)), ("round", .integer(1))
                ])
            }
            return docId
        }
    }

    /// A document's parent is its task (if any), else its project.
    private func documentParentUUID(taskId: Int64?, projectId: Int64?) throws -> String? {
        if let taskId { return try entityUUID(.task, id: taskId) }
        if let projectId { return try entityUUID(.project, id: projectId) }
        return nil
    }

    public func removeDocument(id: Int64) throws {
        try db.transaction {
            if let uuid = try entityUUID(.document, id: id), let projectId = try self.projectId(forDocument: id) {
                try recordDelete(.document, uuid: uuid, projectId: projectId)
            }
            try db.execute("DELETE FROM documents WHERE id = ?", [.integer(id)])
        }
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
        if let uuid = try entityUUID(.task, id: taskId), let projectId = try projectId(forTask: taskId) {
            try recordUpdate(.task, uuid: uuid, projectId: projectId,
                             field: "attention", value: value.map { .text($0) } ?? .null)
        }
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
                if let uuid = try entityUUID(.document, id: docId), let projectId = try projectId(forDocument: docId) {
                    try recordUpdate(.document, uuid: uuid, projectId: projectId, field: "state", value: .text("needs_review"))
                    try recordUpdate(.document, uuid: uuid, projectId: projectId, field: "round", value: .integer(newRound))
                    if let providedTitle = title {
                        try recordUpdate(.document, uuid: uuid, projectId: projectId, field: "title", value: .text(providedTitle))
                    }
                }
            } else {
                let uuid = UUID().uuidString
                try db.execute("""
                    INSERT INTO documents (task_id, project_id, path, title, created_at, kind, state, round, updated_at, uuid)
                    VALUES (?, NULL, ?, ?, ?, 'proposal', 'needs_review', 1, ?, ?)
                    """,
                    [.integer(taskId), .text(expanded), .text(resolvedTitle), .text(now()), .text(now()), .text(uuid)])
                docId = db.lastInsertRowId
                try logActivity(taskId: taskId, actor: actor, kind: "review",
                                message: "submitted “\(resolvedTitle)” for review")
                if let projectId = try projectId(forDocument: docId), let taskUUID = try entityUUID(.task, id: taskId) {
                    try recordInsert(.document, uuid: uuid, projectId: projectId, parentUUID: taskUUID, fields: [
                        ("title", .text(resolvedTitle)), ("kind", .text("proposal")),
                        ("state", .text("needs_review")), ("round", .integer(1))
                    ])
                }
            }
            let supersededDocs = try db.query("""
                SELECT uuid FROM documents
                WHERE task_id = ? AND kind = 'proposal' AND path != ? AND state IN ('approved', 'rejected')
                """, [.integer(taskId), .text(expanded)])
            try db.execute("""
                UPDATE documents SET state = 'superseded', updated_at = ?
                WHERE task_id = ? AND kind = 'proposal' AND path != ?
                  AND state IN ('approved', 'rejected')
                """,
                [.text(now()), .integer(taskId), .text(expanded)])
            if let ownerProject = try projectId(forTask: taskId) {
                for supRow in supersededDocs {
                    try recordUpdate(.document, uuid: supRow.string("uuid"), projectId: ownerProject,
                                     field: "state", value: .text("superseded"))
                }
            }
            try setAttentionColumn(taskId: taskId, TaskAttention.needsReview.rawValue)
            return docId
        }
    }

    private func setDocumentState(_ state: DocumentState, id: Int64) throws {
        try db.execute("UPDATE documents SET state = ?, updated_at = ? WHERE id = ?",
                       [.text(state.rawValue), .text(now()), .integer(id)])
        if let uuid = try entityUUID(.document, id: id), let projectId = try projectId(forDocument: id) {
            try recordUpdate(.document, uuid: uuid, projectId: projectId, field: "state", value: .text(state.rawValue))
        }
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
        return try db.transaction {
            let uuid = UUID().uuidString
            try db.execute("""
                INSERT INTO annotations (document_id, round, quote, prefix, suffix, comment, author, created_at, uuid)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.integer(documentId), .integer(Int64(doc.round)), .text(quote), .text(prefix),
                 .text(suffix), .text(comment), .text(author), .text(now()), .text(uuid)])
            let annId = db.lastInsertRowId
            if let projectId = try projectId(forDocument: documentId), let docUUID = try entityUUID(.document, id: documentId) {
                try recordInsert(.annotation, uuid: uuid, projectId: projectId, parentUUID: docUUID, fields: [
                    ("round", .integer(Int64(doc.round))), ("quote", .text(quote)),
                    ("prefix", .text(prefix)), ("suffix", .text(suffix)),
                    ("comment", .text(comment)), ("author", .text(author)), ("state", .text("open"))
                ])
            }
            return annId
        }
    }

    public func updateAnnotation(id: Int64, comment: String) throws {
        try db.transaction {
            try db.execute("UPDATE annotations SET comment = ? WHERE id = ?", [.text(comment), .integer(id)])
            if let uuid = try entityUUID(.annotation, id: id), let projectId = try projectId(forAnnotation: id) {
                try recordUpdate(.annotation, uuid: uuid, projectId: projectId, field: "comment", value: .text(comment))
            }
        }
    }

    public func deleteAnnotation(id: Int64) throws {
        try db.transaction {
            if let uuid = try entityUUID(.annotation, id: id), let projectId = try projectId(forAnnotation: id) {
                try recordDelete(.annotation, uuid: uuid, projectId: projectId)
            }
            try db.execute("DELETE FROM annotations WHERE id = ?", [.integer(id)])
        }
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
            if let uuid = try entityUUID(.annotation, id: id), let projectId = try projectId(forAnnotation: id) {
                try recordUpdate(.annotation, uuid: uuid, projectId: projectId, field: "state", value: .text("addressed"))
                try recordUpdate(.annotation, uuid: uuid, projectId: projectId, field: "reply", value: .text(reply))
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
                    if let uuid = try entityUUID(.task, id: taskId), let projectId = try projectId(forTask: taskId) {
                        try recordUpdate(.task, uuid: uuid, projectId: projectId, field: "status", value: .text("todo"))
                    }
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
                INSERT INTO projects (name, color, archived, created_at, updated_at, uuid)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [.text(name), .text(project.color), .integer(project.archived ? 1 : 0),
                 .text(project.createdAt), .text(project.updatedAt), .text(UUID().uuidString)])
            let projectId = db.lastInsertRowId

            for document in project.documents {
                try insertImportedDocument(document, taskId: nil, projectId: projectId,
                                           resolver: documentPathResolver)
            }

            for task in project.tasks {
                try db.execute("""
                    INSERT INTO tasks (project_id, title, details, status, priority, due_date,
                                       sort_order, created_at, updated_at, uuid)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.integer(projectId), .text(task.title), .text(task.details),
                     .text(task.status), .text(task.priority),
                     task.dueDate.map { .text($0) } ?? .null,
                     .real(task.sortOrder), .text(task.createdAt), .text(task.updatedAt),
                     .text(UUID().uuidString)])
                let taskId = db.lastInsertRowId

                // addLabel opens no transaction of its own, and already merges by
                // name while keeping an existing label's colour — exactly what we want.
                for label in task.labels {
                    try addLabel(taskId: taskId, name: label.name, color: label.color)
                }

                for subtask in task.subtasks {
                    try db.execute("""
                        INSERT INTO subtasks (task_id, title, done, sort_order, uuid) VALUES (?, ?, ?, ?, ?)
                        """,
                        [.integer(taskId), .text(subtask.title),
                         .integer(subtask.done ? 1 : 0), .real(subtask.sortOrder), .text(UUID().uuidString)])
                }

                for entry in task.activity {
                    try db.execute("""
                        INSERT INTO activity (task_id, actor, kind, message, created_at, uuid)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        [.integer(taskId), .text(entry.actor), .text(entry.kind),
                         .text(entry.message), .text(entry.createdAt), .text(UUID().uuidString)])
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
        try db.execute("""
            INSERT INTO documents (task_id, project_id, path, title, created_at, uuid) VALUES (?, ?, ?, ?, ?, ?)
            """,
            [taskId.map { .integer($0) } ?? .null,
             projectId.map { .integer($0) } ?? .null,
             .text(path), .text(document.title), .text(now()), .text(UUID().uuidString)])
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

    // MARK: - Sync recording

    /// True when the entity's owning project has sync turned on. `nil` projectId
    /// (a project row itself, resolved by the caller) is handled at call sites.
    func projectIsSynced(_ projectId: Int64) throws -> Bool {
        try db.query("SELECT synced FROM projects WHERE id = ?", [.integer(projectId)])
            .first?.bool("synced") ?? false
    }

    /// Resolves the owning project for a task, so subtask/label ops (which
    /// only carry a task id) can be recorded under the right project.
    func projectId(forTask taskId: Int64) throws -> Int64? {
        try db.query("SELECT project_id FROM tasks WHERE id = ?", [.integer(taskId)]).first?.intOrNil("project_id")
    }

    /// Documents belong to a project directly (`project_id`) or through a task (`task_id`).
    func projectId(forDocument documentId: Int64) throws -> Int64? {
        guard let row = try db.query("SELECT task_id, project_id FROM documents WHERE id = ?",
                                     [.integer(documentId)]).first else { return nil }
        if let direct = row.intOrNil("project_id") { return direct }
        if let taskId = row.intOrNil("task_id") { return try projectId(forTask: taskId) }
        return nil
    }

    func projectId(forAnnotation annotationId: Int64) throws -> Int64? {
        guard let docId = try db.query("SELECT document_id FROM annotations WHERE id = ?",
                                       [.integer(annotationId)]).first?.int("document_id") else { return nil }
        return try projectId(forDocument: docId)
    }

    func entityUUID(_ entity: SyncEntity, id: Int64) throws -> String? {
        let table: String
        switch entity {
        case .project: table = "projects"
        case .task: table = "tasks"
        case .subtask: table = "subtasks"
        case .label: table = "labels"
        case .document: table = "documents"
        case .annotation: table = "annotations"
        case .activity: table = "activity"
        case .taskLabel: return nil // derived composite; callers build it directly
        }
        return try db.query("SELECT uuid FROM \(table) WHERE id = ?", [.integer(id)]).first?.stringOrNil("uuid")
    }

    /// Appends one op and advances the entity/field stamp. Transaction-free:
    /// the CALLER already holds an open `db.transaction`.
    private func appendOp(entity: SyncEntity, uuid: String, kind: OpKind,
                          field: String?, value: SQLValue, parentUUID: String?,
                          stamp: HLC? = nil) throws {
        let state = try syncState()
        let hlc = stamp ?? state.clock.now()
        let valueText: String?
        switch value {
        case .text(let s): valueText = s
        case .integer(let i): valueText = String(i)
        case .real(let d): valueText = String(d)
        case .null: valueText = nil
        }
        try db.execute("""
            INSERT INTO ops (entity, entity_uuid, kind, field, value, parent_uuid, device_id, hlc, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(entity.rawValue), .text(uuid), .text(kind.rawValue),
             field.map { .text($0) } ?? .null, valueText.map { .text($0) } ?? .null,
             parentUUID.map { .text($0) } ?? .null,
             .text(state.deviceId), .text(hlc.description), .text(now())])
        if let field {
            try db.execute("""
                INSERT INTO field_stamps (entity_uuid, field, hlc) VALUES (?, ?, ?)
                ON CONFLICT(entity_uuid, field) DO UPDATE SET hlc = excluded.hlc
                """, [.text(uuid), .text(field), .text(hlc.description)])
        }
    }

    /// Records an insert plus one update per field. `projectId` is the owning
    /// project; nothing is recorded unless it is synced.
    func recordInsert(_ entity: SyncEntity, uuid: String, projectId: Int64?,
                      parentUUID: String?, fields: [(String, SQLValue)]) throws {
        guard let projectId, try projectIsSynced(projectId) else { return }
        try appendOp(entity: entity, uuid: uuid, kind: .insert, field: nil, value: .null, parentUUID: parentUUID)
        for (field, value) in fields {
            try appendOp(entity: entity, uuid: uuid, kind: .update, field: field, value: value, parentUUID: nil)
        }
    }

    func recordUpdate(_ entity: SyncEntity, uuid: String, projectId: Int64?,
                      field: String, value: SQLValue) throws {
        guard let projectId, try projectIsSynced(projectId) else { return }
        try appendOp(entity: entity, uuid: uuid, kind: .update, field: field, value: value, parentUUID: nil)
    }

    func recordDelete(_ entity: SyncEntity, uuid: String, projectId: Int64?) throws {
        guard let projectId, try projectIsSynced(projectId) else { return }
        let hlc = try syncState().clock.now()
        try appendOp(entity: entity, uuid: uuid, kind: .delete, field: nil, value: .null, parentUUID: nil, stamp: hlc)
        try db.execute("""
            INSERT INTO tombstones (entity_uuid, entity, hlc) VALUES (?, ?, ?)
            ON CONFLICT(entity_uuid) DO UPDATE SET hlc = excluded.hlc
            """, [.text(uuid), .text(entity.rawValue), .text(hlc.description)])
    }
}
