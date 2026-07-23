# Idempotent GitHub Sync Writes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `GitHubTransport.publish()` from failing with GitHub HTTP 422
("sha wasn't supplied") when an immutable/content-addressed file already exists,
by making blob, ops, and devices.json writes idempotent under GitHub's
eventual consistency and publish retries.

**Architecture:** Three sequential Core tasks: (1) teach the test fake real
GitHub `sha` semantics + opt-in race hooks; (2) add a tolerant-create primitive
to `GitHubAPI`; (3) rewrite `GitHubTransport.publish` to use it for blobs, ops
(GET-and-compare loop), and devices.json (retry-on-conflict).

**Tech Stack:** Swift, `MarkdownProCore` (`import SQLite3`, no GRDB), XCTest,
`URLProtocol`-based fake GitHub server.

## Global Constraints

- Core + tests only. No schema, no data-model change, no UI change.
- Ops file names stay **monotonic integer seqs** (`ops/<device>/<seq>.jsonl`) —
  `fetch` parses them as the per-device cursor (`GitHubTransport.swift:52-56`).
- A collision must **never drop ops**: on an ops-seq collision, only treat it as
  done when the existing bytes are byte-identical to ours; otherwise bump the seq.
- Errors surface as `GitHubError.http(Int, String)` / `GitHubError.malformed(String)`.
- Reviewable design source: `docs/superpowers/specs/2026-07-23-idempotent-sync-writes-design.md`.
- Existing sync tests (`GitHubTransportTests`, `GitHubAPITests`, `SyncEngineTests`)
  must stay green; new race hooks are opt-in and default-off.

---

### Task 1: Teach `FakeGitHubServer` real `sha` semantics + race hooks

**Files:**
- Modify: `Core/Tests/MarkdownProCoreTests/FakeGitHubServer.swift`
  (statics + `reset()` at lines 7-17; the `PUT` case at lines 64-68; the
  directory-listing `GET` branch at lines 55-60)
- Test: `Core/Tests/MarkdownProCoreTests/GitHubTransportTests.swift`
  (add a semantics test)

**Interfaces:**
- Produces: `FakeGitHubServer.staleListingPaths: Set<String>` (paths omitted from
  directory listings only — exact-file GET/getRaw still return them) and
  `FakeGitHubServer.conflictOnce: Set<String>` (paths that return 409 on their
  next PUT, then behave normally). New PUT semantics: create → 201; PUT to an
  existing path with no `sha` → 422; with matching `sha` → 200; with mismatched
  `sha` → 409. Consumed by Tasks 2 and 3.

- [ ] **Step 1: Write a failing semantics test**

Add to `GitHubTransportTests.swift`:

```swift
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd Core && swift test --filter GitHubTransportTests/testFakeEnforcesShaOnPut`
Expected: FAIL — the current fake returns 201 for the second PUT, so
`XCTAssertThrowsError` fails ("did not throw").

- [ ] **Step 3: Add the statics and reset**

In `FakeGitHubServer.swift`, add to the statics (after line 10) and `reset()`:

```swift
    static var staleListingPaths: Set<String> = []
    static var conflictOnce: Set<String> = []
```

```swift
    static func reset() {
        files = [:]
        repoExists = true
        lastAuthHeader = nil
        forceStatus = nil
        staleListingPaths = []
        conflictOnce = []
    }
```

- [ ] **Step 4: Enforce sha on PUT and honor `conflictOnce`**

Replace the `case "PUT":` block (lines 64-68) with:

```swift
            case "PUT":
                if FakeGitHubServer.conflictOnce.remove(repoPath) != nil {
                    return finishJSON(409, ["message": "conflict: sha is not up to date"])
                }
                let body = (try? JSONSerialization.jsonObject(with: request.httpBodyData())) as? [String: Any]
                let b64 = body?["content"] as? String ?? ""
                let providedSha = body?["sha"] as? String
                let newData = Data(base64Encoded: b64) ?? Data()
                if FakeGitHubServer.files[repoPath] != nil {
                    guard let providedSha else {
                        return finishJSON(422, ["message": "Invalid request.\n\n\"sha\" wasn't supplied."])
                    }
                    guard providedSha == sha(repoPath) else {
                        return finishJSON(409, ["message": "sha does not match"])
                    }
                    FakeGitHubServer.files[repoPath] = newData
                    return finishJSON(200, ["content": ["path": repoPath]])
                }
                FakeGitHubServer.files[repoPath] = newData
                return finishJSON(201, ["content": ["path": repoPath]])
```

- [ ] **Step 5: Hide stale paths from directory listings only**

