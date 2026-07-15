import Foundation

/// Applies incoming ops into local tables under last-write-wins-per-field with
/// final deletes. Column names equal op field names, and SQLite type affinity
/// converts the text value into each column's type — so one UPDATE path serves
/// every field. Caller wraps this in a `db.transaction`.
public struct SyncReplayer {
    private let db: SQLiteConnection

    public init(db: SQLiteConnection) { self.db = db }

    public func apply(_ ops: [Op], adoptedProjectUUIDs: Set<String>) throws {
        let ordered = ops.compactMap { op in op.stamp.map { (op, $0) } }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
        for op in ordered {
            try applyOne(op, adopted: adoptedProjectUUIDs)
        }
    }

    private func table(for entity: SyncEntity) -> String? {
        switch entity {
        case .project: return "projects"
        case .task: return "tasks"
        case .subtask: return "subtasks"
        case .label: return "labels"
        case .document: return "documents"
        case .annotation: return "annotations"
        case .activity: return "activity"
        case .taskLabel: return nil
        }
    }

    private func rowExists(_ table: String, uuid: String) throws -> Bool {
        try db.query("SELECT 1 FROM \(table) WHERE uuid = ? LIMIT 1", [.text(uuid)]).isEmpty == false
    }

    private func isTombstoned(_ uuid: String) throws -> Bool {
        try db.query("SELECT 1 FROM tombstones WHERE entity_uuid = ? LIMIT 1", [.text(uuid)]).isEmpty == false
    }

    private func localProjectId(uuid: String) throws -> Int64? {
        try db.query("SELECT id FROM projects WHERE uuid = ?", [.text(uuid)]).first?.intOrNil("id")
    }

    // MARK: Project resolution

    /// The adopted-project UUID an op belongs to, or nil if it can't be placed.
    private func projectUUID(for op: Op) throws -> String? {
        switch op.entity {
        case .project:
            return op.entityUUID
        case .task:
            if op.kind == .insert { return op.parentUUID }
            return try db.query("""
                SELECT p.uuid AS u FROM tasks t JOIN projects p ON p.id = t.project_id WHERE t.uuid = ?
                """, [.text(op.entityUUID)]).first?.stringOrNil("u")
        case .subtask:
            if op.kind == .insert, let taskUUID = op.parentUUID { return try projectUUIDForTask(uuid: taskUUID) }
            return try db.query("""
                SELECT p.uuid AS u FROM subtasks s JOIN tasks t ON t.id = s.task_id
                JOIN projects p ON p.id = t.project_id WHERE s.uuid = ?
                """, [.text(op.entityUUID)]).first?.stringOrNil("u")
        case .activity:
            if op.kind == .insert, let taskUUID = op.parentUUID { return try projectUUIDForTask(uuid: taskUUID) }
            return try db.query("""
                SELECT p.uuid AS u FROM activity a JOIN tasks t ON t.id = a.task_id
                JOIN projects p ON p.id = t.project_id WHERE a.uuid = ?
                """, [.text(op.entityUUID)]).first?.stringOrNil("u")
        case .document:
            if op.kind == .insert, let parent = op.parentUUID {
                // Parent is a task uuid or a project uuid.
                if let viaTask = try projectUUIDForTask(uuid: parent) { return viaTask }
                return parent
            }
            return try db.query("""
                SELECT COALESCE(pp.uuid, pt.uuid) AS u FROM documents d
                LEFT JOIN projects pp ON pp.id = d.project_id
                LEFT JOIN tasks t ON t.id = d.task_id
                LEFT JOIN projects pt ON pt.id = t.project_id
                WHERE d.uuid = ?
                """, [.text(op.entityUUID)]).first?.stringOrNil("u")
        case .annotation:
            if op.kind == .insert, let docUUID = op.parentUUID { return try projectUUIDForDocument(uuid: docUUID) }
            return try db.query("""
                SELECT COALESCE(pp.uuid, pt.uuid) AS u FROM annotations an
                JOIN documents d ON d.id = an.document_id
                LEFT JOIN projects pp ON pp.id = d.project_id
                LEFT JOIN tasks t ON t.id = d.task_id
                LEFT JOIN projects pt ON pt.id = t.project_id
                WHERE an.uuid = ?
                """, [.text(op.entityUUID)]).first?.stringOrNil("u")
        case .label:
            return nil // labels are global; handled without a project gate
        case .taskLabel:
            let taskUUID = String(op.entityUUID.split(separator: ":", maxSplits: 1).first ?? "")
            return try projectUUIDForTask(uuid: taskUUID)
        }
    }

