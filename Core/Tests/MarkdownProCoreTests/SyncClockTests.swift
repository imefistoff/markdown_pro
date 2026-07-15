import XCTest
@testable import MarkdownProCore

final class SyncClockTests: XCTestCase {

    func testStampStringRoundTrips() {
        let hlc = HLC(millis: 1_700_000_000_000, counter: 5, deviceId: "devA")
        let parsed = HLC.parse(hlc.description)
        XCTAssertEqual(parsed, hlc)
    }

    func testLexicographicOrderMatchesComparable() {
        let a = HLC(millis: 100, counter: 0, deviceId: "devA")
        let b = HLC(millis: 100, counter: 1, deviceId: "devA")
        let c = HLC(millis: 101, counter: 0, deviceId: "devA")
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
        // The string order must agree with Comparable.
        XCTAssertLessThan(a.description, b.description)
        XCTAssertLessThan(b.description, c.description)
    }

    func testDeviceIdBreaksTiesDeterministically() {
        let a = HLC(millis: 100, counter: 0, deviceId: "devA")
        let b = HLC(millis: 100, counter: 0, deviceId: "devB")
        XCTAssertLessThan(a, b)
        XCTAssertNotEqual(a, b)
    }

    func testCounterIncrementsWithinSameMilli() {
        var fixed: Int64 = 500
        let clock = HybridLogicalClock(deviceId: "devA", wallMillis: { fixed })
        let first = clock.now()
        let second = clock.now()
        XCTAssertEqual(first.millis, 500)
        XCTAssertEqual(first.counter, 0)
        XCTAssertEqual(second.counter, 1)
        fixed = 501
        XCTAssertEqual(clock.now().counter, 0, "counter resets when the wall clock advances")
    }

    func testObserveAdvancesPastRemoteEvenWithLaggingWallClock() {
        let clock = HybridLogicalClock(deviceId: "slow", wallMillis: { 100 })
        clock.observe(HLC(millis: 900, counter: 3, deviceId: "fast"))
        let next = clock.now()
        XCTAssertGreaterThan(next, HLC(millis: 900, counter: 3, deviceId: "fast"),
                             "a local edit after seeing a remote stamp must sort after it")
    }
}
