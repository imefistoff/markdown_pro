import XCTest
@testable import MarkdownProCore

final class ProjectImporterTests: XCTestCase {

    func testPreviewReportsProjectsWithoutWriting() throws {
        let source = try TestDatabase()
        let projectId = try source.repo.createProject(name: "Alpha")
        try source.repo.createTask(projectId: projectId, title: "One")
        try source.repo.createTask(projectId: projectId, title: "Two")
        let live = try source.writeFile(named: "live.md", contents: "# Live\n")
        try source.repo.attachDocument(taskId: nil, projectId: projectId, path: live, title: "Live")
        let bundle = try ProjectExporter.export(projectIds: [projectId], repo: source.repo)

        let target = try TestDatabase()
        let preview = try ProjectImporter.preview(bundle)

        XCTAssertEqual(preview.projects.count, 1)
        let project = try XCTUnwrap(preview.projects.first)
        XCTAssertEqual(project.name, "Alpha")
        XCTAssertEqual(project.taskCount, 2)
        XCTAssertEqual(project.documentCount, 1)
        XCTAssertEqual(project.relinkCount, 1, "the original file still exists, so it relinks")
        XCTAssertEqual(project.restoreCount, 0)

        XCTAssertTrue(try target.repo.listProjects().isEmpty, "preview must write nothing")
    }

    func testImportRoundTripsTasksSubtasksLabelsAndActivity() throws {
        let source = try TestDatabase()
        let projectId = try source.repo.createProject(name: "Alpha", color: "#123456")
        let taskId = try source.repo.createTask(projectId: projectId, title: "Ship it", details: "body",
                                                status: .todo, priority: .high, dueDate: "2026-08-01",
                                                labels: ["feature"], subtasks: ["one", "two"])
        try source.repo.moveTask(id: taskId, to: .done, actor: "claude")
        let original = try XCTUnwrap(source.repo.getTask(id: taskId))
        let bundle = try ProjectExporter.export(projectIds: [projectId], repo: source.repo)

        let target = try TestDatabase()
        let ids = try ProjectImporter.import(bundle, selecting: [0], repo: target.repo,
                                             documentsDirectory: target.directory.appendingPathComponent("Imported"))

        XCTAssertEqual(ids.count, 1)
        let imported = try XCTUnwrap(target.repo.listProjects().first)
        XCTAssertEqual(imported.name, "Alpha")
        XCTAssertEqual(imported.color, "#123456")

        let task = try XCTUnwrap(target.repo.listTasks(projectId: imported.id).first)
        XCTAssertEqual(task.title, "Ship it")
        XCTAssertEqual(task.status, .done)
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.labels.map(\.name), ["feature"])
        XCTAssertEqual(DateCoding.encode(task.createdAt), DateCoding.encode(original.task.createdAt),
                       "timestamps must survive the round trip")

