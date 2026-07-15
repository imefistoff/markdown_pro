import XCTest
@testable import MarkdownProCore

final class SyncReplayerTests: XCTestCase {

    /// Builds a local, adopted project and returns (repo, projectId, projectUUID).
    private func adoptedProject(_ tdb: TestDatabase) throws -> (Repository, Int64, String) {
        let repo = tdb.repo
        let projectId = try repo.createProject(name: "Adopted")
        try repo.setProjectSynced(id: projectId, synced: true)
        let uuid = try repo.entityUUID(.project, id: projectId)!
        return (repo, projectId, uuid)
    }

    private func op(_ entity: SyncEntity, _ uuid: String, _ kind: OpKind, field: String? = nil,
                    value: String? = nil, parent: String? = nil, hlc: HLC) -> Op {
        Op(entity: entity, entityUUID: uuid, kind: kind, field: field, value: value, parentUUID: parent,
           deviceId: "remote", hlc: hlc.description, createdAt: "2026-07-15T00:00:00.000Z")
    }

    func testInsertThenFieldUpdatesMaterializeATask() throws {
        let tdb = try TestDatabase()
        let (repo, _, projectUUID) = try adoptedProject(tdb)
        let taskUUID = "remote-task"
        let ops = [
            op(.task, taskUUID, .insert, parent: projectUUID, hlc: HLC(millis: 1, counter: 0, deviceId: "remote")),
            op(.task, taskUUID, .update, field: "title", value: "From remote", hlc: HLC(millis: 1, counter: 1, deviceId: "remote")),
            op(.task, taskUUID, .update, field: "priority", value: "high", hlc: HLC(millis: 1, counter: 2, deviceId: "remote"))
        ]
        try SyncReplayer(db: repo.db).apply(ops, adoptedProjectUUIDs: [projectUUID])

        let row = try repo.db.query("SELECT * FROM tasks WHERE uuid = ?", [.text(taskUUID)]).first
        XCTAssertEqual(row?.string("title"), "From remote")
        XCTAssertEqual(row?.string("priority"), "high")
    }

    func testStaleUpdateIsDropped() throws {
        let tdb = try TestDatabase()
        let (repo, projectId, projectUUID) = try adoptedProject(tdb)
        let taskId = try repo.createTask(projectId: projectId, title: "Local")
        let taskUUID = try repo.entityUUID(.task, id: taskId)!
        let localStamp = try repo.db.query(
            "SELECT hlc FROM field_stamps WHERE entity_uuid = ? AND field = 'title'", [.text(taskUUID)]).first!.string("hlc")
        let localMillis = HLC.parse(localStamp)!.millis

        // A remote update older than our local one.
        let stale = op(.task, taskUUID, .update, field: "title", value: "Older",
                       hlc: HLC(millis: localMillis - 1, counter: 0, deviceId: "remote"))
        try SyncReplayer(db: repo.db).apply([stale], adoptedProjectUUIDs: [projectUUID])

        XCTAssertEqual(try repo.db.query("SELECT title FROM tasks WHERE uuid = ?", [.text(taskUUID)]).first?.string("title"),
                       "Local", "a stale update must be dropped")
    }

    func testDeleteIsFinal() throws {
        let tdb = try TestDatabase()
        let (repo, projectId, projectUUID) = try adoptedProject(tdb)
        let taskId = try repo.createTask(projectId: projectId, title: "Doomed")
        let taskUUID = try repo.entityUUID(.task, id: taskId)!
        let ops = [
            op(.task, taskUUID, .delete, hlc: HLC(millis: 10, counter: 0, deviceId: "remote")),
            op(.task, taskUUID, .update, field: "title", value: "Resurrected?",
               hlc: HLC(millis: 20, counter: 0, deviceId: "remote"))
        ]
        try SyncReplayer(db: repo.db).apply(ops, adoptedProjectUUIDs: [projectUUID])
        XCTAssertTrue(try repo.db.query("SELECT 1 FROM tasks WHERE uuid = ?", [.text(taskUUID)]).isEmpty,
                      "a later edit must not resurrect a deleted task")
    }

    func testUnadoptedProjectOpsAreIgnored() throws {
        let tdb = try TestDatabase()
        let (repo, _, projectUUID) = try adoptedProject(tdb)
        let strangerProject = "not-adopted"
        let ops = [
            op(.task, "stranger-task", .insert, parent: strangerProject, hlc: HLC(millis: 1, counter: 0, deviceId: "remote")),
            op(.task, "stranger-task", .update, field: "title", value: "Nope", hlc: HLC(millis: 1, counter: 1, deviceId: "remote"))
        ]
        try SyncReplayer(db: repo.db).apply(ops, adoptedProjectUUIDs: [projectUUID])
        XCTAssertTrue(try repo.db.query("SELECT 1 FROM tasks WHERE uuid = 'stranger-task'").isEmpty)
    }

    func testLabelLinkReattachConverges() throws {
        let tdb = try TestDatabase()
        let (repo, projectId, projectUUID) = try adoptedProject(tdb)
        let taskId = try repo.createTask(projectId: projectId, title: "labelled")
        let taskUUID = try repo.entityUUID(.task, id: taskId)!
        let composite = "\(taskUUID):feature"
        let ops = [
            op(.label, "L", .update, field: "name", value: "feature", hlc: HLC(millis: 1, counter: 0, deviceId: "remote")),
            op(.taskLabel, composite, .update, field: "attached", value: "1", hlc: HLC(millis: 2, counter: 0, deviceId: "remote")),
            op(.taskLabel, composite, .update, field: "attached", value: "0", hlc: HLC(millis: 3, counter: 0, deviceId: "remote")),
            op(.taskLabel, composite, .update, field: "attached", value: "1", hlc: HLC(millis: 4, counter: 0, deviceId: "remote"))
        ]
        try SyncReplayer(db: repo.db).apply(ops, adoptedProjectUUIDs: [projectUUID])
        let attached = try repo.db.query("""
            SELECT 1 FROM task_labels tl JOIN labels l ON l.id = tl.label_id
            WHERE tl.task_id = ? AND l.name = 'feature'
            """, [.integer(taskId)])
        XCTAssertFalse(attached.isEmpty, "attach → detach → attach must end attached")
    }
}
