import XCTest
@testable import MarkdownProCore

final class OpRecordingTests: XCTestCase {

    func testSelfDeviceIsStableAcrossReopen() throws {
        let tdb = try TestDatabase()
        let path = tdb.directory.appendingPathComponent("test.sqlite").path

        let first = try SyncState(db: tdb.repo.db, deviceName: "Test Mac")
        let db2 = try Database.open(path: path)
        let second = try SyncState(db: db2, deviceName: "Test Mac")

        XCTAssertEqual(first.deviceId, second.deviceId, "device id must persist across launches")

        let selfRows = try db2.query("SELECT device_id FROM sync_devices WHERE is_self = 1")
        XCTAssertEqual(selfRows.count, 1, "exactly one self device row")
    }

    func testClockSeedsPastHighestExistingOp() throws {
        let tdb = try TestDatabase()
        let state = try SyncState(db: tdb.repo.db, deviceName: "Test Mac")
        let high = HLC(millis: 9_000_000_000_000, counter: 7, deviceId: state.deviceId)
        try tdb.repo.db.execute("""
            INSERT INTO ops (entity, entity_uuid, kind, device_id, hlc, created_at)
            VALUES ('task', 'u', 'insert', ?, ?, ?)
            """, [.text(state.deviceId), .text(high.description), .text("2026-07-15T00:00:00.000Z")])

        let reseeded = try SyncState(db: tdb.repo.db, deviceName: "Test Mac")
        XCTAssertGreaterThan(reseeded.clock.now(), high,
                             "a fresh clock must not reissue a stamp already in the log")
    }

    // MARK: Project recording

    private func ops(_ repo: Repository, entity: String) throws -> [SQLRow] {
        try repo.db.query("SELECT * FROM ops WHERE entity = ? ORDER BY id", [.text(entity)])
    }

    func testUnsyncedProjectEmitsNoOps() throws {
        let tdb = try TestDatabase()
        let projectId = try tdb.repo.createProject(name: "Private work")
        try tdb.repo.createTask(projectId: projectId, title: "invisible")
        try tdb.repo.renameProject(id: projectId, name: "Renamed")

        XCTAssertTrue(try tdb.repo.db.query("SELECT id FROM ops").isEmpty,
                      "an unsynced project must emit zero ops")
    }

    func testSyncedProjectRecordsInsertAndFieldOps() throws {
        let tdb = try TestDatabase()
        let projectId = try tdb.repo.createProject(name: "Shared")
        try tdb.repo.setProjectSynced(id: projectId, synced: true)
        try tdb.repo.renameProject(id: projectId, name: "Shared board")

        let projectOps = try ops(tdb.repo, entity: "project")
        // insert on toggle-time snapshot + a name update at minimum.
        XCTAssertTrue(projectOps.contains { $0.string("kind") == "update" && $0.string("field") == "name" })
        XCTAssertTrue(projectOps.contains { $0.string("value") == "Shared board" })
    }

    func testFieldStampAdvancesOnUpdate() throws {
        let tdb = try TestDatabase()
        let projectId = try tdb.repo.createProject(name: "Shared")
        try tdb.repo.setProjectSynced(id: projectId, synced: true)
        try tdb.repo.renameProject(id: projectId, name: "First")
        try tdb.repo.renameProject(id: projectId, name: "Second")

        let uuid = try tdb.repo.db.query("SELECT uuid FROM projects WHERE id = ?", [.integer(projectId)])
            .first!.string("uuid")
        let stamp = try tdb.repo.db.query(
            "SELECT hlc FROM field_stamps WHERE entity_uuid = ? AND field = 'name'", [.text(uuid)]).first
        XCTAssertNotNil(stamp)
        // The recorded stamp matches the latest name op.
        let latestNameOp = try tdb.repo.db.query(
            "SELECT hlc FROM ops WHERE entity_uuid = ? AND field = 'name' ORDER BY id DESC LIMIT 1",
            [.text(uuid)]).first
        XCTAssertEqual(stamp?.string("hlc"), latestNameOp?.string("hlc"))
    }

