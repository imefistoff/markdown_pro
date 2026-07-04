# Review Center & Workflow Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a review loop to MarkdownPro: Claude submits markdown proposals via MCP, the user annotates them inline (select text → comment) and issues verdicts (approve / request changes / reject) that drive task state automatically.

**Architecture:** Schema v2 adds a document lifecycle (`kind`/`state`/`round`), an `annotations` table (W3C TextQuoteSelector anchoring), and an orthogonal `tasks.attention` flag. All mutations go through `Repository` (shared by app + MCP server). The annotation UI extends the existing `renderer.html` WKWebView with a JS layer (CSS Custom Highlight API); native SwiftUI provides the queue, comments panel, and verdict bar.

**Tech Stack:** Swift 5.9 / SwiftUI (macOS 14+), raw SQLite3 (no GRDB), WKWebView + vanilla JS, hand-rolled MCP JSON-RPC over stdio. Spec: `docs/superpowers/specs/2026-07-04-review-center-design.md`.

## Global Constraints

- No external Swift dependencies anywhere (no SwiftPM deps beyond `../Core`).
- Qualify ambiguous names: `SwiftUI.Label` for the view, `MarkdownProCore.Label` / `MarkdownProCore.Annotation` for models. The task model is `TaskItem`, never `Task`.
- Dates are TEXT columns: ISO-8601 with fractional seconds via `DateCoding.encode`, plain `yyyy-MM-dd` for due dates.
- Every meaningful mutation goes through `Repository` with activity-log attribution: `actor` is `"user"` from the app, `"claude"` from the MCP server.
- Schema changes bump `PRAGMA user_version` with an idempotent, ordered migration in `Core/Sources/MarkdownProCore/Database.swift`. This plan takes the schema from version 1 to version 2.
- Never add a write path that bypasses the shared SQLite file; the app picks up MCP writes by polling `PRAGMA data_version` (1.5 s).
- Tests run against throwaway SQLite files (`NSTemporaryDirectory()`), never the real DB. `MARKDOWNPRO_DB` overrides the DB path for manual testing.
- New app files go under `MarkdownPro/` — the Xcode 16 synchronized-folder project adds them to the target automatically. Web resources are flattened into `Contents/Resources/`, so file names must stay unique.
- New raw-value vocabulary (fixed, use everywhere): document kinds `note|wiki|proposal`; document states `needs_review|changes_requested|approved|rejected|superseded`; task attention `needs_review|changes_requested|ready_to_execute|executing`; annotation states `open|addressed`.

**Before you start:** the working tree already contains uncommitted changes (Core tests, UI tweaks, `renderer.html` edits, project file). Commit them as a baseline first (`git add -A && git commit -m "chore: baseline before review-center work"`) so each task's commit stays scoped. Confirm with the user if anything there looks half-done.

Build/test commands used throughout:

```bash
# Core tests
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro/Core && swift test

# App build
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro && \
  xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build

# MCP server build
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro/mcp-server && swift build -c release
```

---

### Task 1: Schema migration v2

**Files:**
- Modify: `Core/Sources/MarkdownProCore/Database.swift` (add v2 block after the `if version < 1` block, `Database.swift:106`)
- Test: `Core/Tests/MarkdownProCoreTests/MigrationTests.swift` (create)

**Interfaces:**
- Consumes: `SQLiteConnection.execute/query/transaction`, existing `Database.migrate`.
- Produces: schema v2 — `documents.kind/state/round/updated_at`, `tasks.attention`, table `annotations`, `PRAGMA user_version = 2`. Later tasks assume these exact column names.

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/MarkdownProCoreTests/MigrationTests.swift`:

```swift
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
        XCTAssertEqual(try db.query("PRAGMA user_version").first?.int("user_version"), 2)
    }

    func testMigrationIsIdempotentAcrossReopens() throws {
        try makeLegacyDB()
        _ = try Database.open(path: path)
        // Second open must not throw (both processes migrate on open).
        XCTAssertNoThrow(try Database.open(path: path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/maximsargarovschi/Documents/Developer/markdown_pro/Core && swift test --filter MigrationTests`
Expected: FAIL — `documents.kind missing after migration` (v2 block doesn't exist yet).

- [ ] **Step 3: Implement the migration**

In `Core/Sources/MarkdownProCore/Database.swift`, insert after the closing brace of `if version < 1 { ... }` (currently line 106, before the closing brace of `migrate`):

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/maximsargarovschi/Documents/Developer/markdown_pro/Core && swift test`
Expected: PASS — both MigrationTests and all pre-existing RepositoryTests (v1 path untouched; fresh DBs run v1 then v2).

- [ ] **Step 5: Commit**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro
git add Core/Sources/MarkdownProCore/Database.swift Core/Tests/MarkdownProCoreTests/MigrationTests.swift
git commit -m "feat(core): schema v2 — document lifecycle, annotations table, task attention"
```

---

### Task 2: Core models + document/attention foundations in Repository

**Files:**
- Modify: `Core/Sources/MarkdownProCore/Models.swift` (add enums + `Annotation`; extend `LinkedDocument`, `TaskItem`)
- Modify: `Core/Sources/MarkdownProCore/Repository.swift` (decode new columns; `document(id:)`, `submitForReview`, `setAttention`, `listTasks(attention:)`, `attachDocument(kind:)`)
- Test: `Core/Tests/MarkdownProCoreTests/ReviewTests.swift` (create)

**Interfaces:**
- Consumes: schema v2 from Task 1.
- Produces (exact signatures later tasks rely on):
  - `public enum DocumentKind: String — note, wiki, proposal`
  - `public enum DocumentState: String — needsReview="needs_review", changesRequested="changes_requested", approved, rejected, superseded`
  - `public enum TaskAttention: String, Identifiable — needsReview="needs_review", changesRequested="changes_requested", readyToExecute="ready_to_execute", executing` + `displayName`
  - `public enum AnnotationState: String — open, addressed`
  - `public struct Annotation` (fields below)
  - `LinkedDocument` gains `kind: DocumentKind`, `state: DocumentState?`, `round: Int`, `updatedAt: Date?`
  - `TaskItem` gains `attention: TaskAttention?`
  - `Repository.document(id:) throws -> LinkedDocument?`
  - `Repository.submitForReview(taskId:path:title:actor:) throws -> Int64` (`@discardableResult`, title/actor defaulted)
  - `Repository.setAttention(taskId:attention:actor:) throws`
  - `Repository.listTasks(projectId:status:labelName:attention:)` (new defaulted param)
  - `Repository.attachDocument(taskId:projectId:path:title:kind:)` (new defaulted param)
  - `public enum RepositoryError: Error — notFound(String)`

- [ ] **Step 1: Add the model types**

In `Core/Sources/MarkdownProCore/Models.swift`, append after the `TaskPriority` enum (line 54):

```swift
public enum DocumentKind: String, CaseIterable, Codable, Sendable {
    case note
    case wiki
    case proposal
}

/// Review lifecycle; only meaningful for `kind == .proposal`.
public enum DocumentState: String, CaseIterable, Codable, Sendable {
    case needsReview = "needs_review"
    case changesRequested = "changes_requested"
    case approved
    case rejected
    case superseded

    public var displayName: String {
        switch self {
        case .needsReview: return "Needs review"
        case .changesRequested: return "Changes requested"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        case .superseded: return "Superseded"
        }
    }
}

/// Orthogonal workflow flag on tasks; NULL means nothing pending.
public enum TaskAttention: String, CaseIterable, Codable, Identifiable, Sendable {
    case needsReview = "needs_review"
    case changesRequested = "changes_requested"
    case readyToExecute = "ready_to_execute"
    case executing

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .needsReview: return "Needs review"
        case .changesRequested: return "Changes requested"
        case .readyToExecute: return "Ready to execute"
        case .executing: return "Executing"
        }
    }
}

public enum AnnotationState: String, CaseIterable, Codable, Sendable {
    case open
    case addressed
}

/// An inline review comment anchored by quote + surrounding context
/// (W3C TextQuoteSelector), so it survives document edits between rounds.
public struct Annotation: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var documentId: Int64
    /// Round the comment was made in.
    public var round: Int
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var comment: String
    /// "user" or "claude".
    public var author: String
    public var state: AnnotationState
    /// Claude's response once addressed.
    public var reply: String?
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(id: Int64, documentId: Int64, round: Int, quote: String, prefix: String,
                suffix: String, comment: String, author: String, state: AnnotationState,
                reply: String?, createdAt: Date, resolvedAt: Date?) {
        self.id = id
        self.documentId = documentId
        self.round = round
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.comment = comment
        self.author = author
        self.state = state
        self.reply = reply
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}
```

- [ ] **Step 2: Extend `LinkedDocument` and `TaskItem`**

In `Models.swift`, replace the whole `LinkedDocument` struct with:

```swift
public struct LinkedDocument: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var taskId: Int64?
    public var projectId: Int64?
    public var path: String
    public var title: String
    public var createdAt: Date
    public var kind: DocumentKind
    /// Review lifecycle; nil for non-proposals.
    public var state: DocumentState?
    public var round: Int
    public var updatedAt: Date?

    public init(id: Int64, taskId: Int64?, projectId: Int64?, path: String, title: String,
                createdAt: Date, kind: DocumentKind = .note, state: DocumentState? = nil,
                round: Int = 1, updatedAt: Date? = nil) {
        self.id = id
        self.taskId = taskId
        self.projectId = projectId
        self.path = path
        self.title = title
        self.createdAt = createdAt
        self.kind = kind
        self.state = state
        self.round = round
        self.updatedAt = updatedAt
    }
}
```

In the `TaskItem` struct, add a stored property after `documentCount`:

```swift
    public var attention: TaskAttention?
