# Sync — GitHub Transport (Spec B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a private GitHub repo (REST API, fine-grained single-repo PAT) the app's **sole** sync mechanism — the folder transport is removed entirely — without changing anything above the `SyncTransport` protocol.

**Architecture:** One new `SyncTransport` implementation in `MarkdownProCore` (`GitHubTransport`, over a small `GitHubAPI` REST client using `URLSession`), a Keychain token store, a GitHub-only Settings connect form, and removal of Spec A's `FolderTransport` (and migration of its engine tests onto `GitHubTransport`). The `SyncEngine`, op recording, HLC, replay, and adoption are untouched — the engine already drives any `SyncTransport`.

> **Re-scope (2026-07-15):** Originally this plan added GitHub *alongside* the folder transport (a Folder|GitHub picker). Per the user, GitHub is now the ONLY mechanism and the folder transport is deleted. Tasks 1–4 (GitHubAPI, GitHubTransport, resetSyncCursors, Keychain) are transport-agnostic and unchanged. **Tasks 5–7 below are superseded by the "GitHub-only" task set appended at the end of this document.**

**Tech Stack:** Swift 5.9, `Foundation`/`URLSession` (no external Swift dependencies), `Security` (Keychain, app only), SwiftUI (macOS 14+), XCTest with a stubbed `URLProtocol` (no real network in tests).

Spec: `docs/superpowers/specs/2026-07-15-sync-github-transport-design.md`

## Global Constraints

- **No external Swift package dependencies.** GitHub is reached with `URLSession` (Foundation); no Octokit/libgit2. Keychain uses the system `Security` framework.
- The token is a **fine-grained PAT scoped to the single sync repo** (Contents: read/write). The app never creates a repo — the user creates the empty private repo first.
- **`GitHubTransport` takes the token as an injected `String`** and an injected `URLSession` (default `.shared`). It performs no Keychain access itself — that keeps Core network code unit-testable and keeps Keychain in the app.
- **Repo layout** (inside the repo): `ops/<device-id>/<seq>.jsonl` (immutable op batches, create-only), `blobs/<sha256>` (content-addressed, create-only), `devices.json` (id → name). One writer per path.
- The `SyncTransport` protocol is **unchanged**: `fetch(since:) -> RemoteChanges`, `publish(ops:blobs:selfDevice:)`, `fetchBlob(hash:) -> Data?`. `GitHubTransport` conforms exactly.
- **Cursors are transport-specific** (folder = line counts, GitHub = batch seqs). Switching the sync target MUST reset all `sync_devices.cursor` values (self + remote) to 0 so the new target is fully seeded. Replay is idempotent, so re-applying is safe.
- The app drives sync **synchronously on the main actor** (`Store.syncNow()`), as shipped in Spec A. `GitHubTransport`'s calls are synchronous (block on `URLSession` via a semaphore) so they fit that model.
- Tests never hit the real network: a stubbed `URLProtocol` models an in-memory repo. Core tests run via `cd Core && swift test`.

## File structure

New in `Core/Sources/MarkdownProCore/`:
- `GitHubAPI.swift` — low-level REST client: auth, request helper, error type, and typed primitives (`getContent`, `putContent`, `listDir`, `getRaw`, `getRepo`).
- `GitHubTransport.swift` — `GitHubTransport: SyncTransport` built on `GitHubAPI`.

New in `MarkdownPro/`:
- `KeychainTokenStore.swift` — save/load/delete the PAT (generic-password item).

Modified:
- `Core/Sources/MarkdownProCore/Repository.swift` — `resetSyncCursors()`.
- `MarkdownPro/Store.swift` — transport-type persistence, `loadSyncEngine`, `setGitHubSync`, `disconnectSync`, cursor reset on switch.
- `MarkdownPro/Views/SyncSettingsView.swift` — Folder | GitHub picker + GitHub form.
- `docs/QA_CHECKLIST.md` — a GitHub-sync section.

New tests in `Core/Tests/MarkdownProCoreTests/`:
- `FakeGitHubServer.swift` — a `URLProtocol` stub + in-memory repo (shared by the next two).
- `GitHubAPITests.swift`, `GitHubTransportTests.swift`.

---

### Task 1: GitHub REST client + in-memory fake server

The low-level client and the test double both tasks depend on. `GitHubAPI` wraps `URLSession` with auth and the handful of Contents/Trees calls the transport needs. `FakeGitHubServer` is a `URLProtocol` that models the repo in memory so tests never touch the network.

**Files:**
- Create: `Core/Sources/MarkdownProCore/GitHubAPI.swift`
- Create: `Core/Tests/MarkdownProCoreTests/FakeGitHubServer.swift`
- Create: `Core/Tests/MarkdownProCoreTests/GitHubAPITests.swift`

