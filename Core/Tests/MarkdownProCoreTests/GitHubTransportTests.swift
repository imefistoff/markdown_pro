import XCTest
@testable import MarkdownProCore

final class GitHubTransportTests: XCTestCase {
    override func setUp() { super.setUp(); FakeGitHubServer.reset() }

    private func transport(_ deviceId: String) -> GitHubTransport {
        GitHubTransport(owner: "o", repo: "r", token: "t", deviceId: deviceId, session: FakeGitHubServer.session())
    }

    private func op(_ n: Int64, device: String) -> Op {
        Op(entity: .task, entityUUID: "u\(n)", kind: .update, field: "title", value: "v\(n)",
           parentUUID: nil, deviceId: device, hlc: HLC(millis: n, counter: 0, deviceId: device).description,
           createdAt: "2026-07-15T00:00:00.000Z")
    }

    func testPublishWritesBatchBlobAndDevices() throws {
        let a = transport("devA")
        try a.publish(ops: [op(1, device: "devA")],
                      blobs: [Blob(hash: "h1", data: Data("doc".utf8))],
                      selfDevice: SyncDevice(deviceId: "devA", name: "A"))
        XCTAssertNotNil(FakeGitHubServer.files["ops/devA/1.jsonl"])
        XCTAssertEqual(FakeGitHubServer.files["blobs/h1"], Data("doc".utf8))
        XCTAssertNotNil(FakeGitHubServer.files["devices.json"])
    }

    func testSecondPublishIncrementsSeq() throws {
        let a = transport("devA")
        let dev = SyncDevice(deviceId: "devA", name: "A")
        try a.publish(ops: [op(1, device: "devA")], blobs: [], selfDevice: dev)
        try a.publish(ops: [op(2, device: "devA")], blobs: [], selfDevice: dev)
        XCTAssertNotNil(FakeGitHubServer.files["ops/devA/1.jsonl"])
        XCTAssertNotNil(FakeGitHubServer.files["ops/devA/2.jsonl"])
    }

    func testFetchReturnsOtherDeviceOpsPastCursorAndExcludesOwn() throws {
        try transport("devA").publish(ops: [op(1, device: "devA"), op(2, device: "devA")], blobs: [],
                                      selfDevice: SyncDevice(deviceId: "devA", name: "A"))
        let b = transport("devB")
        let first = try b.fetch(since: [:])
        XCTAssertEqual(first.ops.count, 2)
        XCTAssertEqual(first.cursors["devA"], 1)   // one batch (seq 1) consumed

        try transport("devA").publish(ops: [op(3, device: "devA")], blobs: [],
                                      selfDevice: SyncDevice(deviceId: "devA", name: "A"))
        let second = try b.fetch(since: first.cursors)
        XCTAssertEqual(second.ops.count, 1)
        XCTAssertEqual(second.ops.first?.value, "v3")
        // B never reads its own (empty) log; no crash, no self entry.
        XCTAssertNil(second.cursors["devB"])
    }

    func testBlobRoundTripAndMissing() throws {
        let a = transport("devA")
        try a.publish(ops: [], blobs: [Blob(hash: "hX", data: Data("bytes".utf8))],
                      selfDevice: SyncDevice(deviceId: "devA", name: "A"))
        XCTAssertEqual(try a.fetchBlob(hash: "hX"), Data("bytes".utf8))
        XCTAssertNil(try a.fetchBlob(hash: "nope"))
    }

    func testEmptyRepoFetchIsNoOp() throws {
        let changes = try transport("devB").fetch(since: [:])
        XCTAssertTrue(changes.ops.isEmpty)
    }

    /// The clincher: the real SyncEngine converges over GitHubTransport.
    func testConvergesThroughEngineOverSharedRepo() throws {
        let a = try TestDatabase(), b = try TestDatabase()
        let engineA = SyncEngine(repo: a.repo,
            transport: GitHubTransport(owner: "o", repo: "r", token: "t",
                                       deviceId: try a.repo.syncState().deviceId, session: FakeGitHubServer.session()))
        let engineB = SyncEngine(repo: b.repo,
            transport: GitHubTransport(owner: "o", repo: "r", token: "t",
                                       deviceId: try b.repo.syncState().deviceId, session: FakeGitHubServer.session()))

        let projectId = try a.repo.createProject(name: "Shared")
        try a.repo.setProjectSynced(id: projectId, synced: true)
        let projectUUID = try a.repo.entityUUID(.project, id: projectId)!
        try a.repo.createTask(projectId: projectId, title: "Ship it", priority: .high)

        try engineA.sync()
        try b.repo.adoptProject(remoteUUID: projectUUID, name: "Shared")
        try engineB.sync()

        let tasks = try b.repo.listTasks()
        XCTAssertEqual(tasks.map(\.title), ["Ship it"])
        XCTAssertEqual(tasks.first?.priority, .high)
    }

    func testPublishThrowsRatherThanWipingMalformedDevices() throws {
        FakeGitHubServer.files["devices.json"] = Data("not valid json".utf8)
        XCTAssertThrowsError(try transport("devA").publish(
            ops: [], blobs: [], selfDevice: SyncDevice(deviceId: "devA", name: "A")))
        // The malformed roster file was NOT overwritten with a self-only roster.
        XCTAssertEqual(FakeGitHubServer.files["devices.json"], Data("not valid json".utf8))
    }

    // The fake now models GitHub's sha contract, so the real API surfaces 422/409.
    func testFakeEnforcesShaOnPut() throws {
        let api = GitHubAPI(owner: "o", repo: "r", token: "t", session: FakeGitHubServer.session())
        try api.putContent("f.txt", data: Data("one".utf8), message: "create", sha: nil)   // 201
        // Overwrite without a sha must be rejected.
        XCTAssertThrowsError(try api.putContent("f.txt", data: Data("two".utf8), message: "x", sha: nil)) { error in
            guard case GitHubError.http(422, _) = error else { return XCTFail("expected 422, got \(error)") }
        }
        // Overwrite with the current sha succeeds.
        let existing = try api.getContent("f.txt")
        try api.putContent("f.txt", data: Data("two".utf8), message: "x", sha: existing?.sha)
        XCTAssertEqual(FakeGitHubServer.files["f.txt"], Data("two".utf8))
    }
}
