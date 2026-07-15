import Foundation

/// Per-process sync identity: a stable device id and a clock restored to the
/// highest stamp this device has written. Built lazily from a `Repository`.
public final class SyncState {
    public let deviceId: String
    public let clock: HybridLogicalClock

    public init(db: SQLiteConnection, deviceName: String = SyncState.defaultDeviceName()) throws {
        // Reuse the existing self device, or mint one on first run.
        if let existing = try db.query("SELECT device_id FROM sync_devices WHERE is_self = 1 LIMIT 1").first {
            deviceId = existing.string("device_id")
        } else {
            let id = UUID().uuidString
            try db.execute("""
                INSERT INTO sync_devices (device_id, name, is_self, cursor)
                VALUES (?, ?, 1, 0)
                """, [.text(id), .text(deviceName)])
            deviceId = id
        }

        clock = HybridLogicalClock(deviceId: deviceId)
        // Seed past the highest stamp already known (any device — so we never
        // collide with a stamp another machine's ops taught us about). Remote
        // stamps can land in field_stamps/tombstones without ever appearing in
        // ops (e.g. this device made no local edit), so all three are considered.
        if let top = try db.query("""
            SELECT MAX(h) AS m FROM (
                SELECT MAX(hlc) AS h FROM ops
                UNION ALL SELECT MAX(hlc) FROM field_stamps
                UNION ALL SELECT MAX(hlc) FROM tombstones
            )
            """).first?.stringOrNil("m"),
           let stamp = HLC.parse(top) {
            clock.seed(lastMillis: stamp.millis, counter: stamp.counter)
        }
    }

    public static func defaultDeviceName() -> String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.isEmpty ? "This Mac" : name
    }
}
