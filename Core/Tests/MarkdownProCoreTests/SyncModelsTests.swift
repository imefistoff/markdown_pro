import XCTest
@testable import MarkdownProCore

final class SyncModelsTests: XCTestCase {

    private func sampleOp(field: String?, value: String?) -> Op {
        Op(entity: .task, entityUUID: "task-uuid", kind: field == nil ? .insert : .update,
           field: field, value: value, parentUUID: "project-uuid",
           deviceId: "devA", hlc: HLC(millis: 10, counter: 0, deviceId: "devA").description,
           createdAt: "2026-07-15T10:00:00.000Z")
    }

    func testJSONLRoundTripPreservesOrder() {
        let ops = [
            sampleOp(field: nil, value: nil),
            sampleOp(field: "title", value: "Ship it"),
            sampleOp(field: "priority", value: "high")
        ]
        let data = OpCodec.encode(ops)
        // One op per line.
        let lineCount = String(data: data, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: true).count
        XCTAssertEqual(lineCount, 3)
        XCTAssertEqual(OpCodec.decode(data), ops)
    }

    func testNullValueSurvivesRoundTrip() {
        let op = sampleOp(field: "due_date", value: nil)
        let decoded = OpCodec.decode(OpCodec.encode([op]))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].value)
        XCTAssertEqual(decoded[0].field, "due_date")
    }

    func testDecodeSkipsMalformedLines() {
        let good = OpCodec.encode([sampleOp(field: "title", value: "keep me")])
        var mixed = Data("this is not json\n".utf8)
        mixed.append(good)
        mixed.append(Data("{ also broken\n".utf8))
        let decoded = OpCodec.decode(mixed)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].value, "keep me")
    }

    func testStampParsesFromHLCString() {
        let op = sampleOp(field: "title", value: "x")
        XCTAssertEqual(op.stamp, HLC(millis: 10, counter: 0, deviceId: "devA"))
    }
}
