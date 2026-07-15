import XCTest
@testable import MarkdownProCore

final class FolderTransportTests: XCTestCase {

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sync-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleOp(_ device: String, _ n: Int64) -> Op {
        Op(entity: .task, entityUUID: "u\(n)", kind: .update, field: "title", value: "v\(n)",
           parentUUID: nil, deviceId: device, hlc: HLC(millis: n, counter: 0, deviceId: device).description,
           createdAt: "2026-07-15T00:00:00.000Z")
    }

    func testPublishAppendsOnlyToOwnLog() throws {
        let root = try tempFolder()
        let a = FolderTransport(root: root, deviceId: "devA")
        try a.publish(ops: [sampleOp("devA", 1)], blobs: [], selfDevice: SyncDevice(deviceId: "devA", name: "A"))
        try a.publish(ops: [sampleOp("devA", 2)], blobs: [], selfDevice: SyncDevice(deviceId: "devA", name: "A"))

        let log = root.appendingPathComponent("ops/devA.jsonl")
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "appends, never rewrites")
    }

    func testFetchReturnsOtherDevicesOpsAfterCursor() throws {
        let root = try tempFolder()
        let a = FolderTransport(root: root, deviceId: "devA")
        let b = FolderTransport(root: root, deviceId: "devB")
        try a.publish(ops: [sampleOp("devA", 1), sampleOp("devA", 2)], blobs: [],
                      selfDevice: SyncDevice(deviceId: "devA", name: "A"))

        // B fetches from scratch: sees both of A's ops, none of its own.
        let first = try b.fetch(since: [:])
        XCTAssertEqual(first.ops.count, 2)
        XCTAssertEqual(first.cursors["devA"], 2)

        // A appends one more; B fetches from its last cursor and sees only the new one.
        try a.publish(ops: [sampleOp("devA", 3)], blobs: [], selfDevice: SyncDevice(deviceId: "devA", name: "A"))
        let second = try b.fetch(since: first.cursors)
        XCTAssertEqual(second.ops.count, 1)
        XCTAssertEqual(second.ops.first?.value, "v3")
    }

    func testBlobRoundTrips() throws {
        let root = try tempFolder()
        let a = FolderTransport(root: root, deviceId: "devA")
        let bytes = Data("# Spec\n".utf8)
        let hash = SyncHash.sha256(bytes)
        try a.publish(ops: [], blobs: [Blob(hash: hash, data: bytes)],
                      selfDevice: SyncDevice(deviceId: "devA", name: "A"))
        XCTAssertEqual(try a.fetchBlob(hash: hash), bytes)
        XCTAssertNil(try a.fetchBlob(hash: "deadbeef"))
    }
}
