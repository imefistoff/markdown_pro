import Foundation

/// A hybrid-logical-clock stamp. Ordered by its string form
/// `<15-digit millis>.<6-digit counter>.<device-id>`, so a lexicographic
/// sort on the transport and `Comparable` in memory always agree.
public struct HLC: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let millis: Int64
    public let counter: Int64
    public let deviceId: String

    public init(millis: Int64, counter: Int64, deviceId: String) {
        self.millis = millis
        self.counter = counter
        self.deviceId = deviceId
    }

    public var description: String {
        // 15 digits covers dates to the year 9999; 6 digits covers a million
        // ops inside a single millisecond — far past anything real.
        String(format: "%015lld.%06lld.%@", millis, counter, deviceId)
    }

    public static func parse(_ s: String) -> HLC? {
        let parts = s.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let millis = Int64(parts[0]),
              let counter = Int64(parts[1]) else { return nil }
        return HLC(millis: millis, counter: counter, deviceId: String(parts[2]))
    }

    public static func < (lhs: HLC, rhs: HLC) -> Bool {
        lhs.description < rhs.description
    }
}

/// Generates monotonically increasing stamps and advances past remote ones.
/// Not thread-safe; each process drives it single-threaded (the app on the
/// main actor, the MCP server single-threaded).
public final class HybridLogicalClock {
    private var lastMillis: Int64 = 0
    private var counter: Int64 = 0
    private let deviceId: String
    private let wallMillis: () -> Int64

    public init(deviceId: String, wallMillis: @escaping () -> Int64 = HybridLogicalClock.systemMillis) {
        self.deviceId = deviceId
        self.wallMillis = wallMillis
    }

    public static func systemMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Restore clock state after a restart from the highest local stamp seen.
    public func seed(lastMillis: Int64, counter: Int64) {
        if lastMillis > self.lastMillis || (lastMillis == self.lastMillis && counter > self.counter) {
            self.lastMillis = lastMillis
            self.counter = counter
        }
    }

    public func now() -> HLC {
        let wall = wallMillis()
        if wall > lastMillis {
            lastMillis = wall
            counter = 0
        } else {
            counter += 1
        }
        return HLC(millis: lastMillis, counter: counter, deviceId: deviceId)
    }

    /// Advance so the next local stamp sorts strictly after `remote`.
    public func observe(_ remote: HLC) {
        if remote.millis > lastMillis {
            lastMillis = remote.millis
            counter = remote.counter
        } else if remote.millis == lastMillis {
            counter = max(counter, remote.counter)
        }
    }
}