```

and replace its initializer with:

```swift
    public init(id: Int64, projectId: Int64, title: String, details: String,
                status: TaskStatus, priority: TaskPriority, dueDate: Date?,
                sortOrder: Double, createdAt: Date, updatedAt: Date,
                labels: [Label] = [], subtaskCount: Int = 0, subtaskDoneCount: Int = 0,
                documentCount: Int = 0, attention: TaskAttention? = nil) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.details = details
        self.status = status
        self.priority = priority
        self.dueDate = dueDate
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.labels = labels
        self.subtaskCount = subtaskCount
        self.subtaskDoneCount = subtaskDoneCount
        self.documentCount = documentCount
        self.attention = attention
    }
```

- [ ] **Step 3: Write the failing tests**

Create `Core/Tests/MarkdownProCoreTests/ReviewTests.swift`:

```swift
import XCTest
@testable import MarkdownProCore

/// Review-loop data layer: proposals, rounds, attention, annotations, verdicts.
/// Verdict/annotation tests arrive in later tasks; this file starts with
/// submit/attention/decode coverage and grows.
final class ReviewTests: XCTestCase {
    private var tempPath = ""
    private var repo: Repository!
    private var projectId: Int64 = 0
    private var taskId: Int64 = 0

    override func setUpWithError() throws {
        tempPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mdpro-review-\(UUID().uuidString).sqlite")
        repo = Repository(db: try Database.open(path: tempPath))
        projectId = try repo.createProject(name: "P")
        taskId = try repo.createTask(projectId: projectId, title: "T", status: .inProgress)
    }

