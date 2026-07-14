import XCTest
@testable import MarkdownProCore

final class RepositoryImportTests: XCTestCase {

    private func sampleProject(name: String = "Imported") -> ExportedProject {
        ExportedProject(
            name: name,
            color: "#FF0000",
            archived: false,
            createdAt: "2026-06-01T09:00:00.000Z",
            updatedAt: "2026-06-02T09:00:00.000Z",
            documents: [],
            tasks: [
                ExportedTask(
                    title: "Restored task",
                    details: "body",
                    status: "in_progress",
                    priority: "high",
                    dueDate: "2026-07-20",
                    sortOrder: 7,
                    createdAt: "2026-06-03T10:00:00.000Z",
                    updatedAt: "2026-06-04T10:00:00.000Z",
                    labels: [ExportedLabel(name: "feature", color: "#111111")],
                    subtasks: [ExportedSubtask(title: "step one", done: true, sortOrder: 2)],
                    activity: [
                        ExportedActivity(actor: "claude", kind: "created",
                                         message: "created this task",
                                         createdAt: "2026-06-03T10:00:00.000Z"),
                        ExportedActivity(actor: "user", kind: "status",
                                         message: "moved from Todo to In Progress",
                                         createdAt: "2026-06-04T10:00:00.000Z")
                    ],
                    documents: []
                )
            ]
        )
    }

    func testInsertPreservesFieldsTimestampsAndHistory() throws {
        let test = try TestDatabase()
        let projectId = try test.repo.insertImportedProject(sampleProject(), name: "Imported") { _ in nil }

        let tasks = try test.repo.listTasks(projectId: projectId)
        XCTAssertEqual(tasks.count, 1)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.title, "Restored task")
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.sortOrder, 7)
        XCTAssertEqual(DateCoding.encode(task.createdAt), "2026-06-03T10:00:00.000Z")
        XCTAssertEqual(task.labels.map(\.name), ["feature"])

        let detail = try XCTUnwrap(test.repo.getTask(id: task.id))
        XCTAssertEqual(detail.subtasks.map(\.title), ["step one"])
        XCTAssertEqual(detail.subtasks.first?.done, true)

        // Exactly the two exported entries — no fabricated "created" entry on top.
        XCTAssertEqual(detail.activity.count, 2)
        XCTAssertEqual(Set(detail.activity.map(\.actor)), ["claude", "user"])
        let statusEntry = try XCTUnwrap(detail.activity.first { $0.kind == "status" })
        XCTAssertEqual(statusEntry.message, "moved from Todo to In Progress")
        XCTAssertEqual(DateCoding.encode(statusEntry.createdAt), "2026-06-04T10:00:00.000Z")
    }

    func testAvailableProjectNameUniquifiesOnCollision() throws {
        let test = try TestDatabase()
        XCTAssertEqual(try test.repo.availableProjectName("Fresh"), "Fresh")

        try test.repo.createProject(name: "Taken")
        XCTAssertEqual(try test.repo.availableProjectName("Taken"), "Taken (imported)")

        try test.repo.createProject(name: "Taken (imported)")
        XCTAssertEqual(try test.repo.availableProjectName("Taken"), "Taken (imported 2)")
    }

    func testExistingLabelIsReusedAndKeepsItsColor() throws {
        let test = try TestDatabase()
        let existingProject = try test.repo.createProject(name: "Existing")
        let existingTask = try test.repo.createTask(projectId: existingProject, title: "T")
        try test.repo.addLabel(taskId: existingTask, name: "feature", color: "#ABCDEF")

        // The bundle carries "feature" with a different colour.
        try test.repo.insertImportedProject(sampleProject(), name: "Imported") { _ in nil }

        let labels = try test.repo.listLabels().filter { $0.name == "feature" }
        XCTAssertEqual(labels.count, 1, "the label must be merged, not duplicated")
        XCTAssertEqual(labels.first?.color, "#ABCDEF", "the existing colour wins")
    }

    func testDocumentsAreLinkedAtTheResolvedPath() throws {
        let test = try TestDatabase()
        var project = sampleProject()
        project.documents = [ExportedDocument(title: "Roadmap", originalPath: "/nope/roadmap.md", file: "documents/0001-roadmap.md")]
        project.tasks[0].documents = [ExportedDocument(title: "Spec", originalPath: "/nope/spec.md", file: "documents/0002-spec.md")]

        let projectId = try test.repo.insertImportedProject(project, name: "Imported") { doc in
            "/resolved/\(doc.title).md"
        }

        let docs = try test.repo.documents(projectId: projectId)
        XCTAssertEqual(Set(docs.map(\.path)), ["/resolved/Roadmap.md", "/resolved/Spec.md"])

        let projectLevel = docs.filter { $0.taskId == nil }
        XCTAssertEqual(projectLevel.map(\.title), ["Roadmap"])
    }

    func testSkippedDocumentIsNotInserted() throws {
        let test = try TestDatabase()
        var project = sampleProject()
        project.documents = [ExportedDocument(title: "Gone", originalPath: "/nope/gone.md", file: nil)]

        let projectId = try test.repo.insertImportedProject(project, name: "Imported") { _ in nil }
        XCTAssertTrue(try test.repo.documents(projectId: projectId).isEmpty)
    }
}