**Interfaces:**
- Consumes: `Foundation`.
- Produces:
  - `public struct GitHubAPI { public init(owner: String, repo: String, token: String, session: URLSession = .shared); func getContent(_ path: String) throws -> (data: Data, sha: String)?; func putContent(_ path: String, data: Data, message: String, sha: String?) throws; func listDir(_ path: String) throws -> [String]; func getRaw(_ path: String) throws -> Data?; func getRepoExists() throws -> Bool }`
  - `public enum GitHubError: Error, CustomStringConvertible { case http(Int, String); case malformed(String); case unauthorized }`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/MarkdownProCoreTests/FakeGitHubServer.swift`:

```swift
import Foundation
@testable import MarkdownProCore

/// In-memory model of one GitHub repo, served to `GitHubAPI` via `URLProtocol`.
/// Keyed by repo-relative path (e.g. "ops/devA/1.jsonl", "blobs/<sha>", "devices.json").
final class FakeGitHubServer {
    static var files: [String: Data] = [:]
    static var repoExists = true
    static var lastAuthHeader: String?
    static var forceStatus: Int?

    static func reset() {
        files = [:]
        repoExists = true
        lastAuthHeader = nil
        forceStatus = nil
    }

    /// A URLSession whose only protocol is the fake.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGitHubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class FakeGitHubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.github.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        FakeGitHubServer.lastAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        if let code = FakeGitHubServer.forceStatus { return finish(code, Data()) }
        guard let url = request.url else { return finish(400, Data()) }
        let path = url.path                       // e.g. /repos/o/r/contents/ops/devA/1.jsonl
        let method = request.httpMethod ?? "GET"

        // GET /repos/<o>/<r>  → repo existence
        if let range = path.range(of: "/repos/"), path[range.upperBound...].split(separator: "/").count == 2 {
            return FakeGitHubServer.repoExists ? finishJSON(200, ["full_name": "o/r"]) : finish(404, Data())
        }
        // Contents API: /repos/<o>/<r>/contents/<repoPath>
        if let r = path.range(of: "/contents/") {
            let repoPath = String(path[r.upperBound...]).removingPercentEncoding ?? String(path[r.upperBound...])
            let acceptRaw = request.value(forHTTPHeaderField: "Accept")?.contains("raw") == true
            switch method {
            case "GET" where acceptRaw:
                if let data = FakeGitHubServer.files[repoPath] { return finish(200, data) }
                return finish(404, Data())
            case "GET":
                // A directory listing if any file has this prefix and no exact file.
                if FakeGitHubServer.files[repoPath] == nil {
                    let children = FakeGitHubServer.files.keys.filter { $0.hasPrefix(repoPath + "/") }
                        .map { String($0.dropFirst(repoPath.count + 1)).split(separator: "/").first.map(String.init) ?? "" }
                    if children.isEmpty { return finish(404, Data()) }
                    let arr = Array(Set(children)).map { ["name": $0, "path": repoPath + "/" + $0] }
                    return finishJSON(200, arr)
                }
                let data = FakeGitHubServer.files[repoPath]!
                return finishJSON(200, ["content": data.base64EncodedString(), "sha": sha(repoPath)])
            case "PUT":
                let body = (try? JSONSerialization.jsonObject(with: request.httpBodyData())) as? [String: Any]
                let b64 = body?["content"] as? String ?? ""
                FakeGitHubServer.files[repoPath] = Data(base64Encoded: b64) ?? Data()
                return finishJSON(201, ["content": ["path": repoPath]])
            default:
                return finish(405, Data())
            }
        }
        finish(404, Data())
    }

    private func sha(_ path: String) -> String { String(path.hashValue, radix: 16) }

    private func finish(_ code: Int, _ data: Data) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    private func finishJSON(_ code: Int, _ obj: Any) {
        finish(code, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
    }
}

private extension URLRequest {
    /// URLProtocol strips httpBody for streamed bodies; read from the stream if needed.
    func httpBodyData() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}
```

Create `Core/Tests/MarkdownProCoreTests/GitHubAPITests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Core && swift test --filter GitHubAPITests`
Expected: FAIL — `cannot find 'GitHubAPI'` / `FakeGitHubServer`.

- [ ] **Step 3: Implement GitHubAPI.swift**

Create `Core/Sources/MarkdownProCore/GitHubAPI.swift`:

```swift
import Foundation

public enum GitHubError: Error, CustomStringConvertible {
    case http(Int, String)
    case malformed(String)
    case unauthorized

    public var description: String {
        switch self {
        case .http(let c, let m): return "GitHub HTTP \(c): \(m)"
        case .malformed(let m): return "GitHub malformed response: \(m)"
        case .unauthorized: return "GitHub token invalid or lacks access"
        }
    }
}

