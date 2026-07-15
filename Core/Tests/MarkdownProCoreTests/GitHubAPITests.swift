import XCTest
@testable import MarkdownProCore

final class GitHubAPITests: XCTestCase {
    override func setUp() { super.setUp(); FakeGitHubServer.reset() }

    private func api() -> GitHubAPI {
        GitHubAPI(owner: "o", repo: "r", token: "tok-123", session: FakeGitHubServer.session())
    }

    func testPutThenGetRoundTripsAndSendsAuth() throws {
        try api().putContent("devices.json", data: Data(#"{"a":"A"}"#.utf8), message: "m", sha: nil)
        XCTAssertEqual(FakeGitHubServer.lastAuthHeader, "Bearer tok-123")
        let got = try api().getContent("devices.json")
        XCTAssertEqual(got?.data, Data(#"{"a":"A"}"#.utf8))
    }

    func testGetMissingReturnsNil() throws {
        XCTAssertNil(try api().getContent("nope.json"))
        XCTAssertNil(try api().getRaw("blobs/deadbeef"))
    }

    func testListDirReturnsChildNames() throws {
        try api().putContent("ops/devA/1.jsonl", data: Data("x".utf8), message: "m", sha: nil)
        try api().putContent("ops/devA/2.jsonl", data: Data("y".utf8), message: "m", sha: nil)
        XCTAssertEqual(try api().listDir("ops/devA").sorted(), ["1.jsonl", "2.jsonl"])
        XCTAssertEqual(try api().listDir("ops/none"), [])   // 404 dir → empty
    }

    func testRepoExistence() throws {
        XCTAssertTrue(try api().getRepoExists())
        FakeGitHubServer.repoExists = false
        XCTAssertFalse(try api().getRepoExists())
    }
}