    func testDeleteOpAndTombstoneShareOneStamp() throws {
        let tdb = try TestDatabase()
        let projectId = try tdb.repo.createProject(name: "Doomed")
        try tdb.repo.setProjectSynced(id: projectId, synced: true)
        let uuid = try tdb.repo.db.query("SELECT uuid FROM projects WHERE id = ?", [.integer(projectId)]).first!.string("uuid")
        try tdb.repo.deleteProject(id: projectId)
        let opHlc = try tdb.repo.db.query("SELECT hlc FROM ops WHERE kind = 'delete' AND entity_uuid = ?", [.text(uuid)]).first?.stringOrNil("hlc")
        let tsHlc = try tdb.repo.db.query("SELECT hlc FROM tombstones WHERE entity_uuid = ?", [.text(uuid)]).first?.stringOrNil("hlc")
        XCTAssertNotNil(opHlc)
        XCTAssertEqual(opHlc, tsHlc, "delete op and its tombstone must share exactly one HLC")
    }

    // MARK: Task recording

    private func syncedProject(_ repo: Repository, name: String = "Shared") throws -> Int64 {
        let id = try repo.createProject(name: name)
        try repo.setProjectSynced(id: id, synced: true)
        return id
    }

    func testCreateTaskRecordsInsertWithProjectParent() throws {
        let tdb = try TestDatabase()
        let projectId = try syncedProject(tdb.repo)
        let taskId = try tdb.repo.createTask(projectId: projectId, title: "Do the thing", priority: .high)

        let taskUUID = try tdb.repo.entityUUID(.task, id: taskId)!
        let projectUUID = try tdb.repo.entityUUID(.project, id: projectId)!
        let insert = try tdb.repo.db.query(
            "SELECT * FROM ops WHERE entity = 'task' AND kind = 'insert' AND entity_uuid = ?",
            [.text(taskUUID)]).first
        XCTAssertEqual(insert?.stringOrNil("parent_uuid"), projectUUID)
        // Field ops carry the values.
        let fields = try tdb.repo.db.query(
            "SELECT field, value FROM ops WHERE entity = 'task' AND kind = 'update' AND entity_uuid = ?",
            [.text(taskUUID)])
        XCTAssertTrue(fields.contains { $0.string("field") == "title" && $0.string("value") == "Do the thing" })
        XCTAssertTrue(fields.contains { $0.string("field") == "priority" && $0.string("value") == "high" })
    }

    func testUpdateTaskRecordsOnlyChangedFields() throws {
        let tdb = try TestDatabase()
        let projectId = try syncedProject(tdb.repo)
        let taskId = try tdb.repo.createTask(projectId: projectId, title: "Original")
        let taskUUID = try tdb.repo.entityUUID(.task, id: taskId)!
        // Clear the create-time ops from view by remembering the current max id.
        let before = try tdb.repo.db.query("SELECT COALESCE(MAX(id), 0) AS m FROM ops").first!.int("m")

        try tdb.repo.updateTask(id: taskId, changes: .init(status: .inProgress))

        let after = try tdb.repo.db.query(
            "SELECT field FROM ops WHERE id > ? AND entity_uuid = ?", [.integer(before), .text(taskUUID)])
        XCTAssertEqual(after.compactMap { $0.stringOrNil("field") }, ["status"])
        XCTAssertEqual(try tdb.repo.db.query(
            "SELECT value FROM ops WHERE id > ? AND field = 'status'", [.integer(before)]).first?.string("value"),
            "in_progress")
    }

    func testDeleteTaskTombstones() throws {
        let tdb = try TestDatabase()
        let projectId = try syncedProject(tdb.repo)
        let taskId = try tdb.repo.createTask(projectId: projectId, title: "temp")
        let taskUUID = try tdb.repo.entityUUID(.task, id: taskId)!
        try tdb.repo.deleteTask(id: taskId)

        XCTAssertFalse(try tdb.repo.db.query(
            "SELECT 1 FROM ops WHERE kind = 'delete' AND entity_uuid = ?", [.text(taskUUID)]).isEmpty)
        XCTAssertFalse(try tdb.repo.db.query(
            "SELECT 1 FROM tombstones WHERE entity_uuid = ?", [.text(taskUUID)]).isEmpty)
    }

