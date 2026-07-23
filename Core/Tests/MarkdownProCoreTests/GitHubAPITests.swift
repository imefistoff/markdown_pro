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

    func testUnauthorizedStatusThrows() {
        for code in [401, 403] {
            FakeGitHubServer.forceStatus = code
            XCTAssertThrowsError(try api().getRepoExists()) { err in
                guard case GitHubError.unauthorized = err else {
                    return XCTFail("expected .unauthorized for HTTP \(code), got \(err)")
                }
            }
            FakeGitHubServer.forceStatus = nil
        }
    }

    func testCreateFileNewPathIsCreated() throws {
        FakeGitHubServer.reset()
        let a = api()
        let outcome = try a.createFile("blobs/h", data: Data("x".utf8), message: "m")
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(FakeGitHubServer.files["blobs/h"], Data("x".utf8))
    }

    func testCreateFileExistingPathIsAlreadyExistsAndDoesNotOverwrite() throws {
        FakeGitHubServer.reset()
        let a = api()
        _ = try a.createFile("blobs/h", data: Data("orig".utf8), message: "m")
        let outcome = try a.createFile("blobs/h", data: Data("different".utf8), message: "m")
        XCTAssertEqual(outcome, .alreadyExists)
        XCTAssertEqual(FakeGitHubServer.files["blobs/h"], Data("orig".utf8), "create must not overwrite")
    }

    func testCreateFileGenuineErrorRethrows() throws {
        FakeGitHubServer.reset()
        FakeGitHubServer.forceStatus = 500
        let a = api()
        XCTAssertThrowsError(try a.createFile("blobs/h", data: Data("x".utf8), message: "m")) { error in
            guard case GitHubError.http(500, _) = error else { return XCTFail("expected 500, got \(error)") }
        }
    }
}