        let detail = try XCTUnwrap(target.repo.getTask(id: task.id))
        XCTAssertEqual(detail.subtasks.map(\.title), ["one", "two"])
        XCTAssertEqual(detail.activity.count, original.activity.count)
        XCTAssertEqual(Set(detail.activity.map(\.actor)), Set(original.activity.map(\.actor)))
    }

    func testDocumentRelinksWhenOriginalPathStillExists() throws {
        let source = try TestDatabase()
        let projectId = try source.repo.createProject(name: "Alpha")
        let live = try source.writeFile(named: "live.md", contents: "# Live\n")
        try source.repo.attachDocument(taskId: nil, projectId: projectId, path: live, title: "Live")
        let bundle = try ProjectExporter.export(projectIds: [projectId], repo: source.repo)

        let target = try TestDatabase()
        let ids = try ProjectImporter.import(bundle, selecting: [0], repo: target.repo,
                                             documentsDirectory: target.directory.appendingPathComponent("Imported"))

        let doc = try XCTUnwrap(target.repo.documents(projectId: ids[0]).first)
        XCTAssertEqual(doc.path, live, "the live file still exists, so we link straight to it")
    }

    func testDocumentIsRestoredFromEmbeddedCopyWhenOriginalIsGone() throws {
        let source = try TestDatabase()
        let projectId = try source.repo.createProject(name: "Alpha")
        let doomed = try source.writeFile(named: "doomed.md", contents: "# Doomed\n")
        try source.repo.attachDocument(taskId: nil, projectId: projectId, path: doomed, title: "Doomed")
        let bundle = try ProjectExporter.export(projectIds: [projectId], repo: source.repo)

        // The original file disappears after the export.
        try FileManager.default.removeItem(atPath: doomed)

        let target = try TestDatabase()
        let importedDir = target.directory.appendingPathComponent("Imported")
        let ids = try ProjectImporter.import(bundle, selecting: [0], repo: target.repo,
                                             documentsDirectory: importedDir)

        let doc = try XCTUnwrap(target.repo.documents(projectId: ids[0]).first)
        XCTAssertNotEqual(doc.path, doomed)
        XCTAssertTrue(doc.path.hasPrefix(importedDir.path), "restored copies live under the imported directory")
        XCTAssertEqual(try String(contentsOfFile: doc.path, encoding: .utf8), "# Doomed\n")
    }

    func testImportingIntoABoardThatAlreadyHasTheNameCreatesANewProject() throws {
        let source = try TestDatabase()
        let projectId = try source.repo.createProject(name: "Alpha")
        try source.repo.createTask(projectId: projectId, title: "One")
        let bundle = try ProjectExporter.export(projectIds: [projectId], repo: source.repo)

        let target = try TestDatabase()
        let existing = try target.repo.createProject(name: "Alpha")
        try target.repo.createTask(projectId: existing, title: "Existing")

        try ProjectImporter.import(bundle, selecting: [0], repo: target.repo,
                                   documentsDirectory: target.directory.appendingPathComponent("Imported"))

        let names = try target.repo.listProjects().map(\.name).sorted()
        XCTAssertEqual(names, ["Alpha", "Alpha (imported)"])

        XCTAssertEqual(try target.repo.listTasks(projectId: existing).map(\.title), ["Existing"],
                       "the existing project must be untouched")
    }

    func testUnselectedProjectsAreNotImported() throws {
        let source = try TestDatabase()
        let a = try source.repo.createProject(name: "Alpha")
        let b = try source.repo.createProject(name: "Beta")
        let bundle = try ProjectExporter.export(projectIds: [a, b], repo: source.repo)

        let target = try TestDatabase()
        try ProjectImporter.import(bundle, selecting: [1], repo: target.repo,
                                   documentsDirectory: target.directory.appendingPathComponent("Imported"))

        XCTAssertEqual(try target.repo.listProjects().map(\.name), ["Beta"])
    }

    func testUnknownFormatVersionIsRejected() throws {
        let manifest = Data(#"{"formatVersion":99,"exportedAt":"2026-07-14T10:00:00.000Z","projects":[]}"#.utf8)
        let bundle = Zip.archive([ZipEntry(name: ExportBundle.manifestEntryName, data: manifest)])

        XCTAssertThrowsError(try ProjectImporter.preview(bundle)) { error in
            guard case ImportError.unsupportedFormatVersion(99) = error else {
                return XCTFail("expected unsupportedFormatVersion, got \(error)")
            }
        }
    }

    func testBundleWithoutManifestIsRejected() throws {
        let bundle = Zip.archive([ZipEntry(name: "documents/0001-spec.md", data: Data("# Spec\n".utf8))])
        XCTAssertThrowsError(try ProjectImporter.preview(bundle)) { error in
            guard case ImportError.missingManifest = error else {
                return XCTFail("expected missingManifest, got \(error)")
            }
        }
    }

    func testNonZipFileIsRejectedAndWritesNothing() throws {
        let target = try TestDatabase()
        XCTAssertThrowsError(try ProjectImporter.preview(Data("just some text".utf8)))
        XCTAssertTrue(try target.repo.listProjects().isEmpty)
    }
}