    private func projectUUIDForTask(uuid: String) throws -> String? {
        try db.query("SELECT p.uuid AS u FROM tasks t JOIN projects p ON p.id = t.project_id WHERE t.uuid = ?",
                     [.text(uuid)]).first?.stringOrNil("u")
    }

    private func projectUUIDForDocument(uuid: String) throws -> String? {
        try db.query("""
            SELECT COALESCE(pp.uuid, pt.uuid) AS u FROM documents d
            LEFT JOIN projects pp ON pp.id = d.project_id
            LEFT JOIN tasks t ON t.id = d.task_id
            LEFT JOIN projects pt ON pt.id = t.project_id WHERE d.uuid = ?
            """, [.text(uuid)]).first?.stringOrNil("u")
    }

    // MARK: Apply

    private func applyOne(_ op: Op, adopted: Set<String>) throws {
        // Labels are global and name-keyed — apply create-or-ignore regardless of project.
        if op.entity == .label {
            if op.kind == .update, op.field == "name", let name = op.value {
                try db.execute("INSERT OR IGNORE INTO labels (name, color, uuid) VALUES (?, '#8B5CF6', ?)",
                               [.text(name), .text(UUID().uuidString)])
            }
            return
        }

        // Deletes are final — for generated-UUID entities only. Label links are
        // name-derived and never tombstoned, so they skip this guard.
        if op.entity != .taskLabel, try isTombstoned(op.entityUUID) { return }

        guard let projectUUID = try projectUUID(for: op), adopted.contains(projectUUID) else { return }

        switch op.entity {
        case .taskLabel:
            try applyLabelLink(op)
        default:
            try applyEntity(op, projectUUID: projectUUID)
        }
    }

    private func applyLabelLink(_ op: Op) throws {
        guard op.field == "attached", let value = op.value else { return }
        let parts = op.entityUUID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let (taskUUID, labelName) = (parts[0], parts[1])
        // LWW on the link's single field.
        let stampField = "attached"
        if let existing = try db.query(
            "SELECT hlc FROM field_stamps WHERE entity_uuid = ? AND field = ?",
            [.text(op.entityUUID), .text(stampField)]).first?.string("hlc"), existing >= op.hlc { return }

        guard let taskId = try db.query("SELECT id FROM tasks WHERE uuid = ?", [.text(taskUUID)]).first?.intOrNil("id")
        else { return }
        // Ensure the label exists (merge by name), then attach/detach.
        try db.execute("INSERT OR IGNORE INTO labels (name, color, uuid) VALUES (?, '#8B5CF6', ?)",
                       [.text(labelName), .text(UUID().uuidString)])
        let labelId = try db.query("SELECT id FROM labels WHERE name = ? COLLATE NOCASE", [.text(labelName)])
            .first!.int("id")
        if value == "1" {
            try db.execute("INSERT OR IGNORE INTO task_labels (task_id, label_id) VALUES (?, ?)",
                           [.integer(taskId), .integer(labelId)])
        } else {
            try db.execute("DELETE FROM task_labels WHERE task_id = ? AND label_id = ?",
                           [.integer(taskId), .integer(labelId)])
        }
        try db.execute("""
            INSERT INTO field_stamps (entity_uuid, field, hlc) VALUES (?, ?, ?)
            ON CONFLICT(entity_uuid, field) DO UPDATE SET hlc = excluded.hlc
            """, [.text(op.entityUUID), .text(stampField), .text(op.hlc)])
    }

