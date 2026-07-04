import XCTest
@testable import MarkdownProCore

/// Exercises the shared data layer against every data-backed expectation
/// in docs/QA_CHECKLIST.md. Each test runs on its own throwaway SQLite file.
final class RepositoryTests: XCTestCase {
    private var tempPath: String = ""
    private var repo: Repository!

    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory()
        tempPath = (dir as NSString).appendingPathComponent("mdpro-test-\(UUID().uuidString).sqlite")
        repo = Repository(db: try Database.open(path: tempPath))
    }

    override func tearDownWithError() throws {
        repo = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: tempPath + suffix)
        }
    }

    private func messages(_ taskId: Int64) throws -> [String] {
        try repo.getTask(id: taskId)!.activity.map(\.message)
    }

    // §1 / §5 — progress is done / (tasks excluding canceled)
    func testProjectProgressExcludesCanceled() throws {
        let p = try repo.createProject(name: "P")
        try repo.createTask(projectId: p, title: "a", status: .done)
        try repo.createTask(projectId: p, title: "b", status: .todo)
        try repo.createTask(projectId: p, title: "c", status: .canceled)
        let project = try repo.listProjects().first { $0.id == p }!
        XCTAssertEqual(project.taskCount, 2, "canceled tasks must not count toward the denominator")
        XCTAssertEqual(project.doneCount, 1)
        XCTAssertEqual(project.progress, 0.5, accuracy: 0.0001)
    }

    // §2 — projects sorted by name, case-insensitively
    func testProjectsSortedByNameCaseInsensitive() throws {
        _ = try repo.createProject(name: "banana")
        _ = try repo.createProject(name: "Apple")
        _ = try repo.createProject(name: "cherry")
        XCTAssertEqual(try repo.listProjects().map(\.name), ["Apple", "banana", "cherry"])
    }

    // §2 — deleting a project cascades to its tasks
    func testDeleteProjectCascadesTasks() throws {
        let p = try repo.createProject(name: "P")
        try repo.createTask(projectId: p, title: "a")
        try repo.deleteProject(id: p)
        XCTAssertEqual(try repo.listTasks(projectId: p).count, 0)
    }

    // §3 / §4 — creating a task logs a "created" entry
    func testCreateTaskLogsCreation() throws {
        let p = try repo.createProject(name: "P")
        let t = try repo.createTask(projectId: p, title: "Task", actor: "user")
        XCTAssertTrue(try messages(t).contains { $0.contains("created this task") })
    }

    // §4 — rename logs "renamed to …"
    func testRenameLogsActivity() throws {
        let p = try repo.createProject(name: "P")
        let t = try repo.createTask(projectId: p, title: "Old")
        try repo.updateTask(id: t, changes: .init(title: "New"))
        XCTAssertTrue(try messages(t).contains { $0.contains("renamed to") && $0.contains("New") })
    }

    // §4 — status change logs "moved from X to Y"
    func testStatusChangeLogsMovedFromTo() throws {
        let p = try repo.createProject(name: "P")
        let t = try repo.createTask(projectId: p, title: "T", status: .todo)
        try repo.updateTask(id: t, changes: .init(status: .inProgress))
        XCTAssertTrue(try messages(t).contains("moved from Todo to In Progress"))
    }

    // §4 — priority change logs
    func testPriorityChangeLogged() throws {
        let p = try repo.createProject(name: "P")
        let t = try repo.createTask(projectId: p, title: "T", priority: .none)
        try repo.updateTask(id: t, changes: .init(priority: .high))
        XCTAssertTrue(try messages(t).contains("set priority to High"))
    }

    // §4 — due date set then cleared: both logged
    func testDueDateSetAndClearLogged() throws {
        let p = try repo.createProject(name: "P")
        let t = try repo.createTask(projectId: p, title: "T")
        try repo.updateTask(id: t, changes: .init(dueDate: .some("2026-08-01")))
        try repo.updateTask(id: t, changes: .init(dueDate: .some(nil)))
        let msgs = try messages(t)
        XCTAssertTrue(msgs.contains("set due date to 2026-08-01"))
        XCTAssertTrue(msgs.contains("cleared the due date"))
        XCTAssertNil(try repo.getTask(id: t)!.task.dueDate, "due date should be cleared")
    }

    // §3 / §4 — subtask counters
    func testSubtaskCounts() throws {
        let p = try repo.createProject(name: "P")
        let t = try repo.createTask(projectId: p, title: "T", subtasks: ["one", "two"])
        var detail = try repo.getTask(id: t)!
        XCTAssertEqual(detail.task.subtaskCount, 2)
        XCTAssertEqual(detail.task.subtaskDoneCount, 0)
        try repo.setSubtaskDone(id: detail.subtasks[0].id, done: true)
        detail = try repo.getTask(id: t)!
        XCTAssertEqual(detail.task.subtaskDoneCount, 1)
    }

    // §4 / §7 — labels are created once and matched case-insensitively; filtering works
    func testLabelCreateDedupAndFilter() throws {
        let p = try repo.createProject(name: "P")
        let t1 = try repo.createTask(projectId: p, title: "T1", labels: ["Bug"])
        let t2 = try repo.createTask(projectId: p, title: "T2")
        try repo.addLabel(taskId: t2, name: "bug")           // same label, different case
        XCTAssertEqual(try repo.listLabels().count, 1, "label must be reused, not duplicated")
        let filtered = try repo.listTasks(projectId: p, labelName: "BUG").map(\.id)
        XCTAssertEqual(Set(filtered), Set([t1, t2]))
    }

    // §5 — completions-by-day includes today's Done move, excludes an old one
    func testCompletionsByDayWindow() throws {
        let p = try repo.createProject(name: "P")
        let t = try repo.createTask(projectId: p, title: "T", status: .todo)
        try repo.moveTask(id: t, to: .done)                  // logs a status→Done today
        // Inject an old completion 20 days ago in the stored ISO-8601 format.
        let old = DateCoding.encode(Date(timeIntervalSinceNow: -20 * 86_400))
        try repo.db.execute(
            "INSERT INTO activity (task_id, actor, kind, message, created_at) VALUES (?,?,?,?,?)",
            [.integer(t), .text("user"), .text("status"), .text("moved from Todo to Done"), .text(old)])
        let days = try repo.completionsByDay(days: 14)
        let today = String(DateCoding.encode(Date()).prefix(10))
        XCTAssertTrue(days.contains { $0.day == today && $0.count >= 1 }, "today's completion should appear")
        XCTAssertFalse(days.contains { $0.day == String(old.prefix(10)) }, "a 20-day-old completion is outside the 14-day window")
    }

    // §7 — attaching a document links it and logs an activity note
    func testAttachDocumentLinksAndLogs() throws {
        let p = try repo.createProject(name: "P")
        let t = try repo.createTask(projectId: p, title: "T")
        _ = try repo.attachDocument(taskId: t, projectId: nil, path: "/tmp/report.md", title: "Report")
        let detail = try repo.getTask(id: t)!
        XCTAssertEqual(detail.documents.map(\.title), ["Report"])
        XCTAssertEqual(detail.task.documentCount, 1)
        XCTAssertTrue(detail.activity.contains { $0.message.contains("attached document") })
    }

    // §7 — MCP writes are attributed to claude, app writes to user
    func testActorAttribution() throws {
        let p = try repo.createProject(name: "P")
        let t = try repo.createTask(projectId: p, title: "T", actor: "claude")
        try repo.updateTask(id: t, changes: .init(status: .done), actor: "user")
        let acts = try repo.getTask(id: t)!.activity
        XCTAssertEqual(acts.first { $0.kind == "created" }?.actor, "claude")
        XCTAssertEqual(acts.first { $0.kind == "status" }?.actor, "user")
    }

    // Board is stable: no-op updates don't spam the activity log
    func testNoOpUpdateDoesNotLog() throws {
        let p = try repo.createProject(name: "P")
        let t = try repo.createTask(projectId: p, title: "T", status: .todo)
        let before = try messages(t).count
        try repo.updateTask(id: t, changes: .init(status: .todo))  // same status
        XCTAssertEqual(try messages(t).count, before, "changing a field to its current value should log nothing")
    }
}