/// Minimal synchronous GitHub REST client over the Contents API. Synchronous so
/// it fits the app's main-actor `syncNow()`; it blocks on URLSession via a
/// semaphore. `session` is injectable for tests.
public struct GitHubAPI {
    private let owner: String
    private let repo: String
    private let token: String
    private let session: URLSession
    private let base = "https://api.github.com"

    public init(owner: String, repo: String, token: String, session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.token = token
        self.session = session
    }

    private func send(_ method: String, _ urlString: String, accept: String = "application/vnd.github+json",
                      body: Data? = nil) throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw GitHubError.malformed("bad url \(urlString)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.httpBody = body

        let sem = DispatchSemaphore(value: 0)
        var out: (Data, Int)?
        var failure: Error?
        session.dataTask(with: req) { data, resp, err in
            if let err { failure = err }
            else if let http = resp as? HTTPURLResponse { out = (data ?? Data(), http.statusCode) }
            else { failure = GitHubError.malformed("no response") }
            sem.signal()
        }.resume()
        sem.wait()
        if let failure { throw failure }
        guard let out else { throw GitHubError.malformed("no response") }
        if out.1 == 401 || out.1 == 403 { throw GitHubError.unauthorized }
        return out
    }

    private func contentsURL(_ path: String) -> String {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "\(base)/repos/\(owner)/\(repo)/contents/\(escaped)"
    }

    /// The decoded bytes + blob sha for a file, or nil on 404.
    public func getContent(_ path: String) throws -> (data: Data, sha: String)? {
        let (data, code) = try send("GET", contentsURL(path))
        if code == 404 { return nil }
        guard code == 200 else { throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = obj["content"] as? String,
              let sha = obj["sha"] as? String,
              let decoded = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")) else {
            throw GitHubError.malformed("contents \(path)")
        }
        return (decoded, sha)
    }

    /// Create or update a file. Pass `sha` to update an existing file, nil to create.
    public func putContent(_ path: String, data: Data, message: String, sha: String?) throws {
        var payload: [String: Any] = ["message": message, "content": data.base64EncodedString()]
        if let sha { payload["sha"] = sha }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (respData, code) = try send("PUT", contentsURL(path), body: body)
        guard code == 200 || code == 201 else {
            throw GitHubError.http(code, String(data: respData, encoding: .utf8) ?? "")
        }
    }

    /// Names of the immediate children of a directory, or [] if it doesn't exist.
    public func listDir(_ path: String) throws -> [String] {
        let (data, code) = try send("GET", contentsURL(path))
        if code == 404 { return [] }
        guard code == 200 else { throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.malformed("listDir \(path)")
        }
        return arr.compactMap { $0["name"] as? String }
    }

