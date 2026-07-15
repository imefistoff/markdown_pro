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
}
