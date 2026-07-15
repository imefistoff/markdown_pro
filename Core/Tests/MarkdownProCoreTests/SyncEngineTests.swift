import XCTest
@testable import MarkdownProCore

final class SyncEngineTests: XCTestCase {

    /// Two independent databases sharing one transport folder.
    private struct Pair {
        let a: TestDatabase, b: TestDatabase
        let engineA: SyncEngine, engineB: SyncEngine
        let folder: URL
    }

    private func makePair() throws -> Pair {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = try TestDatabase(), b = try TestDatabase()
        let engineA = SyncEngine(repo: a.repo, transport: FolderTransport(root: folder, deviceId: try a.repo.syncState().deviceId))
        let engineB = SyncEngine(repo: b.repo, transport: FolderTransport(root: folder, deviceId: try b.repo.syncState().deviceId))
        return Pair(a: a, b: b, engineA: engineA, engineB: engineB, folder: folder)
    }

    func testConvergenceAToB() throws {
        let p = try makePair()
        let projectId = try p.a.repo.createProject(name: "Shared")
        try p.a.repo.setProjectSynced(id: projectId, synced: true)
        let projectUUID = try p.a.repo.entityUUID(.project, id: projectId)!
        try p.a.repo.createTask(projectId: projectId, title: "Ship it", priority: .high)

        try p.engineA.sync()
        try p.b.repo.adoptProject(remoteUUID: projectUUID, name: "Shared")
        try p.engineB.sync()

        let tasks = try p.b.repo.listTasks()
        XCTAssertEqual(tasks.map(\.title), ["Ship it"])
        XCTAssertEqual(tasks.first?.priority, .high)
    }

    func testFieldLevelMergeKeepsBothEdits() throws {
        let p = try makePair()
        let projectId = try p.a.repo.createProject(name: "Shared")
        try p.a.repo.setProjectSynced(id: projectId, synced: true)
        let projectUUID = try p.a.repo.entityUUID(.project, id: projectId)!
        let taskId = try p.a.repo.createTask(projectId: projectId, title: "Original", priority: .none)
        let taskUUID = try p.a.repo.entityUUID(.task, id: taskId)!

        try p.engineA.sync()
        try p.b.repo.adoptProject(remoteUUID: projectUUID, name: "Shared")
        try p.engineB.sync()

        // A changes priority; B changes title — no sync between.
        try p.a.repo.updateTask(id: taskId, changes: .init(priority: .urgent))
        let bTaskId = try p.b.repo.db.query("SELECT id FROM tasks WHERE uuid = ?", [.text(taskUUID)]).first!.int("id")
        try p.b.repo.updateTask(id: bTaskId, changes: .init(title: "Renamed on B"))

        try p.engineA.sync(); try p.engineB.sync(); try p.engineA.sync()

        let onA = try p.a.repo.getTask(id: taskId)!.task
        XCTAssertEqual(onA.title, "Renamed on B")
        XCTAssertEqual(onA.priority, .urgent, "field-level LWW keeps both independent edits")
    }

    func testIdempotentSecondSyncChangesNothing() throws {
        let p = try makePair()
        let projectId = try p.a.repo.createProject(name: "Shared")
        try p.a.repo.setProjectSynced(id: projectId, synced: true)
        let projectUUID = try p.a.repo.entityUUID(.project, id: projectId)!
        try p.a.repo.createTask(projectId: projectId, title: "Once")

        try p.engineA.sync()
        try p.b.repo.adoptProject(remoteUUID: projectUUID, name: "Shared")
        try p.engineB.sync()
        let after = try p.b.repo.listTasks().count
        try p.engineB.sync() // second time
        XCTAssertEqual(try p.b.repo.listTasks().count, after, "syncing twice applies nothing new")
    }

    func testHLCCausalityRemoteEditWins() throws {
        // A's wall clock is far behind B's, but A edits AFTER seeing B's change.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("causal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = try TestDatabase(), b = try TestDatabase()
        let engineA = SyncEngine(repo: a.repo, transport: FolderTransport(root: folder, deviceId: try a.repo.syncState().deviceId))
        let engineB = SyncEngine(repo: b.repo, transport: FolderTransport(root: folder, deviceId: try b.repo.syncState().deviceId))

        let projectId = try b.repo.createProject(name: "Shared")
        try b.repo.setProjectSynced(id: projectId, synced: true)
        let projectUUID = try b.repo.entityUUID(.project, id: projectId)!
        let taskId = try b.repo.createTask(projectId: projectId, title: "B original")
        let taskUUID = try b.repo.entityUUID(.task, id: taskId)!

        try engineB.sync()
        try a.repo.adoptProject(remoteUUID: projectUUID, name: "Shared")
        try engineA.sync() // A now knows B's stamps; its clock observed them.

        // A edits after syncing — must win even though A's wall clock could be behind.
        let aTaskId = try a.repo.db.query("SELECT id FROM tasks WHERE uuid = ?", [.text(taskUUID)]).first!.int("id")
        try a.repo.updateTask(id: aTaskId, changes: .init(title: "A wins"))
        try engineA.sync(); try engineB.sync()

        XCTAssertEqual(try b.repo.getTask(id: taskId)!.task.title, "A wins")
    }