    /// Raw bytes for a file, or nil on 404.
    public func getRaw(_ path: String) throws -> Data? {
        let (data, code) = try send("GET", contentsURL(path), accept: "application/vnd.github.raw")
        if code == 404 { return nil }
        guard code == 200 else { throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    /// True if the repo is reachable with this token.
    public func getRepoExists() throws -> Bool {
        let (_, code) = try send("GET", "\(base)/repos/\(owner)/\(repo)")
        if code == 404 { return false }
        guard code == 200 else { throw GitHubError.http(code, "repo check") }
        return true
    }
}
```

- [ ] **Step 4: Run to verify passing**

Run: `cd Core && swift test --filter GitHubAPITests`
Expected: PASS — all four cases.

- [ ] **Step 5: Full suite**

Run: `cd Core && swift test`
Expected: PASS — no regressions.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/MarkdownProCore/GitHubAPI.swift Core/Tests/MarkdownProCoreTests/FakeGitHubServer.swift Core/Tests/MarkdownProCoreTests/GitHubAPITests.swift
git commit -m "feat(core): GitHub REST client + in-memory URLProtocol test double"
```

---
### Task 2: GitHubTransport

The `SyncTransport` implementation. `publish` writes new blobs (create-only) + one new op batch under our own device dir + registers self in `devices.json`; `fetch` lists device dirs, reads each other device's batches past the cursor, and returns ops + cursors + roster; `fetchBlob` reads a blob. It tolerates an empty repo. The clinching test runs the real `SyncEngine` over two `GitHubTransport`s sharing one fake repo and asserts convergence.

**Files:**
- Create: `Core/Sources/MarkdownProCore/GitHubTransport.swift`
- Create: `Core/Tests/MarkdownProCoreTests/GitHubTransportTests.swift`

**Interfaces:**
- Consumes: `GitHubAPI` (Task 1), `SyncTransport`/`Op`/`Blob`/`SyncDevice`/`RemoteChanges`/`OpCodec` (Spec A), `FakeGitHubServer` (Task 1).
- Produces:
  - `public final class GitHubTransport: SyncTransport { public init(owner: String, repo: String, token: String, deviceId: String, session: URLSession = .shared); public func verifyAccess() throws -> Bool; /* + the three protocol methods */ }`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/MarkdownProCoreTests/GitHubTransportTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Core && swift test --filter GitHubTransportTests`
Expected: FAIL — `cannot find 'GitHubTransport'`.

- [ ] **Step 3: Implement GitHubTransport.swift**

Create `Core/Sources/MarkdownProCore/GitHubTransport.swift`:

```swift
import Foundation

/// A `SyncTransport` over a private GitHub repo via the REST Contents API.
/// Layout: ops/<device-id>/<seq>.jsonl (immutable batches, create-only),
/// blobs/<sha256> (content-addressed), devices.json (id → name). One writer
/// per path, so two machines never modify the same file. The per-device cursor
/// is the highest batch seq consumed.
public final class GitHubTransport: SyncTransport {
    private let api: GitHubAPI
    private let deviceId: String

    public init(owner: String, repo: String, token: String, deviceId: String, session: URLSession = .shared) {
        self.api = GitHubAPI(owner: owner, repo: repo, token: token, session: session)
        self.deviceId = deviceId
    }

    /// True if the token can reach the repo — used by the connect flow.
    public func verifyAccess() throws -> Bool { try api.getRepoExists() }

    public func publish(ops: [Op], blobs: [Blob], selfDevice: SyncDevice) throws {
        // Blobs are content-addressed: write once, skip if already present.
        for blob in blobs where try api.getContent("blobs/\(blob.hash)") == nil {
            try api.putContent("blobs/\(blob.hash)", data: blob.data, message: "blob \(blob.hash)", sha: nil)
        }
        // One immutable batch file under our own device directory.
        if !ops.isEmpty {
            let maxSeq = try api.listDir("ops/\(deviceId)")
                .compactMap { Int($0.replacingOccurrences(of: ".jsonl", with: "")) }.max() ?? 0
            try api.putContent("ops/\(deviceId)/\(maxSeq + 1).jsonl", data: OpCodec.encode(ops),
                               message: "ops \(deviceId) \(maxSeq + 1)", sha: nil)
        }
        // Register self in devices.json (read-modify-write; the one shared file).
        var roster: [String: String] = [:]
        var sha: String?
        if let existing = try api.getContent("devices.json") {
            // Throw rather than silently wipe the roster: overwriting with a
            // self-only map (while keeping the old sha) would erase other devices.
            guard let map = try? JSONSerialization.jsonObject(with: existing.data) as? [String: String] else {
                throw GitHubError.malformed("devices.json")
            }
            roster = map
            sha = existing.sha
        }
        roster[selfDevice.deviceId] = selfDevice.name
        let payload = try JSONSerialization.data(withJSONObject: roster, options: [.sortedKeys])
        try api.putContent("devices.json", data: payload, message: "devices", sha: sha)
    }

    public func fetch(since cursors: [String: Int]) throws -> RemoteChanges {
        var allOps: [Op] = []
        var newCursors = cursors
        for device in try api.listDir("ops") where device != deviceId {
            let start = cursors[device] ?? 0
            var maxSeq = start
            let seqs = try api.listDir("ops/\(device)")
                .compactMap { Int($0.replacingOccurrences(of: ".jsonl", with: "")) }.sorted()
            for seq in seqs where seq > start {
                if let content = try api.getContent("ops/\(device)/\(seq).jsonl") {
                    allOps.append(contentsOf: OpCodec.decode(content.data))
                }
                maxSeq = max(maxSeq, seq)
            }
            newCursors[device] = maxSeq
        }
        var roster: [SyncDevice] = []
        if let dj = try api.getContent("devices.json"),
           let map = try? JSONSerialization.jsonObject(with: dj.data) as? [String: String] {
            roster = map.map { SyncDevice(deviceId: $0.key, name: $0.value) }
        }
        return RemoteChanges(ops: allOps, devices: roster, cursors: newCursors)
    }

    public func fetchBlob(hash: String) throws -> Data? {
        try api.getRaw("blobs/\(hash)")
    }
}
```

- [ ] **Step 4: Run to verify passing**

Run: `cd Core && swift test --filter GitHubTransportTests`
Expected: PASS — all six cases, including the engine-convergence test.

- [ ] **Step 5: Full suite**

Run: `cd Core && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/MarkdownProCore/GitHubTransport.swift Core/Tests/MarkdownProCoreTests/GitHubTransportTests.swift
git commit -m "feat(core): GitHubTransport (SyncTransport over the GitHub REST API)"
```

---

### Task 3: Cursor reset for target switch

Switching the sync target (folder ⇄ GitHub) must re-seed the new target: every `sync_devices.cursor` (self publish cursor + remote cursors) goes to 0 so the local op log republishes and all remote batches re-read. A one-method Core addition the Store calls on switch.

**Files:**
- Modify: `Core/Sources/MarkdownProCore/Repository.swift` (add to the `// MARK: - Sync engine support` section)
- Test: `Core/Tests/MarkdownProCoreTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `public func resetSyncCursors() throws` on `Repository`.

- [ ] **Step 1: Write the failing test**

Append to `Core/Tests/MarkdownProCoreTests/SyncEngineTests.swift`:

```swift
    func testResetSyncCursorsZeroesSelfAndRemote() throws {
        let tdb = try TestDatabase()
        _ = try tdb.repo.syncState()   // ensures the self device row exists
        try tdb.repo.db.execute("UPDATE sync_devices SET cursor = 7 WHERE is_self = 1")
        try tdb.repo.db.execute("""
            INSERT INTO sync_devices (device_id, name, is_self, cursor) VALUES ('remote', 'R', 0, 9)
            """)

        try tdb.repo.resetSyncCursors()

        let cursors = try tdb.repo.db.query("SELECT cursor FROM sync_devices").map { $0.int("cursor") }
        XCTAssertEqual(cursors, [0, 0], "all cursors reset to 0")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Core && swift test --filter SyncEngineTests`
Expected: FAIL — `has no member 'resetSyncCursors'`.

- [ ] **Step 3: Implement**

In `Repository.swift`, in the `// MARK: - Sync engine support` section, add:

```swift
    /// Zeroes every sync cursor (self publish cursor + all remote cursors) so a
    /// newly-selected transport target is seeded from the full local op log and
    /// re-reads every remote batch. Safe because replay is idempotent.
    public func resetSyncCursors() throws {
        try db.execute("UPDATE sync_devices SET cursor = 0")
    }
```

- [ ] **Step 4: Run to verify passing**

Run: `cd Core && swift test --filter SyncEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/MarkdownProCore/Repository.swift Core/Tests/MarkdownProCoreTests/SyncEngineTests.swift
git commit -m "feat(core): resetSyncCursors for switching the sync target"
```

---
### Task 4: Keychain token store (app)

The PAT lives in the macOS Keychain, never in `UserDefaults`. A tiny app-side helper over the `Security` framework. App-only (Core stays Keychain-free so `GitHubTransport` takes a plain injected token). Verified by the app build + the manual connect pass — the app target has no unit tests.

**Files:**
- Create: `MarkdownPro/KeychainTokenStore.swift`

**Interfaces:**
- Consumes: `Security`.
- Produces: `enum KeychainTokenStore { static func save(_ token: String); static func load() -> String?; static func delete() }`

- [ ] **Step 1: Implement KeychainTokenStore.swift**

Create `MarkdownPro/KeychainTokenStore.swift`:

```swift
import Foundation
import Security

/// The GitHub sync PAT, stored as a generic-password Keychain item. One token
/// at a time (single sync target). App-only — Core receives the token as a String.
enum KeychainTokenStore {
    private static let service = "com.markdownpro.sync.github"
    private static let account = "github-token"

    static func save(_ token: String) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 2: Build the app to confirm it compiles**

Run: `xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug -derivedDataPath /tmp/mdpro-b4 build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add MarkdownPro/KeychainTokenStore.swift
git commit -m "feat(app): Keychain store for the GitHub sync token"
```

---

### Task 5: Store — transport selection (folder | github)

Generalize `Store`'s sync wiring so it builds a `FolderTransport` *or* a `GitHubTransport` from a persisted transport type, with connect/disconnect for GitHub and a cursor reset whenever the target changes.

**Files:**
- Modify: `MarkdownPro/Store.swift`

**Interfaces:**
- Consumes: `GitHubTransport`, `KeychainTokenStore` (Task 4), `Repository.resetSyncCursors` (Task 3).
- Produces on `Store`: `@Published private(set) var syncTargetLabel: String?`; `func setSyncFolder(_:)` (updated); `@discardableResult func connectGitHub(owner: String, repo: String, token: String) -> String?` (nil on success, else an error message); `func disconnectSync()`.

- [ ] **Step 1: Add persistence keys and generalize engine construction**

In `Store.swift`, next to the existing `syncFolderKey`, add:

```swift
    private let syncTransportKey = "MarkdownProSyncTransport"   // "folder" | "github"
    private let ghOwnerKey = "MarkdownProGitHubOwner"
    private let ghRepoKey = "MarkdownProGitHubRepo"
    @Published private(set) var syncTargetLabel: String?
```

Replace `loadSyncFolder()` (the whole method) with a general `loadSyncEngine()`:

```swift
    private func loadSyncEngine() {
        guard let repo else { return }
        // Backward compatibility: a user who configured folder sync before this
        // change has syncFolderKey set but no syncTransportKey — treat as folder.
        let type = UserDefaults.standard.string(forKey: syncTransportKey)
            ?? (UserDefaults.standard.string(forKey: syncFolderKey).map { _ in "folder" })
        do {
            let deviceId = try repo.syncState().deviceId
            switch type {
            case "folder":
                guard let path = UserDefaults.standard.string(forKey: syncFolderKey), !path.isEmpty else { return }
                syncFolderPath = path
                syncTargetLabel = "Folder: \((path as NSString).lastPathComponent)"
                syncEngine = SyncEngine(repo: repo, transport: FolderTransport(root: URL(fileURLWithPath: path), deviceId: deviceId))
            case "github":
                guard let owner = UserDefaults.standard.string(forKey: ghOwnerKey),
                      let name = UserDefaults.standard.string(forKey: ghRepoKey),
                      let token = KeychainTokenStore.load() else { return }
                syncTargetLabel = "GitHub: \(owner)/\(name)"
                syncEngine = SyncEngine(repo: repo, transport:
                    GitHubTransport(owner: owner, repo: name, token: token, deviceId: deviceId))
            default:
                syncEngine = nil
            }
        } catch {
            errorMessage = "Could not start sync: \(error)"
        }
    }
```

Update `init()` — replace the `loadSyncFolder()` call with `loadSyncEngine()`.

- [ ] **Step 2: Update setSyncFolder and add connect/disconnect**

Replace `setSyncFolder(_:)` with a version that records the type and resets cursors on a genuine switch:

```swift
    func setSyncFolder(_ url: URL) {
        let switching = UserDefaults.standard.string(forKey: syncTransportKey) != "folder"
            || UserDefaults.standard.string(forKey: syncFolderKey) != url.path
        UserDefaults.standard.set("folder", forKey: syncTransportKey)
        UserDefaults.standard.set(url.path, forKey: syncFolderKey)
        if switching { perform { try $0.resetSyncCursors() } }
        loadSyncEngine()
        syncNow()
    }

    /// Verifies access, stores the token in the Keychain, switches the target to
    /// GitHub, and syncs. Returns nil on success or a user-facing error message.
    @discardableResult
    func connectGitHub(owner: String, repo: String, token: String) -> String? {
        guard let store = self.repo else { return "No database" }
        do {
            let deviceId = try store.syncState().deviceId
            let probe = GitHubTransport(owner: owner, repo: repo, token: token, deviceId: deviceId)
            guard try probe.verifyAccess() else { return "Repo \(owner)/\(repo) not found or no access." }
        } catch {
            return "Could not verify: \(error)"
        }
        KeychainTokenStore.save(token)
        UserDefaults.standard.set("github", forKey: syncTransportKey)
        UserDefaults.standard.set(owner, forKey: ghOwnerKey)
        UserDefaults.standard.set(repo, forKey: ghRepoKey)
        perform { try $0.resetSyncCursors() }
        loadSyncEngine()
        syncNow()
        return nil
    }

    func disconnectSync() {
        KeychainTokenStore.delete()
        UserDefaults.standard.removeObject(forKey: syncTransportKey)
        syncEngine = nil
        syncTargetLabel = nil
        syncFolderPath = nil
        adoptable = []
    }
```

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug -derivedDataPath /tmp/mdpro-b5 build`
Expected: `** BUILD SUCCEEDED **`. Fix any references to the removed `loadSyncFolder()`.

- [ ] **Step 4: Commit**

```bash
git add MarkdownPro/Store.swift
git commit -m "feat(app): Store transport selection (folder | github) with cursor reset on switch"
```

---

### Task 6: SyncSettingsView — transport picker + GitHub form

The UI: pick Folder or GitHub; the GitHub form takes `owner/repo` + token, Verify/Connect, shows the connected target, and a Disconnect. The "Available to adopt" list stays.

**Files:**
- Modify: `MarkdownPro/Views/SyncSettingsView.swift`

**Interfaces:**
- Consumes: `Store.connectGitHub`, `Store.disconnectSync`, `Store.setSyncFolder`, `Store.syncTargetLabel`, `Store.adoptable`.

- [ ] **Step 1: Rebuild the view with a transport picker**

Replace the body of `SyncSettingsView` with a Folder/GitHub picker. Keep the existing folder button and adoption list; add the GitHub form. Concretely:

```swift
import SwiftUI
import MarkdownProCore

struct SyncSettingsView: View {
    @EnvironmentObject var store: Store
    @State private var mode = "folder"          // "folder" | "github"
    @State private var owner = ""
    @State private var repo = "markdownpro-sync"
    @State private var token = ""
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync").font(.title2.bold())
            if let target = store.syncTargetLabel {
                HStack {
                    Text("Connected — \(target)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Disconnect") { store.disconnectSync() }
                }
            }
            Picker("Transport", selection: $mode) {
                Text("Folder").tag("folder")
                Text("GitHub").tag("github")
            }
            .pickerStyle(.segmented)

            if mode == "folder" {
                Button("Choose Folder…") { chooseFolder() }
                Text("Pick a folder both Macs share (Dropbox, Syncthing, …).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("owner", text: $owner)
                TextField("repo", text: $repo)
                SecureField("fine-grained token (Contents: read/write)", text: $token)
                HStack {
                    Button("Verify & Connect") { connectGitHub() }
                        .disabled(owner.isEmpty || repo.isEmpty || token.isEmpty)
                    if let status { Text(status).font(.caption).foregroundStyle(.red) }
                }
                Text("Create an empty private repo on GitHub first, then a fine-grained token scoped to just that repo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Text("Available to adopt").font(.headline)
            if store.adoptable.isEmpty {
                Text(store.syncTargetLabel == nil ? "Connect a sync target first."
                     : "No unadopted projects found.").foregroundStyle(.secondary)
            } else {
                List(store.adoptable) { project in
                    HStack {
                        Text(project.name)
                        Spacer()
                        Button("Adopt") { store.adopt(project) }
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 460, height: 420)
        .textFieldStyle(.roundedBorder)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { store.setSyncFolder(url) }
    }

    private func connectGitHub() {
        status = store.connectGitHub(owner: owner.trimmingCharacters(in: .whitespaces),
                                     repo: repo.trimmingCharacters(in: .whitespaces),
                                     token: token.trimmingCharacters(in: .whitespaces))
        if status == nil { token = "" }   // clear the field on success
    }
}
```

- [ ] **Step 2: Build the app**

Run: `xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug -derivedDataPath /tmp/mdpro-b6 build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add MarkdownPro/Views/SyncSettingsView.swift
git commit -m "feat(app): Sync settings transport picker + GitHub connect form"
```

---

### Task 7: QA checklist + manual two-machine pass

Document the GitHub-sync verification. The convergence logic is already proven by `GitHubTransportTests` (engine over a fake repo); this is the live GUI/network walk.

**Files:**
- Modify: `docs/QA_CHECKLIST.md`

- [ ] **Step 1: Append a GitHub-sync section**

Append to `docs/QA_CHECKLIST.md`:

```markdown
## § Sync (Spec B — GitHub)

One-time: create an empty **private** repo (with a README) on GitHub, and a
**fine-grained token** scoped to just that repo with Contents: read/write.

- [ ] Settings ▸ Sync ▸ GitHub: entering owner/repo + a bad token shows a clear
      "not found or no access" error and stays disconnected.
- [ ] A valid token connects; the header shows "Connected — GitHub: owner/repo".
- [ ] Toggle a project synced on Mac A → the repo gains `ops/<A>/1.jsonl`,
      `blobs/…`, and `devices.json` (check on github.com).
- [ ] On Mac B (same repo + its own token), the project appears under
      "Available to adopt"; adopting materializes tasks/subtasks/labels/docs.
- [ ] Field-level merge, delete-is-final, label convergence, and document
      restore all behave as in the folder transport (§ Sync (Spec A)).
- [ ] Switching a Mac from Folder to GitHub (or back) re-seeds the new target:
      all local synced projects republish and converge on the other Mac.
- [ ] Revoke/expire the token → sync surfaces a non-blocking "Sync failed"
      error and the app keeps working; reconnecting with a fresh token resumes.
- [ ] Disconnect clears the token (Keychain) and stops syncing; the repo is
      untouched.
```

- [ ] **Step 2: Commit**

```bash
git add docs/QA_CHECKLIST.md
git commit -m "docs: QA checklist for GitHub sync (Spec B)"
```

---

## Self-review notes (for the plan author)

Checked against the spec, 2026-07-15:

- **GitHubTransport conforms to the unchanged `SyncTransport`** (Task 2); the engine, recording, HLC, replay, adoption are untouched — proven by the engine-convergence test running over `GitHubTransport`.
- **Fine-grained single-repo token, injected** (Tasks 2, 4, 5): `GitHubTransport` takes a `String` token; the app stores it in the Keychain; Core is Keychain-free and network-testable.
- **Repo layout** `ops/<device>/<seq>.jsonl` + `blobs/<sha>` + `devices.json`, one-writer-per-path, immutable batches (Task 2).
- **No repo creation** — connect only verifies (`verifyAccess` → `getRepoExists`); empty repo tolerated (Task 2 `testEmptyRepoFetchIsNoOp`).
- **Cursor reset on target switch** (Task 3 + Task 5): `resetSyncCursors` zeroes self + remote; `setSyncFolder`/`connectGitHub` call it on a genuine switch.
- **Errors** — non-2xx throws `GitHubError`; the engine treats a failed sync as a no-op (`Store.syncNow` → `errorMessage`); 401/403 → `.unauthorized`.
- **No external dependencies** — `URLSession` + `Security` only.
- **Synchronous transport** fits main-actor `syncNow` (Task 1 semaphore).

Deviations from Spec A patterns: `GitHubTransport` is a `final class` (like `FolderTransport`) and blocks on `URLSession` synchronously — deliberate, to match the main-actor sync model.

Type consistency: `GitHubAPI`, `GitHubError`, `GitHubTransport`, `KeychainTokenStore`, `resetSyncCursors`, `connectGitHub`, `disconnectSync`, `loadSyncEngine`, `syncTargetLabel` are each defined once and used with those names throughout.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-15-sync-github-transport.md`. Two execution options:

**1. Subagent-Driven (recommended)** — a fresh subagent per task, spec+quality review between each, then a whole-branch review.

**2. Inline Execution** — execute tasks in this session with checkpoints.

Which approach? (Execution should run in a fresh worktree off the up-to-date `main`.)

---

## GitHub-only task set (supersedes Tasks 5–7)

After Tasks 1–4 (GitHub client, transport, cursor reset, Keychain), these three tasks make GitHub the sole sync mechanism and delete the folder transport. Order matters: **R1 (app) first** so the app stops referencing `FolderTransport`, then **R2 (Core)** deletes it and migrates the engine tests, keeping everything building at each step.

### Task R1: App — GitHub-only (remove folder from Store + SyncSettingsView)

**Files:** Modify `MarkdownPro/Store.swift`, `MarkdownPro/Views/SyncSettingsView.swift`.

- `Store`: delete all folder wiring — `syncFolderPath`, `syncFolderKey`, `setSyncFolder(_:)`, the backward-compat fallback, and the `"folder"` branch of `loadSyncEngine()`. `loadSyncEngine()` builds a `GitHubTransport` when `syncTransportKey == "github"` (owner/repo from UserDefaults, token from Keychain), else `syncEngine = nil`. Keep `connectGitHub`, `disconnectSync` (it should still clear `ghOwnerKey`/`ghRepoKey` + Keychain), `resetSyncCursors` use, `syncTargetLabel`, `adopt`, `syncNow`, triggers.
- `SyncSettingsView`: remove the transport picker and the "Choose Folder…" button; show only the GitHub connect form (owner/repo + token + Verify/Connect, connected status + Disconnect, and the Available-to-adopt list).
- Verify: `xcodebuild ... -scheme MarkdownPro build` → `** BUILD SUCCEEDED **`; `cd Core && swift test` still green.

### Task R2: Core — delete FolderTransport + migrate engine tests

**Files:** Delete `Core/Sources/MarkdownProCore/FolderTransport.swift`, `Core/Tests/MarkdownProCoreTests/FolderTransportTests.swift`. Modify `SyncEngineTests.swift`, `SyncDocumentTests.swift`, `SyncAdoptionTests.swift`, and any source comment referencing the folder transport (`SyncTransport.swift`, `Repository.swift`).

- Migrate each test file's `makePair()` (and equivalents) from `FolderTransport(root:deviceId:)` over a temp folder to `GitHubTransport(owner:repo:token:deviceId:session: FakeGitHubServer.session())` over a shared in-memory repo (call `FakeGitHubServer.reset()` in `setUp`) — mirroring `GitHubTransportTests.testConvergesThroughEngineOverSharedRepo`.
- Fix folder-specific assertions: the containment test that inspects `ops/*.jsonl` on disk should instead inspect `FakeGitHubServer.files` (assert no file's bytes contain the unsynced project's data).
- `SyncDocumentTests` keeps using `MARKDOWNPRO_SYNC_ROOT` for managed copies (transport-agnostic); only the transport in `makePair` changes.
- Verify: `cd Core && swift test` all green (the engine/doc/adoption convergence coverage now runs over `GitHubTransport`); the app still builds (R1 already removed its folder refs).

### Task R3: QA — GitHub-only checklist

**Files:** Modify `docs/QA_CHECKLIST.md`. Ensure the sync section is GitHub-only (no folder steps); keep the Spec A `§ Sync` convergence items but framed against the GitHub repo. Manual two-Mac pass over one private repo.

