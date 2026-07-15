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
}