    private func applyEntity(_ op: Op, projectUUID: String) throws {
        guard let table = table(for: op.entity) else { return }
        switch op.kind {
        case .insert:
            if try rowExists(table, uuid: op.entityUUID) { return }
            try insertSkeleton(op, table: table, projectUUID: projectUUID)
        case .update:
            guard let field = op.field else { return }
            guard try rowExists(table, uuid: op.entityUUID) else { return } // insert not seen yet
            // LWW gate.
            if let existing = try db.query(
                "SELECT hlc FROM field_stamps WHERE entity_uuid = ? AND field = ?",
                [.text(op.entityUUID), .text(field)]).first?.string("hlc"), existing >= op.hlc { return }
            try db.execute("UPDATE \(table) SET \(field) = ? WHERE uuid = ?",
                           [op.value.map { .text($0) } ?? .null, .text(op.entityUUID)])
            try db.execute("""
                INSERT INTO field_stamps (entity_uuid, field, hlc) VALUES (?, ?, ?)
                ON CONFLICT(entity_uuid, field) DO UPDATE SET hlc = excluded.hlc
                """, [.text(op.entityUUID), .text(field), .text(op.hlc)])
        case .delete:
            try db.execute("DELETE FROM \(table) WHERE uuid = ?", [.text(op.entityUUID)])
            try db.execute("""
                INSERT INTO tombstones (entity_uuid, entity, hlc) VALUES (?, ?, ?)
                ON CONFLICT(entity_uuid) DO UPDATE SET hlc = excluded.hlc
                """, [.text(op.entityUUID), .text(op.entity.rawValue), .text(op.hlc)])
        }
    }

    /// Creates the row with just enough NOT NULL columns; field ops fill the rest.
    private func insertSkeleton(_ op: Op, table: String, projectUUID: String) throws {
        let nowText = DateCoding.encode(Date())
        switch op.entity {
        case .project:
            // Adoption (Task 15) creates the project row; nothing to do if missing.
            return
        case .task:
            guard let projectId = try localProjectId(uuid: projectUUID) else { return }
            try db.execute("""
                INSERT INTO tasks (project_id, title, status, priority, sort_order, created_at, updated_at, uuid)
                VALUES (?, '', 'todo', 'none', 0, ?, ?, ?)
                """, [.integer(projectId), .text(nowText), .text(nowText), .text(op.entityUUID)])
        case .subtask:
            guard let taskUUID = op.parentUUID,
                  let taskId = try db.query("SELECT id FROM tasks WHERE uuid = ?", [.text(taskUUID)]).first?.intOrNil("id")
            else { return }
            try db.execute("INSERT INTO subtasks (task_id, title, done, sort_order, uuid) VALUES (?, '', 0, 0, ?)",
                           [.integer(taskId), .text(op.entityUUID)])
        case .activity:
            guard let taskUUID = op.parentUUID,
                  let taskId = try db.query("SELECT id FROM tasks WHERE uuid = ?", [.text(taskUUID)]).first?.intOrNil("id")
            else { return }
            try db.execute("INSERT INTO activity (task_id, actor, kind, message, created_at, uuid) VALUES (?, 'user', 'note', '', ?, ?)",
                           [.integer(taskId), .text(nowText), .text(op.entityUUID)])
        case .document:
            // Parent is a task uuid or a project uuid; path is device-local, set empty for now.
            let parent = op.parentUUID
            let taskId = try parent.flatMap { try db.query("SELECT id FROM tasks WHERE uuid = ?", [.text($0)]).first?.intOrNil("id") }
            let projectIdForDoc = taskId == nil ? try localProjectId(uuid: projectUUID) : nil
            try db.execute("""
                INSERT INTO documents (task_id, project_id, path, title, created_at, kind, round, updated_at, uuid)
                VALUES (?, ?, '', '', ?, 'note', 1, ?, ?)
                """, [taskId.map { .integer($0) } ?? .null, projectIdForDoc.map { .integer($0) } ?? .null,
                      .text(nowText), .text(nowText), .text(op.entityUUID)])
        case .annotation:
            guard let docUUID = op.parentUUID,
                  let docId = try db.query("SELECT id FROM documents WHERE uuid = ?", [.text(docUUID)]).first?.intOrNil("id")
            else { return }
            try db.execute("""
                INSERT INTO annotations (document_id, round, quote, comment, author, state, created_at, uuid)
                VALUES (?, 1, '', '', 'user', 'open', ?, ?)
                """, [.integer(docId), .text(nowText), .text(op.entityUUID)])
        case .label, .taskLabel:
            return
        }
    }
}
