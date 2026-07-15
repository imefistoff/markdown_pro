import XCTest
@testable import MarkdownProCore

final class SyncDocumentTests: XCTestCase {

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-managed-\(UUID().uuidString)")
        setenv("MARKDOWNPRO_SYNC_ROOT", dir.path, 1)
    }
    override func tearDown() {
        if let root = ProcessInfo.processInfo.environment["MARKDOWNPRO_SYNC_ROOT"] {
            try? FileManager.default.removeItem(atPath: root)
        }
        unsetenv("MARKDOWNPRO_SYNC_ROOT")
        super.tearDown()
    }

    private func makePair() throws -> (a: TestDatabase, b: TestDatabase, ea: SyncEngine, eb: SyncEngine, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("docsync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = try TestDatabase(), b = try TestDatabase()
        return (a, b,
                SyncEngine(repo: a.repo, transport: FolderTransport(root: folder, deviceId: try a.repo.syncState().deviceId)),
                SyncEngine(repo: b.repo, transport: FolderTransport(root: folder, deviceId: try b.repo.syncState().deviceId)),
                folder)
    }

    func testDocumentContentTravelsAsBlobAndRestoresManagedCopy() throws {
        let p = try makePair()
        let projectId = try p.a.repo.createProject(name: "Shared")
        try p.a.repo.setProjectSynced(id: projectId, synced: true)
        let projectUUID = try p.a.repo.entityUUID(.project, id: projectId)!
        let taskId = try p.a.repo.createTask(projectId: projectId, title: "with doc")
        let path = try p.a.writeFile(named: "spec.md", contents: "# Real spec\n")
        try p.a.repo.attachDocument(taskId: taskId, projectId: nil, path: path, title: "Spec")

        try p.ea.sync() // hashes + uploads blob + content_hash op
        try p.b.repo.adoptProject(remoteUUID: projectUUID, name: "Shared")
        try p.eb.sync()

        let docs = try p.b.repo.documents(projectId: try p.b.repo.db.query(
            "SELECT id FROM projects WHERE uuid = ?", [.text(projectUUID)]).first!.int("id"))
        let doc = docs.first { $0.title == "Spec" }
        XCTAssertNotNil(doc)
        // B has no original at that path, so it restored a managed copy that exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: doc!.path))
        XCTAssertEqual(try String(contentsOfFile: doc!.path, encoding: .utf8), "# Real spec\n")
    }

    func testLocalEditRehashesAndPropagates() throws {
        let p = try makePair()
        let projectId = try p.a.repo.createProject(name: "Shared")
        try p.a.repo.setProjectSynced(id: projectId, synced: true)
        let projectUUID = try p.a.repo.entityUUID(.project, id: projectId)!
        let taskId = try p.a.repo.createTask(projectId: projectId, title: "with doc")
        let docUUID: String
        do {
            let path = try p.a.writeFile(named: "spec.md", contents: "v1\n")
            let docId = try p.a.repo.attachDocument(taskId: taskId, projectId: nil, path: path, title: "Spec")
            docUUID = try p.a.repo.entityUUID(.document, id: docId)!
        }
        try p.ea.sync()
        try p.b.repo.adoptProject(remoteUUID: projectUUID, name: "Shared")
        try p.eb.sync()

        // Edit the original on A, then sync twice.
        _ = try p.a.writeFile(named: "spec.md", contents: "v2 edited\n")
        try p.ea.sync(); try p.eb.sync()

        let bPath = try p.b.repo.documentLocalPath(uuid: docUUID)!
        XCTAssertEqual(try String(contentsOfFile: bPath, encoding: .utf8), "v2 edited\n")
    }
}