    func testUpdateTaskSameDueDateRecordsNoDueDateOp() throws {
        let tdb = try TestDatabase()
        let projectId = try tdb.repo.createProject(name: "Shared")
        try tdb.repo.setProjectSynced(id: projectId, synced: true)
        let taskId = try tdb.repo.createTask(projectId: projectId, title: "T", dueDate: "2026-08-01")
        let taskUUID = try tdb.repo.entityUUID(.task, id: taskId)!
        let before = try tdb.repo.db.query("SELECT COALESCE(MAX(id), 0) AS m FROM ops").first!.int("m")
        try tdb.repo.updateTask(id: taskId, changes: .init(dueDate: "2026-08-01"))
        let dueOps = try tdb.repo.db.query(
            "SELECT 1 FROM ops WHERE id > ? AND entity_uuid = ? AND field = 'due_date'",
            [.integer(before), .text(taskUUID)])
        XCTAssertTrue(dueOps.isEmpty, "re-setting the same due date must record no op")
    }

    func testTaskMoveRecordsProjectIdUnderNewProject() throws {
        let tdb = try TestDatabase()
        let projectA = try tdb.repo.createProject(name: "A")
        try tdb.repo.setProjectSynced(id: projectA, synced: true)
        let projectB = try tdb.repo.createProject(name: "B")
        try tdb.repo.setProjectSynced(id: projectB, synced: true)
        let taskId = try tdb.repo.createTask(projectId: projectA, title: "movable")
        let taskUUID = try tdb.repo.entityUUID(.task, id: taskId)!
        let before = try tdb.repo.db.query("SELECT COALESCE(MAX(id), 0) AS m FROM ops").first!.int("m")
        try tdb.repo.updateTask(id: taskId, changes: .init(projectId: projectB))
        let op = try tdb.repo.db.query(
            "SELECT value FROM ops WHERE id > ? AND entity_uuid = ? AND field = 'project_id'",
            [.integer(before), .text(taskUUID)]).first
        XCTAssertEqual(op?.stringOrNil("value"), String(projectB), "a move records project_id under the new project")
    }

    // MARK: Subtask / label recording

    func testSubtaskRecordsUnderTaskParent() throws {
        let tdb = try TestDatabase()
        let projectId = try syncedProject(tdb.repo)
        let taskId = try tdb.repo.createTask(projectId: projectId, title: "parent")
        let subId = try tdb.repo.addSubtask(taskId: taskId, title: "child")

        let subUUID = try tdb.repo.entityUUID(.subtask, id: subId)!
        let taskUUID = try tdb.repo.entityUUID(.task, id: taskId)!
        let insert = try tdb.repo.db.query(
            "SELECT parent_uuid FROM ops WHERE entity = 'subtask' AND kind = 'insert' AND entity_uuid = ?",
            [.text(subUUID)]).first
        XCTAssertEqual(insert?.stringOrNil("parent_uuid"), taskUUID)
    }

    func testSetSubtaskDoneRecordsUpdate() throws {
        let tdb = try TestDatabase()
        let projectId = try syncedProject(tdb.repo)
        let taskId = try tdb.repo.createTask(projectId: projectId, title: "parent")
        let subId = try tdb.repo.addSubtask(taskId: taskId, title: "child")
        try tdb.repo.setSubtaskDone(id: subId, done: true)

        let subUUID = try tdb.repo.entityUUID(.subtask, id: subId)!
        XCTAssertEqual(try tdb.repo.db.query(
            "SELECT value FROM ops WHERE entity_uuid = ? AND field = 'done' ORDER BY id DESC LIMIT 1",
            [.text(subUUID)]).first?.string("value"), "1")
    }

    func testLabelLinkIsLWWBoolean() throws {
        let tdb = try TestDatabase()
        let projectId = try syncedProject(tdb.repo)
        let taskId = try tdb.repo.createTask(projectId: projectId, title: "labelled")
        let taskUUID = try tdb.repo.entityUUID(.task, id: taskId)!
        let labelId = try tdb.repo.addLabel(taskId: taskId, name: "feature")
        try tdb.repo.removeLabel(taskId: taskId, labelId: labelId)

        let composite = "\(taskUUID):feature"
        let linkOps = try tdb.repo.db.query(
            "SELECT kind, field, value FROM ops WHERE entity = 'task_label' AND entity_uuid = ? ORDER BY id",
            [.text(composite)])
        XCTAssertTrue(linkOps.allSatisfy { $0.string("kind") == "update" && $0.string("field") == "attached" },
                      "links are LWW boolean updates, never insert/delete")
        XCTAssertEqual(linkOps.map { $0.string("value") }, ["1", "0"])
    }
}