    override func tearDownWithError() throws {
        repo = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: tempPath + suffix)
        }
    }

    // submit_for_review: creates a needs_review proposal and flags the task
    func testSubmitForReviewCreatesProposalAndFlagsTask() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/proposal.md", title: "Fix crash")
        let doc = try repo.document(id: docId)!
        XCTAssertEqual(doc.kind, .proposal)
        XCTAssertEqual(doc.state, .needsReview)
        XCTAssertEqual(doc.round, 1)
        XCTAssertEqual(doc.taskId, taskId)
        XCTAssertEqual(try repo.getTask(id: taskId)!.task.attention, .needsReview)
        XCTAssertTrue(try repo.getTask(id: taskId)!.activity
            .contains { $0.actor == "claude" && $0.message.contains("submitted") })
    }

    // Resubmitting the same task+path bumps the round instead of duplicating
    func testResubmitBumpsRound() throws {
        let first = try repo.submitForReview(taskId: taskId, path: "/tmp/proposal.md", title: nil)
        let second = try repo.submitForReview(taskId: taskId, path: "/tmp/proposal.md", title: nil)
        XCTAssertEqual(first, second, "resubmission must reuse the document row")
        XCTAssertEqual(try repo.document(id: first)!.round, 2)
        XCTAssertEqual(try repo.document(id: first)!.state, .needsReview)
    }

    // setAttention flips and clears the flag with attribution
    func testSetAttention() throws {
        try repo.setAttention(taskId: taskId, attention: .executing)
        XCTAssertEqual(try repo.getTask(id: taskId)!.task.attention, .executing)
        try repo.setAttention(taskId: taskId, attention: nil)
        XCTAssertNil(try repo.getTask(id: taskId)!.task.attention)
    }

    // listTasks(attention:) filters
    func testListTasksAttentionFilter() throws {
        let other = try repo.createTask(projectId: projectId, title: "Other")
        try repo.setAttention(taskId: taskId, attention: .readyToExecute)
        let hits = try repo.listTasks(attention: .readyToExecute).map(\.id)
        XCTAssertEqual(hits, [taskId])
        XCTAssertFalse(hits.contains(other))
    }

    // attach_document kind lands in the row; default stays note
    func testAttachDocumentKind() throws {
        let wiki = try repo.attachDocument(taskId: nil, projectId: projectId,
                                           path: "/tmp/wiki.md", title: "Wiki", kind: .wiki)
        XCTAssertEqual(try repo.document(id: wiki)!.kind, .wiki)
        let plain = try repo.attachDocument(taskId: taskId, projectId: nil,
                                            path: "/tmp/n.md", title: nil)
        XCTAssertEqual(try repo.document(id: plain)!.kind, .note)
        XCTAssertNil(try repo.document(id: plain)!.state)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd /Users/maximsargarovschi/Documents/Developer/markdown_pro/Core && swift test --filter ReviewTests`
Expected: FAIL to compile — `submitForReview`, `document(id:)`, `setAttention`, `attention:` label don't exist yet.

- [ ] **Step 5: Implement the Repository foundations**

In `Core/Sources/MarkdownProCore/Repository.swift`:

**5a.** Add an error type right below the `Repository` class opening (after `private func now()`):

```swift
    public enum RepositoryError: Error, CustomStringConvertible {
        case notFound(String)

        public var description: String {
            switch self {
            case .notFound(let m): return "not found: \(m)"
            }
        }
    }
```

**5b.** In `taskItem(from:)`, pass the new field — replace the method with:

```swift
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
```

**5c.** Extend `listTasks` — replace its signature and add the clause (body otherwise unchanged):

```swift
    public func listTasks(projectId: Int64? = nil, status: TaskStatus? = nil,
                          labelName: String? = nil, attention: TaskAttention? = nil) throws -> [TaskItem] {
```

and after the `if let labelName { ... }` block add:

```swift
        if let attention {
            clauses.append("t.attention = ?")
            bindings.append(.text(attention.rawValue))
        }
```

**5d.** Add a shared document decoder + fetch (place in the `// MARK: - Documents` section):

```swift
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
```

Then switch the two existing document decode sites to the helper:
- In `getTask(id:)`, replace the `documents` mapping closure with `.map(linkedDocument(from:))`.
- In `documents(projectId:)`, replace the trailing mapping closure with `.map(linkedDocument(from:))` — but note that query selects `d.*`, which is what the helper reads, so this is a drop-in.

**5e.** Extend `attachDocument` — replace the method with:

```swift
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
```

**5f.** Add the review section (new `// MARK: - Review` after `// MARK: - Documents`):

```swift
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
    /// the user's verdict. Resubmitting the same task+path bumps the round.
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
            try setAttentionColumn(taskId: taskId, TaskAttention.needsReview.rawValue)
            return docId
        }
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /Users/maximsargarovschi/Documents/Developer/markdown_pro/Core && swift test`
Expected: PASS — ReviewTests (5 tests) plus all earlier suites.

- [ ] **Step 7: Verify the app still compiles against the changed Core**

Run: `cd /Users/maximsargarovschi/Documents/Developer/markdown_pro && xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED` (all new init params are defaulted, so existing call sites compile).

- [ ] **Step 8: Commit**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro
git add Core/Sources/MarkdownProCore/Models.swift Core/Sources/MarkdownProCore/Repository.swift Core/Tests/MarkdownProCoreTests/ReviewTests.swift
git commit -m "feat(core): review models, submit_for_review, task attention"
```

---

### Task 3: Annotations CRUD, verdicts, review queue

**Files:**
- Modify: `Core/Sources/MarkdownProCore/Repository.swift` (extend the `// MARK: - Review` section)
- Test: `Core/Tests/MarkdownProCoreTests/ReviewTests.swift` (extend)

**Interfaces:**
- Consumes: Task 2's types and `submitForReview`.
- Produces:
  - `Repository.addAnnotation(documentId:quote:prefix:suffix:comment:author:) throws -> Int64` (`@discardableResult`; prefix/suffix default `""`, author defaults `"user"`)
  - `Repository.updateAnnotation(id:comment:) throws`
  - `Repository.deleteAnnotation(id:) throws`
  - `Repository.annotations(documentId:) throws -> [Annotation]` (ordered by round, id)
  - `Repository.resolveAnnotation(id:reply:actor:) throws` (actor defaults `"claude"`)
  - `public enum Repository.ReviewVerdict: String — approve, requestChanges="request_changes", reject`
  - `Repository.applyVerdict(_:documentId:actor:) throws` (actor defaults `"user"`)
  - `public struct Repository.ReviewQueueItem: Identifiable — document: LinkedDocument, taskId: Int64, taskTitle: String, projectId: Int64, projectName: String; id == document.id`
  - `Repository.reviewQueue() throws -> [ReviewQueueItem]` (proposals in `needs_review`, newest activity first)

- [ ] **Step 1: Write the failing tests**

Append to `ReviewTests` in `Core/Tests/MarkdownProCoreTests/ReviewTests.swift`:

```swift
    // Annotation lifecycle: open on the current round, addressed with reply
    func testAnnotationLifecycle() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
        let annId = try repo.addAnnotation(documentId: docId, quote: "use SQLite",
                                           prefix: "we should ", suffix: " for this",
                                           comment: "agreed, but WAL mode please")
        var anns = try repo.annotations(documentId: docId)
        XCTAssertEqual(anns.count, 1)
        XCTAssertEqual(anns[0].state, .open)
        XCTAssertEqual(anns[0].round, 1)
        XCTAssertEqual(anns[0].author, "user")

        try repo.updateAnnotation(id: annId, comment: "WAL + busy timeout")
        try repo.resolveAnnotation(id: annId, reply: "done — WAL enabled in SQLite.swift")
        anns = try repo.annotations(documentId: docId)
        XCTAssertEqual(anns[0].state, .addressed)
        XCTAssertEqual(anns[0].comment, "WAL + busy timeout")
        XCTAssertEqual(anns[0].reply, "done — WAL enabled in SQLite.swift")
        XCTAssertNotNil(anns[0].resolvedAt)

        try repo.deleteAnnotation(id: annId)
        XCTAssertTrue(try repo.annotations(documentId: docId).isEmpty)
    }

    // Annotations made after a resubmission carry the new round
    func testAnnotationTracksDocumentRound() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
        _ = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md") // round 2
        let annId = try repo.addAnnotation(documentId: docId, quote: "q", comment: "c")
        XCTAssertEqual(try repo.annotations(documentId: docId).first { $0.id == annId }?.round, 2)
    }

    // Approve: doc approved, task ready_to_execute
    func testApproveVerdict() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
        try repo.applyVerdict(.approve, documentId: docId)
        XCTAssertEqual(try repo.document(id: docId)!.state, .approved)
        XCTAssertEqual(try repo.getTask(id: taskId)!.task.attention, .readyToExecute)
        XCTAssertTrue(try repo.getTask(id: taskId)!.activity
            .contains { $0.actor == "user" && $0.kind == "review" && $0.message.contains("approved") })
    }

    // Request changes: doc + attention both changes_requested
    func testRequestChangesVerdict() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
        try repo.applyVerdict(.requestChanges, documentId: docId)
        XCTAssertEqual(try repo.document(id: docId)!.state, .changesRequested)
        XCTAssertEqual(try repo.getTask(id: taskId)!.task.attention, .changesRequested)
    }

    // Reject: doc rejected, attention cleared, task back to todo
    func testRejectVerdictMovesTaskToTodo() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
        try repo.applyVerdict(.reject, documentId: docId)
        XCTAssertEqual(try repo.document(id: docId)!.state, .rejected)
        let task = try repo.getTask(id: taskId)!.task
        XCTAssertNil(task.attention)
        XCTAssertEqual(task.status, .todo)
        XCTAssertTrue(try repo.getTask(id: taskId)!.activity
            .contains { $0.message == "moved from In Progress to Todo" })
    }

    // Queue: needs_review proposals only, with task/project context
    func testReviewQueueContents() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md", title: "Proposal P")
        _ = try repo.attachDocument(taskId: taskId, projectId: nil, path: "/tmp/n.md", title: "Note")
        var queue = try repo.reviewQueue()
        XCTAssertEqual(queue.map(\.id), [docId])
        XCTAssertEqual(queue[0].taskTitle, "T")
        XCTAssertEqual(queue[0].projectName, "P")
        try repo.applyVerdict(.approve, documentId: docId)
        queue = try repo.reviewQueue()
        XCTAssertTrue(queue.isEmpty, "verdicted docs leave the queue")
    }

    // Verdict on an unknown document fails loudly
    func testVerdictOnMissingDocumentThrows() throws {
        XCTAssertThrowsError(try repo.applyVerdict(.approve, documentId: 999))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/maximsargarovschi/Documents/Developer/markdown_pro/Core && swift test --filter ReviewTests`
Expected: FAIL to compile — `addAnnotation`, `applyVerdict`, `reviewQueue` missing.

- [ ] **Step 3: Implement annotations, verdicts, queue**

Append inside the `// MARK: - Review` section of `Repository.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/maximsargarovschi/Documents/Developer/markdown_pro/Core && swift test`
Expected: PASS — all suites (MigrationTests, RepositoryTests, ReviewTests with 12 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro
git add Core/Sources/MarkdownProCore/Repository.swift Core/Tests/MarkdownProCoreTests/ReviewTests.swift
git commit -m "feat(core): annotations CRUD, review verdicts, review queue"
```

---

### Task 4: MCP tools

**Files:**
- Modify: `mcp-server/Sources/markdownpro-mcp/ToolCatalog.swift` (4 new tools; extend `attach_document`, `list_tasks`)
- Modify: `mcp-server/Sources/markdownpro-mcp/MCPServer.swift` (dispatch cases + `Encode` additions)

**Interfaces:**
- Consumes: everything from Tasks 2–3.
- Produces MCP tools: `submit_for_review(task_id, path, title?)`, `get_review_feedback(document_id)`, `resolve_annotation(annotation_id, reply)`, `set_attention(task_id, attention?)`; `attach_document` gains `kind` (`note|wiki`); `list_tasks` gains `attention` filter; `get_task`/`list_tasks` output includes document `kind/state/round`, `open_annotations`, and task `attention`.

- [ ] **Step 1: Add tool definitions**

In `ToolCatalog.swift`, add below `priorityProp` (line 29):

```swift
    private static let attentionProp: [String: Any] = [
        "type": "string",
        "enum": ["needs_review", "changes_requested", "ready_to_execute", "executing"],
        "description": "Workflow attention flag"
    ]
```

In the `definitions` array: add `"attention": attentionProp` to the `list_tasks` properties; add to `attach_document` properties:

```swift
                "kind": ["type": "string", "enum": ["note", "wiki"],
                         "description": "Document kind (default note). Use submit_for_review for proposals."],
```

and append these four tools at the end of the array (after `add_label`):

```swift
        tool("submit_for_review",
             "Submit a markdown proposal for the user's review. Registers the file as a proposal " +
             "on the task, flags the task needs_review, and puts it in the app's Review queue. " +
             "Resubmitting the same file after addressing feedback starts a new round.",
             properties: [
                "task_id": ["type": "integer", "description": "Task the proposal belongs to"],
                "path": ["type": "string", "description": "Absolute path to the .md file (must exist)"],
                "title": ["type": "string", "description": "Display title (defaults to file name)"]
             ],
             required: ["task_id", "path"]),

        tool("get_review_feedback",
             "Get the review state and the user's inline annotations for a proposal. " +
             "Open annotations on a changes_requested doc are the actionable feedback: " +
             "each has the quoted text plus surrounding context and the user's comment.",
             properties: [
                "document_id": ["type": "integer", "description": "Document id (from submit_for_review or get_task)"]
             ],
             required: ["document_id"]),

        tool("resolve_annotation",
             "Mark a review annotation as addressed, with a short reply describing what you did. " +
             "Do this for every open annotation before resubmitting a revised proposal.",
             properties: [
                "annotation_id": ["type": "integer", "description": "Annotation id (from get_review_feedback)"],
                "reply": ["type": "string", "description": "What you changed in response"]
             ],
             required: ["annotation_id", "reply"]),

        tool("set_attention",
             "Set or clear a task's workflow attention flag. Set executing when you start " +
             "implementing an approved proposal; clear it (omit attention) when done.",
             properties: [
                "task_id": ["type": "integer", "description": "Task id"],
                "attention": attentionProp
             ],
             required: ["task_id"])
```

- [ ] **Step 2: Add dispatch cases and encoders**

In `MCPServer.swift`:

**2a.** In `callTool`, extend the `list_tasks` case — replace it with:

```swift
        case "list_tasks":
            let status = try string(args, "status").map { raw -> TaskStatus in
                guard let s = TaskStatus(rawValue: raw) else {
                    throw ToolError.badArgument("status must be one of backlog|todo|in_progress|done|canceled")
                }
                return s
            }
            let attention = try string(args, "attention").map { raw -> TaskAttention in
                guard let a = TaskAttention(rawValue: raw) else {
                    throw ToolError.badArgument("attention must be one of needs_review|changes_requested|ready_to_execute|executing")
                }
                return a
            }
            let tasks = try repo.listTasks(projectId: int(args, "project_id"),
                                           status: status,
                                           labelName: string(args, "label"),
                                           attention: attention)
            return jsonText(tasks.map(Encode.taskSummary))
```

**2b.** Extend the `attach_document` case — replace the `repo.attachDocument` call with:

```swift
            let kind = string(args, "kind").flatMap(DocumentKind.init(rawValue:)) ?? .note
            let id = try repo.attachDocument(taskId: taskId, projectId: projectId,
                                             path: path, title: string(args, "title"), kind: kind)
```

**2c.** Replace the `get_task` case so documents carry review info:

```swift
        case "get_task":
            let id = try requireInt(args, "task_id")
            guard let detail = try repo.getTask(id: id) else { throw ToolError.notFound("task \(id)") }
            var dict = Encode.taskDetail(detail)
            dict["linked_documents"] = try detail.documents.map { doc -> [String: Any] in
                var d = Encode.document(doc)
                if doc.kind == .proposal {
                    d["open_annotations"] = try repo.annotations(documentId: doc.id)
                        .filter { $0.state == .open }.count
                }
                return d
            }
            return jsonText(dict)
```

**2d.** Add the four new cases before `default:`:

```swift
        case "submit_for_review":
            let taskId = try requireInt(args, "task_id")
            let path = try requireString(args, "path")
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ToolError.badArgument("file does not exist: \(expanded)")
            }
            guard try repo.getTask(id: taskId) != nil else { throw ToolError.notFound("task \(taskId)") }
            let docId = try repo.submitForReview(taskId: taskId, path: expanded, title: string(args, "title"))
            guard let doc = try repo.document(id: docId) else { throw ToolError.notFound("document \(docId)") }
            return jsonText(["document_id": docId, "state": "needs_review", "round": doc.round,
                             "message": "Submitted “\(doc.title)” for review (round \(doc.round))"])

        case "get_review_feedback":
            let docId = try requireInt(args, "document_id")
            guard let doc = try repo.document(id: docId) else { throw ToolError.notFound("document \(docId)") }
            let annotations = try repo.annotations(documentId: docId)
            var dict = Encode.document(doc)
            dict["annotations"] = annotations.map(Encode.annotation)
            dict["open_annotations"] = annotations.filter { $0.state == .open }.count
            return jsonText(dict)

        case "resolve_annotation":
            let annotationId = try requireInt(args, "annotation_id")
            let reply = try requireString(args, "reply")
            try repo.resolveAnnotation(id: annotationId, reply: reply)
            return jsonText(["message": "Annotation \(annotationId) marked addressed"])

        case "set_attention":
            let taskId = try requireInt(args, "task_id")
            guard try repo.getTask(id: taskId) != nil else { throw ToolError.notFound("task \(taskId)") }
            var attention: TaskAttention?
            if let raw = string(args, "attention") {
                guard let parsed = TaskAttention(rawValue: raw) else {
                    throw ToolError.badArgument("attention must be one of needs_review|changes_requested|ready_to_execute|executing")
                }
                attention = parsed
            }
            try repo.setAttention(taskId: taskId, attention: attention)
            return jsonText(["message": attention.map { "Attention set to \($0.rawValue)" } ?? "Attention cleared"])
```

**2e.** In `enum Encode`: add to `taskSummary`, right before `return dict`:

```swift
        if let attention = t.attention { dict["attention"] = attention.rawValue }
```

Replace the `linked_documents` line in `taskDetail` with `dict["linked_documents"] = d.documents.map(Encode.document)` and add two encoders:

```swift
    static func document(_ d: LinkedDocument) -> [String: Any] {
        var dict: [String: Any] = ["id": d.id, "title": d.title, "path": d.path,
                                   "kind": d.kind.rawValue, "round": d.round]
        if let state = d.state { dict["state"] = state.rawValue }
        if let taskId = d.taskId { dict["task_id"] = taskId }
        return dict
    }

    static func annotation(_ a: MarkdownProCore.Annotation) -> [String: Any] {
        var dict: [String: Any] = ["id": a.id, "round": a.round, "quote": a.quote,
                                   "prefix": a.prefix, "suffix": a.suffix,
                                   "comment": a.comment, "author": a.author,
                                   "state": a.state.rawValue]
        if let reply = a.reply { dict["reply"] = reply }
        return dict
    }
```

- [ ] **Step 3: Build the server**

Run: `cd /Users/maximsargarovschi/Documents/Developer/markdown_pro/mcp-server && swift build -c release`
Expected: `Build complete!`

- [ ] **Step 4: Drive the full loop over stdio against a scratch DB**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro/mcp-server
export MARKDOWNPRO_DB=/tmp/mdpro-mcp-e2e.sqlite
rm -f /tmp/mdpro-mcp-e2e.sqlite*
printf '# Proposal\n\nUse SQLite with WAL mode.\n' > /tmp/mdpro-proposal.md

printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_project","arguments":{"name":"QA"}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_task","arguments":{"project_id":1,"title":"Review loop e2e"}}}' \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"submit_for_review","arguments":{"task_id":1,"path":"/tmp/mdpro-proposal.md","title":"WAL proposal"}}}' \
 '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_tasks","arguments":{"attention":"needs_review"}}}' \
 | ./.build/release/markdownpro-mcp 2>/dev/null

# Simulate a user annotation (the app writes these; here we inject directly):
sqlite3 /tmp/mdpro-mcp-e2e.sqlite "INSERT INTO annotations (document_id, round, quote, prefix, suffix, comment, author, state, created_at) VALUES (1,1,'WAL mode','SQLite with ','.','also set busy_timeout','user','open','2026-07-04T00:00:00.000Z'); UPDATE documents SET state='changes_requested' WHERE id=1; UPDATE tasks SET attention='changes_requested' WHERE id=1;"

printf '%s\n' \
 '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_review_feedback","arguments":{"document_id":1}}}' \
 '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"resolve_annotation","arguments":{"annotation_id":1,"reply":"added busy_timeout 3000"}}}' \
 '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"submit_for_review","arguments":{"task_id":1,"path":"/tmp/mdpro-proposal.md"}}}' \
 '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"set_attention","arguments":{"task_id":1,"attention":"executing"}}}' \
 | ./.build/release/markdownpro-mcp 2>/dev/null
```

Expected: id 3 → `"round": 1`; id 4 → one task with `"attention": "needs_review"`; id 5 → one annotation with `"comment": "also set busy_timeout"`, `"state": "open"`; id 7 → `"round": 2`; id 8 → `Attention set to executing`. Also test the loud failure: `submit_for_review` with `"path":"/tmp/does-not-exist.md"` must return `isError: true` with `file does not exist`.

- [ ] **Step 5: Commit**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro
git add mcp-server/Sources/markdownpro-mcp/ToolCatalog.swift mcp-server/Sources/markdownpro-mcp/MCPServer.swift
git commit -m "feat(mcp): submit_for_review, get_review_feedback, resolve_annotation, set_attention"
```

---

### Task 5: Annotation layer in renderer.html

**Files:**
- Modify: `MarkdownPro/Web/renderer.html`

**Interfaces:**
- Consumes: existing `window.renderMarkdown(markdown, baseHref)`.
- Produces the JS API the Swift bridge (Task 6) calls:
  - `window.setReviewAnnotations(list)` — `list` is `[{id: Number, quote, prefix, suffix: String}]`; paints highlights.
  - Posts to `window.webkit.messageHandlers.review` (when the handler exists; the plain reader has none, so `post` is a no-op there):
    - `{type: "selection", quote, prefix, suffix}` — user confirmed a selection (button or `c` key)
    - `{type: "annotationClicked", id}` — user clicked a painted highlight
    - `{type: "anchors", anchored: {"<id>": Bool}}` — after each repaint

- [ ] **Step 1: Add styles and the floating button**

In `renderer.html`, add inside the `<style>` block (before `#empty`):

```css
  ::highlight(review) { background: rgba(255, 196, 0, .38); }
  #annotate-btn {
    position: absolute; display: none; z-index: 10;
    font: 12px/1 -apple-system, BlinkMacSystemFont, sans-serif;
    background: #1f6feb; color: #fff; border: none; border-radius: 6px;
    padding: 5px 10px; cursor: pointer;
    box-shadow: 0 2px 8px rgba(0,0,0,.25);
  }
```

Add the button element right after `<article id="content">…</article>`:

```html
<button id="annotate-btn" type="button">Comment (c)</button>
```

- [ ] **Step 2: Hook the repaint into renderMarkdown**

At the end of `window.renderMarkdown` (after the mermaid `for` loop, still inside the function), add:

```js
    if (window.__reviewRepaint) window.__reviewRepaint();
```

- [ ] **Step 3: Add the review IIFE**

Append a second `<script>` block before `</body>`:

```html
<script>
(function () {
  'use strict';

  var annotations = [];   // [{id, quote, prefix, suffix}] — current round, open
  var anchorRanges = {};  // id -> {start, end} offsets into content.textContent
  var pendingSelection = null;
  var content = document.getElementById('content');
  var btn = document.getElementById('annotate-btn');

  function post(msg) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.review) {
      window.webkit.messageHandlers.review.postMessage(msg);
    }
  }

  function contentText() { return content.textContent; }

  // Convert [start, end) offsets over content.textContent to a DOM Range.
  function textRange(start, end) {
    var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
    var range = document.createRange();
    var pos = 0, node, haveStart = false;
    while ((node = walker.nextNode())) {
      var next = pos + node.data.length;
      if (!haveStart && start < next) { range.setStart(node, start - pos); haveStart = true; }
      if (haveStart && end <= next) { range.setEnd(node, end - pos); return range; }
      pos = next;
    }
    return null;
  }

  // W3C TextQuoteSelector matching: prefer the quote occurrence whose
  // surrounding text matches prefix/suffix; fall back to first occurrence.
  function findAnchor(a) {
    if (!a.quote) return null;
    var text = contentText();
    var from = 0, idx, best = null;
    while ((idx = text.indexOf(a.quote, from)) !== -1) {
      var score = 0;
      if (a.prefix && text.slice(Math.max(0, idx - a.prefix.length), idx) === a.prefix) score++;
      if (a.suffix && text.slice(idx + a.quote.length, idx + a.quote.length + a.suffix.length) === a.suffix) score++;
      if (!best || score > best.score) best = { start: idx, score: score };
      if (score === 2) break;
      from = idx + 1;
    }
    return best ? { start: best.start, end: best.start + a.quote.length } : null;
  }

  function repaint() {
    anchorRanges = {};
    var anchored = {};
    var ranges = [];
    annotations.forEach(function (a) {
      var pos = findAnchor(a);
      anchored[a.id] = !!pos;
      if (pos) {
        anchorRanges[a.id] = pos;
        var r = textRange(pos.start, pos.end);
        if (r) ranges.push(r);
      }
    });
    // CSS Custom Highlight API (Safari 17.2+). Without it, comments still
    // work from the side panel — graceful degradation per spec.
    if (window.Highlight && CSS.highlights) {
      CSS.highlights.delete('review');
      if (ranges.length) CSS.highlights.set('review', new Highlight(...ranges));
    }
    post({ type: 'anchors', anchored: anchored });
  }
  window.__reviewRepaint = repaint;

  window.setReviewAnnotations = function (list) {
    annotations = list || [];
    repaint();
  };

  // Click on a painted highlight -> select its comment in the panel.
  content.addEventListener('click', function (e) {
    var caret = document.caretRangeFromPoint(e.clientX, e.clientY);
    if (!caret) return;
    var probe = document.createRange();
    probe.selectNodeContents(content);
    probe.setEnd(caret.startContainer, caret.startOffset);
    var offset = probe.toString().length;
    for (var id in anchorRanges) {
      if (offset >= anchorRanges[id].start && offset <= anchorRanges[id].end) {
        post({ type: 'annotationClicked', id: Number(id) });
        return;
      }
    }
  });

  function hideButton() {
    btn.style.display = 'none';
    pendingSelection = null;
  }

  function captureSelection() {
    // Only in the Review Center (which installs the handler); the plain
    // reader never shows the comment button.
    if (!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.review)) return;
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) { hideButton(); return; }
    var range = sel.getRangeAt(0);
    if (!content.contains(range.commonAncestorContainer)) { hideButton(); return; }
    var quote = range.toString();
    if (!quote.trim()) { hideButton(); return; }
    var probe = document.createRange();
    probe.selectNodeContents(content);
    probe.setEnd(range.startContainer, range.startOffset);
    var start = probe.toString().length;
    var text = contentText();
    pendingSelection = {
      quote: quote,
      prefix: text.slice(Math.max(0, start - 32), start),
      suffix: text.slice(start + quote.length, start + quote.length + 32)
    };
    var rect = range.getBoundingClientRect();
    btn.style.left = (window.scrollX + rect.left) + 'px';
    btn.style.top = (window.scrollY + rect.bottom + 6) + 'px';
    btn.style.display = 'block';
  }

  function sendPending() {
    if (!pendingSelection) return;
    post({ type: 'selection', quote: pendingSelection.quote,
           prefix: pendingSelection.prefix, suffix: pendingSelection.suffix });
    hideButton();
    window.getSelection().removeAllRanges();
  }

  document.addEventListener('mouseup', function () { setTimeout(captureSelection, 0); });
  // mousedown (not click) so we act before the selection collapses.
  btn.addEventListener('mousedown', function (e) { e.preventDefault(); sendPending(); });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'c' && pendingSelection && !e.metaKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault();
      sendPending();
    }
  });
})();
</script>
```

- [ ] **Step 4: Verify no reader regression**

Run: `cd /Users/maximsargarovschi/Documents/Developer/markdown_pro && xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`.

Launch the app (`open ~/Library/Developer/Xcode/DerivedData/MarkdownPro-*/Build/Products/Debug/MarkdownPro.app`), open any markdown doc in the reader, and confirm: it renders exactly as before (mermaid + code highlighting intact), and selecting text does **not** show the comment button (the plain reader installs no `review` handler, so `captureSelection` bails out early). Interactive annotation behavior is verified in Task 7.

- [ ] **Step 5: Commit**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro
git add MarkdownPro/Web/renderer.html
git commit -m "feat(web): annotation layer — quote anchoring, highlights, selection capture"
```

---

### Task 6: ReviewWebView bridge + Store review state

**Files:**
- Create: `MarkdownPro/Reader/ReviewWebView.swift`
- Modify: `MarkdownPro/Store.swift` (review queue, toast, annotation/verdict methods)

**Interfaces:**
- Consumes: renderer JS API from Task 5; `Repository` review API from Tasks 2–3.
- Produces:
  - `struct ReviewSelection: Equatable { var quote, prefix, suffix: String }`
  - `struct ReviewWebView: NSViewRepresentable` with `markdown: String`, `baseURL: URL?`, `annotations: [MarkdownProCore.Annotation]`, `onSelection: (ReviewSelection) -> Void`, `onAnnotationClicked: (Int64) -> Void`, `onAnchors: ([Int64: Bool]) -> Void`
  - `Store.reviewQueue: [Repository.ReviewQueueItem]` (`@Published private(set)`), `Store.toast: String?` (`@Published`)
  - `Store.annotations(documentId:) -> [MarkdownProCore.Annotation]`, `Store.addAnnotation(documentId:quote:prefix:suffix:comment:)`, `Store.deleteAnnotation(id:)`, `Store.applyVerdict(_:documentId:)`

- [ ] **Step 1: Create the bridge view**

Create `MarkdownPro/Reader/ReviewWebView.swift`:

```swift
import SwiftUI
import WebKit
import MarkdownProCore

/// A text selection captured in the rendered document, with W3C
/// TextQuoteSelector context so it can be re-anchored later.
struct ReviewSelection: Equatable {
    var quote: String
    var prefix: String
    var suffix: String
}

/// The Review Center's document pane: renderer.html plus the annotation
/// layer, bridged over the "review" script-message handler.
struct ReviewWebView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL?
    /// Current-round open annotations, painted as highlights.
    let annotations: [MarkdownProCore.Annotation]
    var onSelection: (ReviewSelection) -> Void
    var onAnnotationClicked: (Int64) -> Void
    var onAnchors: ([Int64: Bool]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "review")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        if let rendererURL = Bundle.main.url(forResource: "renderer", withExtension: "html") {
            webView.loadFileURL(rendererURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.push(markdown: markdown, baseURL: baseURL, annotations: annotations)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // The content controller retains the handler; break the cycle.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "review")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ReviewWebView
        weak var webView: WKWebView?
        private var pageLoaded = false
        private var lastRendered: String?
        private var lastAnnotationsJSON: String?

        init(_ parent: ReviewWebView) {
            self.parent = parent
        }

        func push(markdown: String, baseURL: URL?, annotations: [MarkdownProCore.Annotation]) {
            guard pageLoaded, let webView else { return }

            // Annotations first: renderMarkdown ends with __reviewRepaint().
            let list = annotations.map { a -> [String: Any] in
                ["id": a.id, "quote": a.quote, "prefix": a.prefix, "suffix": a.suffix]
            }
            if let data = try? JSONSerialization.data(withJSONObject: list) {
                let json = String(decoding: data, as: UTF8.self)
                if json != lastAnnotationsJSON {
                    lastAnnotationsJSON = json
                    webView.evaluateJavaScript("window.setReviewAnnotations(\(json))")
                }
            }

            let key = (baseURL?.path ?? "") + "|" + markdown
            if key != lastRendered {
                lastRendered = key
                if let payload = try? JSONSerialization.data(withJSONObject: [markdown, baseURL?.absoluteString ?? ""]) {
                    let json = String(decoding: payload, as: UTF8.self)
                    webView.evaluateJavaScript("window.renderMarkdown((\(json))[0], (\(json))[1])")
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            push(markdown: parent.markdown, baseURL: parent.baseURL, annotations: parent.annotations)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "selection":
                let selection = ReviewSelection(quote: body["quote"] as? String ?? "",
                                                prefix: body["prefix"] as? String ?? "",
                                                suffix: body["suffix"] as? String ?? "")
                guard !selection.quote.isEmpty else { return }
                parent.onSelection(selection)
            case "annotationClicked":
                if let id = body["id"] as? Int { parent.onAnnotationClicked(Int64(id)) }
            case "anchors":
                guard let map = body["anchored"] as? [String: Bool] else { return }
                var anchored: [Int64: Bool] = [:]
                for (key, value) in map {
                    if let id = Int64(key) { anchored[id] = value }
                }
                parent.onAnchors(anchored)
            default:
                break
            }
        }

        // Open clicked links in the default browser (same as MarkdownWebView).
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
```

- [ ] **Step 2: Extend the Store**

In `MarkdownPro/Store.swift`:

**2a.** Add published state below `pendingReaderURL`:

```swift
    @Published private(set) var reviewQueue: [Repository.ReviewQueueItem] = []
    /// One-shot in-app notification ("Proposal ready: …").
    @Published var toast: String?

    /// Review-doc ids seen by the last refresh; nil until the first load
    /// so launch never toasts.
    private var knownReviewDocIds: Set<Int64>?
```

**2b.** Replace `refresh()` with:

```swift
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
```

**2c.** Add a review section after `// MARK: - Subtasks / labels / notes / documents`:

```swift
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
```

- [ ] **Step 3: Build**

Run: `cd /Users/maximsargarovschi/Documents/Developer/markdown_pro && xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED` (new files auto-join the target via the synchronized folder).

- [ ] **Step 4: Commit**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro
git add MarkdownPro/Reader/ReviewWebView.swift MarkdownPro/Store.swift
git commit -m "feat(app): ReviewWebView JS bridge and Store review state"
```

---

### Task 7: Review Center view + sidebar + toast

**Files:**
- Create: `MarkdownPro/Views/ReviewCenterView.swift`
- Modify: `MarkdownPro/Views/ContentView.swift` (`SidebarItem.review`, sidebar row + badge, detail case, toast overlay)

**Interfaces:**
- Consumes: `ReviewWebView`, `Store` review API (Task 6), `Repository.ReviewQueueItem` (Task 3), existing `Date.timeAgo` helper (`MarkdownPro/Helpers.swift`).
- Produces: `struct ReviewCenterView: View` (no parameters; reads `Store` from the environment), `SidebarItem.review` case.

- [ ] **Step 1: Create the Review Center**

Create `MarkdownPro/Views/ReviewCenterView.swift`:

```swift
import SwiftUI
import MarkdownProCore

/// The review queue + annotation surface: pick a proposal on the left,
/// comment inline on the right, issue a verdict at the bottom.
struct ReviewCenterView: View {
    @EnvironmentObject private var store: Store
    @State private var selectedId: Int64?

    private var current: Repository.ReviewQueueItem? {
        store.reviewQueue.first { $0.id == selectedId } ?? store.reviewQueue.first
    }

    var body: some View {
        HSplitView {
            queue
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            if let item = current {
                ReviewDocumentView(item: item) {
                    // Verdict issued — auto-advance to the next proposal.
                    selectedId = store.reviewQueue.first { $0.id != item.id }?.id
                }
                .id(item.id) // reset per-document state when switching
            } else {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal",
                                       description: Text("Proposals Claude submits will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Review")
    }

    private var queue: some View {
        List(store.reviewQueue, selection: $selectedId) { item in
            VStack(alignment: .leading, spacing: 3) {
                Text(item.document.title)
                    .font(.callout)
                    .lineLimit(2)
                Text(item.taskTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.projectName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if item.document.round > 1 {
                        Text("round \(item.document.round)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    Spacer()
                    Text((item.document.updatedAt ?? item.document.createdAt).timeAgo)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
            .tag(item.id)
            .accessibilityIdentifier("reviewQueueRow-\(item.document.title)")
        }
        .listStyle(.inset)
    }
}
// Queue traversal: native List selection gives ↑/↓ arrow-key navigation,
// which covers the spec's "⌘↓/⌘↑ or click" intent with the platform-standard
// keys. Deliberate simplification — do not add custom ⌘-arrow handling.

/// One proposal: rendered document + comments panel + verdict bar.
private struct ReviewDocumentView: View {
    @EnvironmentObject private var store: Store
    let item: Repository.ReviewQueueItem
    let onVerdict: () -> Void

    @State private var markdown = ""
    @State private var annotations: [MarkdownProCore.Annotation] = []
    @State private var anchored: [Int64: Bool] = [:]
    @State private var pendingSelection: ReviewSelection?
    @State private var draftComment = ""
    @State private var scrollTarget: Int64?
    @State private var confirmReject = false
    @State private var confirmApproveWithComments = false

    private var currentRound: Int { item.document.round }
    /// Open comments made this round — painted in the doc, sent with the verdict.
    private var currentComments: [MarkdownProCore.Annotation] {
        annotations.filter { $0.round == currentRound && $0.state == .open }
    }
    /// Everything already handled: earlier rounds and addressed comments.
    private var pastComments: [MarkdownProCore.Annotation] {
        annotations.filter { $0.round < currentRound || $0.state == .addressed }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ReviewWebView(markdown: markdown,
                              baseURL: URL(fileURLWithPath: item.document.path).deletingLastPathComponent(),
                              annotations: currentComments,
                              onSelection: { pendingSelection = $0 },
                              onAnnotationClicked: { scrollTarget = $0 },
                              onAnchors: { anchored = $0 })
                Divider()
                verdictBar
            }
            Divider()
            commentsPanel
                .frame(width: 300)
        }
        .onAppear(perform: load)
        .confirmationDialog("Reject this proposal?", isPresented: $confirmReject) {
            Button("Reject — task returns to Todo", role: .destructive) { verdict(.reject) }
        } message: {
            Text("The proposal is marked rejected and its task drops back to Todo.")
        }
        .confirmationDialog("Approve with unsent comments?", isPresented: $confirmApproveWithComments) {
            Button("Approve — send \(currentComments.count) comments as FYI notes") { verdict(.approve) }
        } message: {
            Text("Claude sees them via get_review_feedback but no changes are requested.")
        }
    }

    private func load() {
        markdown = (try? String(contentsOfFile: item.document.path, encoding: .utf8))
            ?? "⚠️ Could not read `\(item.document.path)`"
        annotations = store.annotations(documentId: item.document.id)
    }

    private func reloadAnnotations() {
        annotations = store.annotations(documentId: item.document.id)
    }

    private func saveDraft() {
        guard let sel = pendingSelection else { return }
        let text = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addAnnotation(documentId: item.document.id, quote: sel.quote,
                            prefix: sel.prefix, suffix: sel.suffix, comment: text)
        pendingSelection = nil
        draftComment = ""
        reloadAnnotations()
    }

    private func verdict(_ v: Repository.ReviewVerdict) {
        store.applyVerdict(v, documentId: item.document.id)
        onVerdict()
    }

    private var verdictBar: some View {
        HStack(spacing: 10) {
            Text("\(currentComments.count) comment\(currentComments.count == 1 ? "" : "s") this round")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reject") { confirmReject = true }
                .accessibilityIdentifier("rejectButton")
            Button("Request Changes") { verdict(.requestChanges) }
                .disabled(currentComments.isEmpty)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("⌘⇧⏎ — needs at least one comment")
                .accessibilityIdentifier("requestChangesButton")
            Button("Approve") {
                if currentComments.isEmpty { verdict(.approve) } else { confirmApproveWithComments = true }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help("⌘⏎")
            .accessibilityIdentifier("approveButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var commentsPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    composer
                    if !currentComments.isEmpty {
                        panelSection("Round \(currentRound)") {
                            ForEach(currentComments) { a in
                                commentRow(a).id(a.id)
                            }
                        }
                    }
                    if !pastComments.isEmpty {
                        panelSection("Earlier") {
                            ForEach(pastComments) { a in resolvedRow(a) }
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: scrollTarget) { _, target in
                if let target {
                    withAnimation { proxy.scrollTo(target) }
                    scrollTarget = nil
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var composer: some View {
        if let sel = pendingSelection {
            VStack(alignment: .leading, spacing: 6) {
                Text("“\(sel.quote)”")
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                TextField("Comment…", text: $draftComment, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveDraft)
                    .accessibilityIdentifier("commentField")
                HStack {
                    Button("Cancel") { pendingSelection = nil; draftComment = "" }
                        .controlSize(.small)
                    Spacer()
                    Button("Save", action: saveDraft)
                        .controlSize(.small)
                        .disabled(draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        } else {
            Text("Select text in the document to comment")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func commentRow(_ a: MarkdownProCore.Annotation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("“\(a.quote)”")
                .font(.caption.italic())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(a.comment)
                .font(.callout)
            if anchored[a.id] == false {
                SwiftUI.Label("Unanchored — quoted text changed", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .contextMenu {
            Button("Delete comment", role: .destructive) {
                store.deleteAnnotation(id: a.id)
                reloadAnnotations()
            }
        }
    }

    private func resolvedRow(_ a: MarkdownProCore.Annotation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: a.state == .addressed ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(a.state == .addressed ? Color.green : Color.secondary)
                Text("Round \(a.round)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("“\(a.quote)”")
                .font(.caption.italic())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(a.comment)
                .font(.caption)
            if let reply = a.reply {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(reply)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
    }

    @ViewBuilder
    private func panelSection(_ title: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            body()
        }
    }
}
```

- [ ] **Step 2: Wire the sidebar, detail pane, and toast**

In `MarkdownPro/Views/ContentView.swift`:

**2a.** Add the case to `SidebarItem` (line 4):

```swift
enum SidebarItem: Hashable {
    case stats
    case review
    case document(String)   // a markdown file path, selected in the sidebar
    case project(Int64)
}
```

**2b.** In the `ContentView` detail `switch`, add before `case .document`:

```swift
            case .review:
                ReviewCenterView()
```

**2c.** In `SidebarView`'s `Section("Overview")`, add after the Progress row:

```swift
                SwiftUI.Label("Review", systemImage: "text.badge.checkmark")
                    .badge(store.reviewQueue.count)
                    .tag(SidebarItem.review)
                    .accessibilityIdentifier("reviewSidebarItem")
```

**2d.** Add the toast overlay to `ContentView`'s `NavigationSplitView` (chain after `.preferredColorScheme(...)`):

```swift
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThickMaterial))
                    .shadow(radius: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture {
                        selection = .review
                        store.toast = nil
                    }
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        store.toast = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.toast)
```

- [ ] **Step 3: Build and smoke-test the full annotation flow**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro
xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build 2>&1 | tail -3

# Seed a scratch DB with a pending review, then launch against it:
export MARKDOWNPRO_DB=/tmp/mdpro-ui-test.sqlite
rm -f /tmp/mdpro-ui-test.sqlite*
printf '# Test proposal\n\nSwitch the cache to an LRU eviction policy.\n\n```mermaid\ngraph TD; A-->B;\n```\n' > /tmp/mdpro-ui-proposal.md
cd mcp-server && printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_project","arguments":{"name":"UI QA"}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_task","arguments":{"project_id":1,"title":"Cache eviction"}}}' \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"submit_for_review","arguments":{"task_id":1,"path":"/tmp/mdpro-ui-proposal.md","title":"LRU proposal"}}}' \
 | ./.build/release/markdownpro-mcp 2>/dev/null
cd ..
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/MarkdownPro-*/Build/Products/Debug/MarkdownPro.app | head -1)
MARKDOWNPRO_DB=/tmp/mdpro-ui-test.sqlite "$APP/Contents/MacOS/MarkdownPro" &
```

Verify manually (screenshot with `screencapture -x /tmp/review-center.png` as needed):
1. Sidebar shows **Review** with badge `1`; clicking it shows the queue with "LRU proposal".
2. The document renders (mermaid diagram visible). Select "LRU eviction policy" → "Comment (c)" button appears → click → composer shows the quote → type a comment → Save → highlight is painted, comment listed under "Round 1".
3. "Request Changes" becomes enabled; click it → queue empties, and the board card for "Cache eviction" is the next task's concern (chip lands in Task 8).
4. While the app is running, resubmit via MCP (repeat the id 3 call) → within ~1.5 s the badge returns and the toast "Proposal ready: LRU proposal" appears; clicking the toast opens Review; the earlier comment shows under "Earlier" once addressed... (resolution itself is Claude's job — just confirm the round-2 grouping).

Kill the app when done.

- [ ] **Step 4: Commit**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro
git add MarkdownPro/Views/ReviewCenterView.swift MarkdownPro/Views/ContentView.swift
git commit -m "feat(app): Review Center — queue, inline comments, verdicts, toast"
```

---

### Task 8: Attention chips on board and task detail

**Files:**
- Modify: `MarkdownPro/Helpers.swift` (colors/icons for `TaskAttention` + `DocumentState`)
- Modify: `MarkdownPro/Views/ProjectView.swift` (chip on `TaskCardView`, `ProjectView.swift:185-245`)
- Modify: `MarkdownPro/Views/TaskDetailView.swift` (attention chip in the header row; review state on linked documents)

**Interfaces:**
- Consumes: `TaskItem.attention`, `LinkedDocument.state` (Task 2).
- Produces: `TaskAttention.iconName/color`, `DocumentState.color` extensions used only app-side.

- [ ] **Step 1: Add display helpers**

Append to `MarkdownPro/Helpers.swift`:

```swift
extension TaskAttention {
    var iconName: String {
        switch self {
        case .needsReview: return "eye"
        case .changesRequested: return "arrow.uturn.left"
        case .readyToExecute: return "play.circle"
        case .executing: return "gearshape.2"
        }
    }

    var color: Color {
        switch self {
        case .needsReview: return .orange
        case .changesRequested: return .yellow
        case .readyToExecute: return .green
        case .executing: return .blue
        }
    }
}

extension DocumentState {
    var color: Color {
        switch self {
        case .needsReview: return .orange
        case .changesRequested: return .yellow
        case .approved: return .green
        case .rejected: return .red
        case .superseded: return .gray
        }
    }
}

/// Small colored capsule used for attention / review-state chips.
struct AttentionChip: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        SwiftUI.Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}
```

- [ ] **Step 2: Chip on the board card**

In `TaskCardView` (`MarkdownPro/Views/ProjectView.swift`), insert between the title `HStack` and the labels block (after line 199):

```swift
            if let attention = task.attention {
                AttentionChip(text: attention.displayName,
                              icon: attention.iconName,
                              color: attention.color)
            }
```

- [ ] **Step 3: Chips in the task detail sheet**

In `MarkdownPro/Views/TaskDetailView.swift`:

After the `dueDateControl(detail)` call inside the status/priority row (line 81), add:

```swift
                        if let attention = detail.task.attention {
                            AttentionChip(text: attention.displayName,
                                          icon: attention.iconName,
                                          color: attention.color)
                        }
```

In the linked-documents row, after the `VStack(alignment: .leading, spacing: 1)` closing brace (line 173), add:

```swift
                                    if let state = doc.state {
                                        AttentionChip(text: state.displayName,
                                                      icon: "doc.badge.ellipsis",
                                                      color: state.color)
                                    }
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/maximsargarovschi/Documents/Developer/markdown_pro && xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`.

Relaunch against the Task 7 scratch DB (`MARKDOWNPRO_DB=/tmp/mdpro-ui-test.sqlite`): the "Cache eviction" card on the board shows the 🟡 "Changes requested" chip (from Task 7's verdict); open the task detail — chip in the header, "Changes requested" state on the linked proposal row.

- [ ] **Step 5: Commit**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro
git add MarkdownPro/Helpers.swift MarkdownPro/Views/ProjectView.swift MarkdownPro/Views/TaskDetailView.swift
git commit -m "feat(app): attention chips on board cards and task detail"
```

---

### Task 9: QA checklist + full end-to-end verification

**Files:**
- Modify: `docs/QA_CHECKLIST.md` (append review section)

**Interfaces:** none produced; this task closes the loop.

- [ ] **Step 1: Append the QA section**

Append to `docs/QA_CHECKLIST.md`:

```markdown
## §8 Review Center

Setup: scratch DB (`MARKDOWNPRO_DB=/tmp/qa.sqlite`), one project + task, a
proposal `.md` submitted via `submit_for_review` (see mcp-server README or
Task 4 of the review-center plan for the JSON-RPC lines).

- [ ] Sidebar shows **Review** with a badge equal to the number of
      `needs_review` proposals; badge hides at zero.
- [ ] Submitting a proposal while the app runs shows the toast within ~2 s;
      clicking the toast opens Review.
- [ ] Queue rows show title, task, project, round chip (round ≥ 2 only),
      and age; selection follows clicks and stays valid after refresh.
- [ ] Document renders with mermaid + syntax highlighting intact.
- [ ] Selecting text shows "Comment (c)"; both the button and the `c` key
      open the composer with the quote; Save paints a highlight.
- [ ] Selection across a code block and across two paragraphs both anchor.
- [ ] Clicking a highlight scrolls the panel to its comment.
- [ ] Comment context menu → Delete removes comment and highlight.
- [ ] Request Changes is disabled with zero comments; with comments it
      moves doc → changes_requested, task chip → 🟡, queue advances.
- [ ] Approve with unsent comments warns ("FYI notes"); approving moves
      task chip → 🟢 ready to execute.
- [ ] Reject asks for confirmation; task returns to Todo, chip clears.
- [ ] After Claude resubmits (round 2): prior comments listed under
      "Earlier" with green check + reply once resolved; only current-round
      comments paint highlights.
- [ ] Editing the file so a quote disappears flags that comment
      "Unanchored" instead of highlighting the wrong text.
- [ ] Activity log on the task shows review entries with correct actors
      (user verdicts, claude submissions/resolutions).
- [ ] Plain reader (Documents section) still renders and never shows the
      comment button.
```

- [ ] **Step 2: Run everything**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro/Core && swift test
cd ../mcp-server && swift build -c release
cd .. && xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build 2>&1 | tail -3
```

Expected: all tests pass, both builds succeed.

- [ ] **Step 3: Walk §8 of the QA checklist manually**

Follow the section end-to-end against a scratch DB, including one full two-round loop: submit → comment → request changes → `get_review_feedback` → `resolve_annotation` → resubmit → verify "Earlier" grouping + replies → approve → confirm 🟢 chip and `list_tasks(attention=ready_to_execute)` returns the task. Fix anything that fails before committing.

- [ ] **Step 4: Commit**

```bash
cd /Users/maximsargarovschi/Documents/Developer/markdown_pro
git add docs/QA_CHECKLIST.md
git commit -m "docs: QA checklist section for the Review Center"
```

---

## Post-plan notes

- **Out of scope (spec):** dispatch-from-app, navigation reorg, rendered diffs, comment threading, macOS system notifications, local-LLM executor. Do not add them opportunistically.
- **Forward hooks that must survive review:** `list_tasks(attention:)` filter and `set_attention` are the executor-agnostic dispatch points for future automation.
- **Known acceptable degradations:** without CSS Custom Highlight API support highlights don't paint (comments still work from the panel); unanchored quotes surface as flagged panel entries, never as wrong highlights.
