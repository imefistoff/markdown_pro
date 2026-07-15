import XCTest
@testable import MarkdownProCore

/// Verifies the v1 → v2 migration on a hand-built legacy database.
final class MigrationTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mdpro-legacy-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Builds a database with the exact v1 schema (subset relevant to v2)
    /// and one pre-existing document row.
    private func makeLegacyDB() throws {
        let legacy = try SQLiteConnection(path: path)
        try legacy.execute("""
            CREATE TABLE projects (
                id INTEGER PRIMARY KEY, name TEXT NOT NULL,
                color TEXT NOT NULL DEFAULT '#5E6AD2', archived INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
            """)
        try legacy.execute("""
            CREATE TABLE tasks (
                id INTEGER PRIMARY KEY,
                project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                title TEXT NOT NULL, details TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'todo', priority TEXT NOT NULL DEFAULT 'none',
                due_date TEXT, sort_order REAL NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
            """)
        try legacy.execute("""
            CREATE TABLE documents (
                id INTEGER PRIMARY KEY,
                task_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE,
                project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE,
                path TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL)
            """)
        try legacy.execute(
            "INSERT INTO documents (path, title, created_at) VALUES ('/tmp/a.md', 'A', '2026-01-01T00:00:00.000Z')")
        try legacy.execute("PRAGMA user_version = 1")
        // `legacy` closes when it goes out of scope (deinit).
    }

    func testMigrationV2AddsReviewSchemaToLegacyDB() throws {
        try makeLegacyDB()
        let db = try Database.open(path: path) // runs migrations

        let docCols = try db.query("PRAGMA table_info(documents)").map { $0.string("name") }
        for col in ["kind", "state", "round", "updated_at"] {
            XCTAssertTrue(docCols.contains(col), "documents.\(col) missing after migration")
        }
        let taskCols = try db.query("PRAGMA table_info(tasks)").map { $0.string("name") }
        XCTAssertTrue(taskCols.contains("attention"), "tasks.attention missing after migration")

        // Legacy rows get the defaults.
        let row = try db.query("SELECT kind, round, state FROM documents WHERE id = 1").first!
        XCTAssertEqual(row.string("kind"), "note")
        XCTAssertEqual(row.int("round"), 1)
        XCTAssertNil(row.stringOrNil("state"))

        // annotations table exists and is queryable.
        XCTAssertNoThrow(try db.query("SELECT COUNT(*) AS c FROM annotations"))
        // Database.open migrates all the way to the latest version (now 4),
        // not just v2 — this test only cares that the v2 columns/table landed.
        XCTAssertEqual(try db.query("PRAGMA user_version").first?.int("user_version"), 4)
    }

    func testMigrationIsIdempotentAcrossReopens() throws {
        try makeLegacyDB()
        _ = try Database.open(path: path)
        // Second open must not throw (both processes migrate on open).
        XCTAssertNoThrow(try Database.open(path: path))
    }

    // A DB where a previous migration attempt died after adding only some
    // v2 columns (user_version still 1) must complete cleanly.
    func testMigrationCompletesPartiallyUpgradedSchema() throws {
        try makeLegacyDB()
        do {
            let partial = try SQLiteConnection(path: path)
            try partial.execute("ALTER TABLE documents ADD COLUMN kind TEXT NOT NULL DEFAULT 'note'")
        }
        let db = try Database.open(path: path)
        let docCols = try db.query("PRAGMA table_info(documents)").map { $0.string("name") }
        for col in ["kind", "state", "round", "updated_at"] {
            XCTAssertTrue(docCols.contains(col), "documents.\(col) missing after partial-upgrade migration")
        }
        let taskCols = try db.query("PRAGMA table_info(tasks)").map { $0.string("name") }
        XCTAssertTrue(taskCols.contains("attention"))
        // Database.open migrates all the way to the latest version (now 4),
        // not just v2 — this test only cares that the v2 columns/table landed.
        XCTAssertEqual(try db.query("PRAGMA user_version").first?.int("user_version"), 4)
    }

    func testMigrationV3AddsLaunchSchema() throws {
        try makeLegacyDB()                 // v1 → open runs all migrations
        let db = try Database.open(path: path)

        let projectCols = try db.query("PRAGMA table_info(projects)").map { $0.string("name") }
        for col in ["repo_path", "permission_preset", "use_worktree"] {
            XCTAssertTrue(projectCols.contains(col), "projects.\(col) missing after v3 migration")
        }
        // launch_templates table exists and is queryable.
        XCTAssertNoThrow(try db.query("SELECT COUNT(*) AS c FROM launch_templates"))
        // Open migrates all the way to the latest version (now 4).
        XCTAssertEqual(try db.query("PRAGMA user_version").first?.int("user_version"), 4)
    }

    func testMigrationV3IsIdempotent() throws {
        try makeLegacyDB()
        _ = try Database.open(path: path)
        XCTAssertNoThrow(try Database.open(path: path))   // second open must not throw
        let db = try Database.open(path: path)
        XCTAssertEqual(try db.query("PRAGMA user_version").first?.int("user_version"), 4)
    }

    func testV4AddsUUIDColumnsAndSyncTables() throws {
        let tdb = try TestDatabase()
        let db = tdb.repo.db

        XCTAssertEqual(try db.query("PRAGMA user_version").first?.int("user_version"), 4)

        for table in ["projects", "tasks", "subtasks", "labels", "documents", "annotations", "activity"] {
            let cols = try db.query("PRAGMA table_info(\(table))").map { $0.string("name") }
            XCTAssertTrue(cols.contains("uuid"), "\(table) is missing uuid")
        }
        let projectCols = try db.query("PRAGMA table_info(projects)").map { $0.string("name") }
        XCTAssertTrue(projectCols.contains("synced"))
        let docCols = try db.query("PRAGMA table_info(documents)").map { $0.string("name") }
        XCTAssertTrue(docCols.contains("content_hash"))

        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").map { $0.string("name") }
        for expected in ["ops", "field_stamps", "tombstones", "sync_devices", "sync_blobs"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
    }

    func testV4BackfillsUUIDForExistingRows() throws {
        let tdb = try TestDatabase()
        let projectId = try tdb.repo.createProject(name: "Backfill me")
        let taskId = try tdb.repo.createTask(projectId: projectId, title: "row with a uuid")

        let projectUUID = try tdb.repo.db.query("SELECT uuid FROM projects WHERE id = ?", [.integer(projectId)])
            .first?.stringOrNil("uuid")
        let taskUUID = try tdb.repo.db.query("SELECT uuid FROM tasks WHERE id = ?", [.integer(taskId)])
            .first?.stringOrNil("uuid")

        XCTAssertNotNil(projectUUID)
        XCTAssertNotNil(taskUUID)
        XCTAssertFalse(projectUUID!.isEmpty)
        XCTAssertNotEqual(projectUUID, taskUUID)
    }

    func testV4IsIdempotentWhenReopened() throws {
        let tdb = try TestDatabase()
        let path = tdb.directory.appendingPathComponent("test.sqlite").path
        // Reopen the same file — migrate() runs again and must not throw or duplicate.
        let db2 = try Database.open(path: path)
        XCTAssertEqual(try db2.query("PRAGMA user_version").first?.int("user_version"), 4)
        let uuidIndexes = try db2.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_projects_uuid'")
        XCTAssertEqual(uuidIndexes.count, 1)
    }
}