In the directory-listing `GET` branch, exclude stale-listed children. Replace the
children computation (lines 56-57) so it filters `staleListingPaths`:

```swift
                if FakeGitHubServer.files[repoPath] == nil {
                    let children = FakeGitHubServer.files.keys
                        .filter { $0.hasPrefix(repoPath + "/") && !FakeGitHubServer.staleListingPaths.contains($0) }
                        .map { String($0.dropFirst(repoPath.count + 1)).split(separator: "/").first.map(String.init) ?? "" }
                    if children.isEmpty { return finish(404, Data()) }
                    let arr = Array(Set(children)).map { ["name": $0, "path": repoPath + "/" + $0] }
                    return finishJSON(200, arr)
                }
```

Leave the exact-file `GET` (line 62-63) and the raw `GET` (lines 50-52) untouched
— a stale-listed file is still fetchable by exact path, which is what the ops
GET-and-compare relies on.

- [ ] **Step 6: Run the semantics test + full suite**

Run: `cd Core && swift test --filter GitHubTransportTests`
Expected: PASS — `testFakeEnforcesShaOnPut` green and the existing transport
tests still pass (they only ever create fresh paths or fetch, so the new sha
rules don't affect them).

Run: `cd Core && swift test`
Expected: PASS — full suite green (confirms no other test depended on the old
always-201 PUT).

- [ ] **Step 7: Commit**

```bash
git add Core/Tests/MarkdownProCoreTests/FakeGitHubServer.swift \
        Core/Tests/MarkdownProCoreTests/GitHubTransportTests.swift
git commit -m "test(sync): model GitHub sha semantics + race hooks in the fake"
```

---

### Task 2: `GitHubAPI.createFile` tolerant-create primitive

**Files:**
- Modify: `Core/Sources/MarkdownProCore/GitHubAPI.swift` (add the enum + method
  near `putContent`, ~line 84-93)
- Test: `Core/Tests/MarkdownProCoreTests/GitHubAPITests.swift`

**Interfaces:**
- Consumes: `FakeGitHubServer` sha semantics from Task 1; existing `send`,
  `contentsURL`, `getRaw`.
- Produces: `public enum GitHubAPI.CreateOutcome { case created, alreadyExists }`
  and `public func createFile(_ path: String, data: Data, message: String) throws
  -> CreateOutcome`. Consumed by Task 3.

- [ ] **Step 1: Write the failing tests**

Add to `GitHubAPITests.swift` (inside its `XCTestCase`; it already resets the
fake in `setUp` — mirror the existing style, adding a `setUp` reset if absent):

```swift
    func testCreateFileNewPathIsCreated() throws {
        FakeGitHubServer.reset()
        let api = GitHubAPI(owner: "o", repo: "r", token: "t", session: FakeGitHubServer.session())
        let outcome = try api.createFile("blobs/h", data: Data("x".utf8), message: "m")
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(FakeGitHubServer.files["blobs/h"], Data("x".utf8))
    }

    func testCreateFileExistingPathIsAlreadyExistsAndDoesNotOverwrite() throws {
        FakeGitHubServer.reset()
        let api = GitHubAPI(owner: "o", repo: "r", token: "t", session: FakeGitHubServer.session())
        _ = try api.createFile("blobs/h", data: Data("orig".utf8), message: "m")
        let outcome = try api.createFile("blobs/h", data: Data("different".utf8), message: "m")
        XCTAssertEqual(outcome, .alreadyExists)
        XCTAssertEqual(FakeGitHubServer.files["blobs/h"], Data("orig".utf8), "create must not overwrite")
    }

    func testCreateFileGenuineErrorRethrows() throws {
        FakeGitHubServer.reset()
        FakeGitHubServer.forceStatus = 500
        let api = GitHubAPI(owner: "o", repo: "r", token: "t", session: FakeGitHubServer.session())
        XCTAssertThrowsError(try api.createFile("blobs/h", data: Data("x".utf8), message: "m")) { error in
            guard case GitHubError.http(500, _) = error else { return XCTFail("expected 500, got \(error)") }
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Core && swift test --filter GitHubAPITests/testCreateFileNewPathIsCreated`
Expected: FAIL — compile error, `GitHubAPI` has no member `createFile`.

- [ ] **Step 3: Implement `createFile`**

In `GitHubAPI.swift`, add after `putContent` (after line 93):

```swift
    public enum CreateOutcome: Sendable { case created, alreadyExists }

    /// Create a file, never overwriting. If the path already exists — including a
    /// 422/409 race where a prior existence check missed it — reports
    /// `.alreadyExists` instead of throwing. Any other failure is rethrown.
    public func createFile(_ path: String, data: Data, message: String) throws -> CreateOutcome {
        let payload: [String: Any] = ["message": message, "content": data.base64EncodedString()]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (respData, code) = try send("PUT", contentsURL(path), body: body)
        if code == 200 || code == 201 { return .created }
        if code == 422 || code == 409, try getRaw(path) != nil { return .alreadyExists }
        throw GitHubError.http(code, String(data: respData, encoding: .utf8) ?? "")
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter GitHubAPITests`
Expected: PASS — all three new tests plus the existing `GitHubAPITests` green.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/MarkdownProCore/GitHubAPI.swift \
        Core/Tests/MarkdownProCoreTests/GitHubAPITests.swift
git commit -m "feat(sync): GitHubAPI.createFile tolerant-create primitive"
```

---

### Task 3: `GitHubTransport` idempotent publish

**Files:**
- Modify: `Core/Sources/MarkdownProCore/GitHubTransport.swift` (`publish`, lines 20-47)
- Test: `Core/Tests/MarkdownProCoreTests/GitHubTransportTests.swift`

**Interfaces:**
- Consumes: `GitHubAPI.createFile` / `CreateOutcome` (Task 2); `getRaw`,
  `getContent`, `listDir`, `putContent`; `OpCodec.encode`; the Task 1 race hooks.
- Produces: no new symbols; `publish` becomes idempotent under existence races.

- [ ] **Step 1: Write the failing tests**

Add to `GitHubTransportTests.swift`:

```swift
    // A blob already present on the remote is not re-uploaded and does not error.
    func testRepublishSameBlobIsNoOp() throws {
        let a = transport("devA")
        let dev = SyncDevice(deviceId: "devA", name: "A")
        let blob = Blob(hash: "h1", data: Data("doc".utf8))
        try a.publish(ops: [], blobs: [blob], selfDevice: dev)
        try a.publish(ops: [], blobs: [blob], selfDevice: dev)   // must not throw
        XCTAssertEqual(FakeGitHubServer.files["blobs/h1"], Data("doc".utf8))
    }

    // Retried publish under a stale directory listing: the batch already exists
    // with identical bytes, so it resolves without 422 and without duplication.
    func testOpsRetryUnderStaleListingIsIdempotent() throws {
        let a = transport("devA")
        let dev = SyncDevice(deviceId: "devA", name: "A")
        let ops = [op(1, device: "devA")]
        // Simulate a prior partial publish: batch 1 is already on the remote but
        // invisible to the directory listing.
        FakeGitHubServer.files["ops/devA/1.jsonl"] = OpCodec.encode(ops)
        FakeGitHubServer.staleListingPaths = ["ops/devA/1.jsonl"]
        try a.publish(ops: ops, blobs: [], selfDevice: dev)   // must not throw
        XCTAssertNil(FakeGitHubServer.files["ops/devA/2.jsonl"], "identical batch must not duplicate")
        XCTAssertEqual(FakeGitHubServer.files["ops/devA/1.jsonl"], OpCodec.encode(ops))
    }

    // A seq occupied by a *different* batch (stale listing) forces a bump, never
    // dropping the new ops.
    func testOpsCollisionWithDifferentContentBumpsSeq() throws {
        let a = transport("devA")
        let dev = SyncDevice(deviceId: "devA", name: "A")
        let otherBytes = OpCodec.encode([op(99, device: "devA")])
        FakeGitHubServer.files["ops/devA/1.jsonl"] = otherBytes
        FakeGitHubServer.staleListingPaths = ["ops/devA/1.jsonl"]
        let ops = [op(1, device: "devA")]
        try a.publish(ops: ops, blobs: [], selfDevice: dev)
        XCTAssertEqual(FakeGitHubServer.files["ops/devA/2.jsonl"], OpCodec.encode(ops))
        XCTAssertEqual(FakeGitHubServer.files["ops/devA/1.jsonl"], otherBytes, "existing batch untouched")
    }

    // A concurrent writer moves devices.json's sha; publish retries and succeeds.
    func testDevicesJsonConflictRetries() throws {
        let a = transport("devA")
        FakeGitHubServer.files["devices.json"] = Data("{\"devB\":\"B\"}".utf8)
        FakeGitHubServer.conflictOnce = ["devices.json"]
        try a.publish(ops: [], blobs: [], selfDevice: SyncDevice(deviceId: "devA", name: "A"))
        let roster = try JSONSerialization.jsonObject(with: FakeGitHubServer.files["devices.json"]!) as! [String: String]
        XCTAssertEqual(roster["devA"], "A")
        XCTAssertEqual(roster["devB"], "B", "concurrent writer's entry preserved")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Core && swift test --filter GitHubTransportTests/testOpsRetryUnderStaleListingIsIdempotent`
Expected: FAIL — the current `publish` calls `putContent(..., sha: nil)` for the
colliding ops path, which now (Task 1) returns 422, so `publish` throws.

- [ ] **Step 3: Rewrite `publish`**

Replace the body of `publish` (`GitHubTransport.swift:20-47`) with:

```swift
    public func publish(ops: [Op], blobs: [Blob], selfDevice: SyncDevice) throws {
        // Blobs are content-addressed: skip if present, tolerate a lost race.
        for blob in blobs where try api.getContent("blobs/\(blob.hash)") == nil {
            _ = try api.createFile("blobs/\(blob.hash)", data: blob.data, message: "blob \(blob.hash)")
        }
        // One immutable batch file under our own device directory. Under eventual
        // consistency a just-written seq can be invisible to listDir; GET-and-compare
        // resolves it without dropping ops.
        if !ops.isEmpty {
            let encoded = OpCodec.encode(ops)
            var seq = (try api.listDir("ops/\(deviceId)")
                .compactMap { Int($0.replacingOccurrences(of: ".jsonl", with: "")) }.max() ?? 0) + 1
            var published = false
            var attempts = 0
            while !published {
                attempts += 1
                guard attempts <= 8 else {
                    throw GitHubError.http(422, "ops publish: exhausted seq attempts near \(seq)")
                }
                let path = "ops/\(deviceId)/\(seq).jsonl"
                switch try api.createFile(path, data: encoded, message: "ops \(deviceId) \(seq)") {
                case .created:
                    published = true
                case .alreadyExists:
                    if let existing = try api.getRaw(path), existing == encoded {
                        published = true   // our own retried batch
                    } else {
                        seq += 1           // a different batch holds this seq
                    }
                }
            }
        }
        // Register self in devices.json (read-modify-write; retry if a concurrent
        // writer moves the sha out from under us).
        var attempt = 0
        while true {
            attempt += 1
            var roster: [String: String] = [:]
            var sha: String?
            if let existing = try api.getContent("devices.json") {
                guard let map = try? JSONSerialization.jsonObject(with: existing.data) as? [String: String] else {
                    throw GitHubError.malformed("devices.json")
                }
                roster = map
                sha = existing.sha
            }
            roster[selfDevice.deviceId] = selfDevice.name
            let payload = try JSONSerialization.data(withJSONObject: roster, options: [.sortedKeys])
            do {
                try api.putContent("devices.json", data: payload, message: "devices", sha: sha)
                return
            } catch let error as GitHubError {
                if case .http(let code, _) = error, code == 409 || code == 422, attempt < 3 { continue }
                throw error
            }
        }
    }
```

- [ ] **Step 4: Run the transport tests**

Run: `cd Core && swift test --filter GitHubTransportTests`
Expected: PASS — the four new tests plus every existing transport test green.

- [ ] **Step 5: Run the whole Core suite**

Run: `cd Core && swift test`
Expected: PASS — full suite green (in particular `SyncEngineTests`, which drives
`publish` end-to-end).

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/MarkdownProCore/GitHubTransport.swift \
        Core/Tests/MarkdownProCoreTests/GitHubTransportTests.swift
git commit -m "fix(sync): idempotent blob/ops/devices writes to survive GitHub races"
```

---

## Self-Review

**Spec coverage:**
- Section 1 (tolerant create) → Task 2. ✅
- Section 2 (idempotent blobs) → Task 3 Step 3 (blob loop). ✅
- Section 3 (ops GET-and-compare, bounded) → Task 3 Step 3 (ops loop, `published`
  flag replaces the spec's labeled-break note). ✅
- Section 4 (devices.json retry-on-409/422, bounded 3) → Task 3 Step 3. ✅
- Section 5a (fake sha semantics + staleListing/conflictOnce) → Task 1. ✅
- Section 5b (4 transport tests) → Task 3 Step 1. ✅
- Out-of-scope (seqs stay integer; >1MB getContent untouched) → honored; ops
  naming unchanged, no getContent change. ✅
- Verification (`swift test`) → every task's final steps. ✅

**Placeholder scan:** none — every code step is complete; the spec's labeled-loop
caveat is resolved concretely with a `published` bool.

**Type consistency:** `CreateOutcome` (`.created`/`.alreadyExists`),
`createFile(_:data:message:) -> CreateOutcome`, `getRaw(_) -> Data?`,
`getContent(_) -> (data:Data, sha:String)?`, `putContent(_:data:message:sha:)`,
`OpCodec.encode(_) -> Data`, and the fake's `staleListingPaths`/`conflictOnce`
statics are used identically across tasks.
