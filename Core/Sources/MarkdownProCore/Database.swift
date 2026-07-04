import Foundation

/// Opens the shared database and applies schema migrations.
/// Both the app and the MCP server go through this type, so either
/// one can safely be launched first.
public enum Database {
    /// Resolution order: MARKDOWNPRO_DB env var, then
    /// ~/Library/Application Support/MarkdownPro/markdownpro.sqlite
    public static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["MARKDOWNPRO_DB"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("MarkdownPro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("markdownpro.sqlite").path
    }

    public static func open(path: String? = nil) throws -> SQLiteConnection {
        let resolved = path ?? defaultPath()
        let parent = (resolved as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let connection = try SQLiteConnection(path: resolved)
        try migrate(connection)
        return connection
    }

    static func migrate(_ db: SQLiteConnection) throws {
        let version = try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
        if version < 1 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS projects (
                        id INTEGER PRIMARY KEY,
                        name TEXT NOT NULL,
                        color TEXT NOT NULL DEFAULT '#5E6AD2',
                        archived INTEGER NOT NULL DEFAULT 0,
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL
                    )
                    """)
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS tasks (
                        id INTEGER PRIMARY KEY,
                        project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                        title TEXT NOT NULL,
                        details TEXT NOT NULL DEFAULT '',
                        status TEXT NOT NULL DEFAULT 'todo'
                            CHECK (status IN ('backlog','todo','in_progress','done','canceled')),
                        priority TEXT NOT NULL DEFAULT 'none'
                            CHECK (priority IN ('urgent','high','medium','low','none')),
                        due_date TEXT,
                        sort_order REAL NOT NULL DEFAULT 0,
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL
                    )
                    """)
                try db.execute("CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id, status)")
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS subtasks (
                        id INTEGER PRIMARY KEY,
                        task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                        title TEXT NOT NULL,
                        done INTEGER NOT NULL DEFAULT 0,
                        sort_order REAL NOT NULL DEFAULT 0
                    )
                    """)
                try db.execute("CREATE INDEX IF NOT EXISTS idx_subtasks_task ON subtasks(task_id)")
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS labels (
                        id INTEGER PRIMARY KEY,
                        name TEXT NOT NULL UNIQUE,
                        color TEXT NOT NULL DEFAULT '#8B5CF6'
                    )
                    """)
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS task_labels (
                        task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                        label_id INTEGER NOT NULL REFERENCES labels(id) ON DELETE CASCADE,
                        PRIMARY KEY (task_id, label_id)
                    )
                    """)
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS activity (
                        id INTEGER PRIMARY KEY,
                        task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                        actor TEXT NOT NULL DEFAULT 'user',
                        kind TEXT NOT NULL DEFAULT 'note',
                        message TEXT NOT NULL,
                        created_at TEXT NOT NULL
                    )
                    """)
                try db.execute("CREATE INDEX IF NOT EXISTS idx_activity_task ON activity(task_id)")
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS documents (
                        id INTEGER PRIMARY KEY,
                        task_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE,
                        project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE,
                        path TEXT NOT NULL,
                        title TEXT NOT NULL DEFAULT '',
                        created_at TEXT NOT NULL
                    )
                    """)
                try db.execute("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            try db.transaction {
                // Guard each ALTER by column existence so a partially
                // upgraded DB (crash between processes) migrates cleanly.
                let docCols = try db.query("PRAGMA table_info(documents)").map { $0.string("name") }
                if !docCols.contains("kind") {
                    try db.execute("ALTER TABLE documents ADD COLUMN kind TEXT NOT NULL DEFAULT 'note'")
                }
                if !docCols.contains("state") {
                    try db.execute("ALTER TABLE documents ADD COLUMN state TEXT")
                }
                if !docCols.contains("round") {
                    try db.execute("ALTER TABLE documents ADD COLUMN round INTEGER NOT NULL DEFAULT 1")
                }
                if !docCols.contains("updated_at") {
                    try db.execute("ALTER TABLE documents ADD COLUMN updated_at TEXT")
                }
                let taskCols = try db.query("PRAGMA table_info(tasks)").map { $0.string("name") }
                if !taskCols.contains("attention") {
                    try db.execute("ALTER TABLE tasks ADD COLUMN attention TEXT")
                }
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS annotations (
                        id INTEGER PRIMARY KEY,
                        document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                        round INTEGER NOT NULL,
                        quote TEXT NOT NULL,
                        prefix TEXT NOT NULL DEFAULT '',
                        suffix TEXT NOT NULL DEFAULT '',
                        comment TEXT NOT NULL,
                        author TEXT NOT NULL DEFAULT 'user',
                        state TEXT NOT NULL DEFAULT 'open',
                        reply TEXT,
                        created_at TEXT NOT NULL,
                        resolved_at TEXT
                    )
                    """)
                try db.execute("CREATE INDEX IF NOT EXISTS idx_annotations_document ON annotations(document_id)")
                try db.execute("PRAGMA user_version = 2")
            }
        }
    }
}
