import XCTest
@testable import MarkdownProCore

final class ProjectExporterTests: XCTestCase {

    func testExportProducesManifestWithTasksLabelsSubtasksAndHistory() throws {
        let test = try TestDatabase()
        let projectId = try test.repo.createProject(name: "Alpha", color: "#123456")
        let taskId = try test.repo.createTask(projectId: projectId, title: "Ship it", details: "body",
                                              status: .todo, priority: .high, dueDate: "2026-08-01",
                                              labels: ["feature"], subtasks: ["one", "two"])
        try test.repo.moveTask(id: taskId, to: .done, actor: "claude")

        let data = try ProjectExporter.export(projectIds: [projectId], repo: test.repo)
        let bundle = try decodeManifest(from: data)

        XCTAssertEqual(bundle.formatVersion, ExportBundle.currentFormatVersion)
        XCTAssertEqual(bundle.projects.count, 1)
        let project = try XCTUnwrap(bundle.projects.first)
        XCTAssertEqual(project.name, "Alpha")
        XCTAssertEqual(project.color, "#123456")

        let task = try XCTUnwrap(project.tasks.first)
        XCTAssertEqual(task.title, "Ship it")
        XCTAssertEqual(task.status, "done")
        XCTAssertEqual(task.priority, "high")
        XCTAssertEqual(task.dueDate, "2026-08-01")
        XCTAssertEqual(task.labels.map(\.name), ["feature"])
        XCTAssertEqual(task.subtasks.map(\.title), ["one", "two"])

        // "created" from createTask plus "status" from moveTask, oldest first.
        XCTAssertEqual(task.activity.map(\.kind), ["created", "status"])
        XCTAssertEqual(task.activity.last?.actor, "claude")
    }

    func testDocumentContentsAreEmbeddedAndProjectDocumentsStayProjectLevel() throws {
        let test = try TestDatabase()
        let projectId = try test.repo.createProject(name: "Alpha")
        let taskId = try test.repo.createTask(projectId: projectId, title: "T")

        let roadmap = try test.writeFile(named: "roadmap.md", contents: "# Roadmap\n")
        let spec = try test.writeFile(named: "spec.md", contents: "# Spec\n")
        try test.repo.attachDocument(taskId: nil, projectId: projectId, path: roadmap, title: "Roadmap")
        try test.repo.attachDocument(taskId: taskId, projectId: nil, path: spec, title: "Spec")

        let data = try ProjectExporter.export(projectIds: [projectId], repo: test.repo)
        let entries = try Zip.read(data)
        let bundle = try decodeManifest(from: data)
        let project = try XCTUnwrap(bundle.projects.first)

        let projectDoc = try XCTUnwrap(project.documents.first)
        XCTAssertEqual(project.documents.count, 1, "the task's document must not also appear at project level")
        XCTAssertEqual(projectDoc.title, "Roadmap")
        XCTAssertEqual(projectDoc.originalPath, roadmap)

        let taskDoc = try XCTUnwrap(project.tasks.first?.documents.first)
        XCTAssertEqual(taskDoc.title, "Spec")

        let roadmapEntry = try XCTUnwrap(entries.first { $0.name == projectDoc.file })
        XCTAssertEqual(String(data: roadmapEntry.data, encoding: .utf8), "# Roadmap\n")
        let specEntry = try XCTUnwrap(entries.first { $0.name == taskDoc.file })
        XCTAssertEqual(String(data: specEntry.data, encoding: .utf8), "# Spec\n")
    }

    func testMissingDocumentFileExportsWithNullFile() throws {
        let test = try TestDatabase()
        let projectId = try test.repo.createProject(name: "Alpha")
        try test.repo.attachDocument(taskId: nil, projectId: projectId,
                                     path: "/definitely/not/here.md", title: "Ghost")

        let data = try ProjectExporter.export(projectIds: [projectId], repo: test.repo)
        let bundle = try decodeManifest(from: data)
        let doc = try XCTUnwrap(bundle.projects.first?.documents.first)

        XCTAssertEqual(doc.originalPath, "/definitely/not/here.md")
        XCTAssertNil(doc.file, "an unreadable file must not fail the export")
    }

    func testUnknownProjectIdThrows() throws {
        let test = try TestDatabase()
        XCTAssertThrowsError(try ProjectExporter.export(projectIds: [9999], repo: test.repo))
    }

    private func decodeManifest(from bundle: Data) throws -> ExportBundle {
        let entries = try Zip.read(bundle)
        let manifest = try XCTUnwrap(entries.first { $0.name == ExportBundle.manifestEntryName })
        return try JSONDecoder().decode(ExportBundle.self, from: manifest.data)
    }
}