    func testSyncBeforeAdoptStillMaterializesAfterAdopt() throws {
        let p = try makePair()
        let projectId = try p.a.repo.createProject(name: "Shared")
        try p.a.repo.setProjectSynced(id: projectId, synced: true)
        let projectUUID = try p.a.repo.entityUUID(.project, id: projectId)!
        try p.a.repo.createTask(projectId: projectId, title: "Ship it")
        try p.engineA.sync()

        // B syncs BEFORE adopting — P's ops are fetched but skipped (unadopted).
        try p.engineB.sync()
        XCTAssertTrue(try p.b.repo.listTasks().isEmpty)

        // Adopt, then sync again — the task must still materialize.
        try p.b.repo.adoptProject(remoteUUID: projectUUID, name: "Shared")
        try p.engineB.sync()
        XCTAssertEqual(try p.b.repo.listTasks().map(\.title), ["Ship it"])
    }

    func testContainmentUnsyncedProjectNeverReachesFolder() throws {
        let p = try makePair()
        let projectId = try p.a.repo.createProject(name: "Private") // not synced
        try p.a.repo.createTask(projectId: projectId, title: "secret")
        try p.engineA.sync()

        let opsDir = p.folder.appendingPathComponent("ops")
        let logs = (try? FileManager.default.contentsOfDirectory(at: opsDir, includingPropertiesForKeys: nil)) ?? []
        for log in logs {
            let contents = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            XCTAssertFalse(contents.contains("secret"), "an unsynced project must never reach the transport")
        }
    }

    func testTaskMoveBetweenSyncedProjectsConvergesToCorrectProject() throws {
        let p = try makePair()
        let projA = try p.a.repo.createProject(name: "Alpha"); try p.a.repo.setProjectSynced(id: projA, synced: true)
        let projB = try p.a.repo.createProject(name: "Beta");  try p.a.repo.setProjectSynced(id: projB, synced: true)
        let projAUUID = try p.a.repo.entityUUID(.project, id: projA)!
        let projBUUID = try p.a.repo.entityUUID(.project, id: projB)!
        let taskId = try p.a.repo.createTask(projectId: projA, title: "mover")
        let taskUUID = try p.a.repo.entityUUID(.task, id: taskId)!
        try p.engineA.sync()
        try p.b.repo.adoptProject(remoteUUID: projAUUID, name: "Alpha")
        try p.b.repo.adoptProject(remoteUUID: projBUUID, name: "Beta")
        try p.engineB.sync()

        // Move on A from Alpha to Beta, sync across.
        try p.a.repo.updateTask(id: taskId, changes: .init(projectId: projB))
        try p.engineA.sync(); try p.engineB.sync()

        // On B, the task must now belong to B's local "Beta" project, not a stray integer.
        let bBetaId = try p.b.repo.db.query("SELECT id FROM projects WHERE uuid = ?", [.text(projBUUID)]).first!.int("id")
        let bTaskProject = try p.b.repo.db.query("SELECT project_id FROM tasks WHERE uuid = ?", [.text(taskUUID)]).first?.intOrNil("project_id")
        XCTAssertEqual(bTaskProject, bBetaId, "a cross-project move must land the task under the peer's matching project")
    }

    func testResetSyncCursorsZeroesSelfAndRemote() throws {
        let tdb = try TestDatabase()
        _ = try tdb.repo.syncState()   // ensures the self device row exists
        try tdb.repo.db.execute("UPDATE sync_devices SET cursor = 7 WHERE is_self = 1")
        try tdb.repo.db.execute("""
            INSERT INTO sync_devices (device_id, name, is_self, cursor) VALUES ('remote', 'R', 0, 9)
            """)

        try tdb.repo.resetSyncCursors()

        let cursors = try tdb.repo.db.query("SELECT cursor FROM sync_devices").map { $0.int("cursor") }
        XCTAssertEqual(cursors, [0, 0], "all cursors reset to 0")
    }
}
