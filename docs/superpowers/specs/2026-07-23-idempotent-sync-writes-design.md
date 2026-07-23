# Idempotent GitHub Sync Writes — Design

**Date:** 2026-07-23
**Status:** Approved for planning
**Scope:** Stop `GitHubTransport.publish()` from failing with GitHub HTTP 422
("sha wasn't supplied") when an immutable/content-addressed file already exists
on the remote. Board task: **#27** (project *Markdown Pro*, labels `bug`,
`sync`). Core + tests only; no schema, no data-model change.

## Problem

`GitHubTransport.publish()` writes three file classes to the sync repo:

- **`blobs/<sha256>`** — content-addressed, immutable. Written create-only
  (`sha: nil`), guarded by a `getContent == nil` existence check
  (`GitHubTransport.swift:22-23`).
- **`ops/<device>/<seq>.jsonl`** — immutable op batches. Written create-only,
  `seq` chosen as `max(existing seqs) + 1` from a `listDir` scan
  (`GitHubTransport.swift:27-30`).
- **`devices.json`** — the one mutable, shared file. Correctly read-modify-written
  *with* a sha (`GitHubTransport.swift:35-46`), but with **no** retry when a
  concurrent writer changes it between our read and write.

GitHub's contents endpoint requires the existing file's `sha` to overwrite a
path that already exists; a create (`sha: nil`) against an existing path returns
**422 "sha wasn't supplied"**, and an update with a stale sha returns **409**.
The create-only assumption for blobs and ops breaks under:

1. **GitHub read-after-write eventual consistency** — immediately after a write,
   the existence check (`getContent`) or `listDir` can still report the path as
   absent, so the app re-issues a *create* for a path that now exists → 422.
2. **Retried partial publish** — `SyncEngine.publishLocal()` advances the
   self-cursor only *after* `publish()` returns (`SyncEngine.swift:53-55`). If
   `publish()` writes some blobs/ops and then throws later (e.g. the
   `devices.json` malformed guard, or any network error), the next sync retries
   `publish()` with the **identical** ops set, re-attempting the same immutable
   paths.

**Why correctness is currently preserved but fragile:** `SyncReplayer` applies
ops under last-write-wins-per-field with an idempotency gate
(`SyncReplayer.swift:3,199`), so a *duplicate* op batch replays as a no-op.
Duplicates are therefore harmless — but a naive "swallow the collision" fix is
**not** safe: if a colliding `ops/<device>/<seq>.jsonl` held *different* bytes,
swallowing would advance the cursor and permanently drop the current batch. The
fix must never lose ops.

## Decisions (agreed in brainstorming)

1. **Tolerant create, not body string-matching.** A create that fails with 422
   or 409 is resolved by a follow-up GET: if the path now exists, the create is
   treated as already-satisfied; otherwise the original error is rethrown. This
   never masks a genuine validation-422.
2. **Blobs:** an `alreadyExists` outcome is success — a `blobs/<sha256>` file is
   byte-identical to ours by construction (content addressing).
3. **Ops:** GET-and-compare. On a seq collision, fetch the existing batch; if its
   bytes equal ours it is our own retried publish (done); otherwise bump the seq
   and retry, bounded. Never loses ops, never leaves a duplicate batch.
4. **devices.json:** bounded retry-on-conflict. On 409 (or a create-race 422),
   re-read the roster + sha, re-merge self, and retry (up to 3 attempts).
5. **Replay idempotency is a safety net, not the fix.** We rely on it only to
   make the (now rare) duplicate batch harmless, not to excuse dropping ops.

## Section 1 — `GitHubAPI`: tolerant create (`GitHubAPI.swift`)

Add a create primitive that reports whether the file was created or already
present, distinguishing a real conflict from other errors by re-checking
existence with a raw GET (no base64 decode, so large blobs are fine):

```swift
public enum CreateOutcome: Sendable { case created, alreadyExists }

/// Create a file (never overwrites). If the path already exists — including a
/// 422/409 race where our existence check missed it — reports `.alreadyExists`
/// instead of throwing. Any other failure is rethrown unchanged.
public func createFile(_ path: String, data: Data, message: String) throws -> CreateOutcome {
    let payload: [String: Any] = ["message": message, "content": data.base64EncodedString()]
    let body = try JSONSerialization.data(withJSONObject: payload)
    let (respData, code) = try send("PUT", contentsURL(path), body: body)
    if code == 200 || code == 201 { return .created }
    if code == 422 || code == 409 {
        if try getRaw(path) != nil { return .alreadyExists }   // it does exist — race
    }
    throw GitHubError.http(code, String(data: respData, encoding: .utf8) ?? "")
}
```

`putContent` is retained unchanged for `devices.json` (sha-based update). Its
existing behavior of throwing `GitHubError.http(code, _)` on non-2xx is what the
Section 4 retry loop catches for 409/422.

## Section 2 — `GitHubTransport`: idempotent blobs (`GitHubTransport.swift`)

Keep the existence pre-check as a fast path (skips re-uploading known blobs), but
route the write through `createFile` so a lost race is tolerated:

```swift
for blob in blobs where try api.getContent("blobs/\(blob.hash)") == nil {
    _ = try api.createFile("blobs/\(blob.hash)", data: blob.data, message: "blob \(blob.hash)")
    // .alreadyExists is fine: identical content by hash.
}
```

## Section 3 — `GitHubTransport`: ops GET-and-compare (`GitHubTransport.swift`)

Replace the single create with a bounded loop:

```swift
if !ops.isEmpty {
    let encoded = OpCodec.encode(ops)
    var seq = (try api.listDir("ops/\(deviceId)")
        .compactMap { Int($0.replacingOccurrences(of: ".jsonl", with: "")) }.max() ?? 0) + 1
    var attempts = 0
    while true {
        attempts += 1
        guard attempts <= 8 else {
            throw GitHubError.http(422, "ops publish: exhausted seq attempts near \(seq)")
        }
        switch try api.createFile("ops/\(deviceId)/\(seq).jsonl", data: encoded,
                                  message: "ops \(deviceId) \(seq)") {
        case .created:
            break                       // written at seq
        case .alreadyExists:
            if let existing = try api.getRaw("ops/\(deviceId)/\(seq).jsonl"), existing == encoded {
                break                   // our own retried batch — already published
            }
            seq += 1
            continue                    // a different batch holds this seq — try the next slot
        }
        break
    }
}
```

(`break` inside the `switch` needs a labeled loop in Swift; the plan will use a
`while` with an explicit `done` flag or a labeled `outer:` loop so control exits
correctly. Behavior as described.)

## Section 4 — `GitHubTransport`: devices.json retry (`GitHubTransport.swift`)

Wrap the read-modify-write in a bounded retry so a concurrent device
registration doesn't surface as a sync error:

```swift
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
    } catch GitHubError.http(let code, _) where (code == 409 || code == 422) && attempt < 3 {
        continue   // concurrent writer moved the sha — re-read and re-merge
    }
}
```

The malformed-roster guard still throws (never silently replace a bad roster
with a self-only one).

## Section 5 — Tests

### 5a. `FakeGitHubServer` — real sha semantics + race simulation

The fake's PUT currently ignores `sha` and always returns 201
(`FakeGitHubServer.swift:64-68`). Teach it GitHub's contract:

- PUT to a **new** path (no `sha` in body) → 201, store bytes.
- PUT to an **existing** path with **no** `sha` → **422** with a body containing
  `"sha" wasn't supplied`.
- PUT to an existing path with a `sha` matching `sha(path)` → 200, update.
- PUT to an existing path with a **mismatched** `sha` → **409**.

Add opt-in race hooks (default off, so existing tests are unaffected):

- `staleListingPaths: Set<String>` — paths hidden from the next `GET`/`listDir`
  (simulates eventual consistency: the file is stored but not yet visible).
- `conflictOnce: Set<String>` — paths that return 409 on their next PUT then
  behave normally (simulates a concurrent devices.json writer).

### 5b. `GitHubTransportTests`

1. **Blob re-publish is a no-op.** Publish a blob, publish the same blob again;
   assert no throw and the server holds exactly one `blobs/<hash>`.
2. **Ops retry under stale listing doesn't 422 and doesn't lose ops.** Pre-store
   `ops/devA/1.jsonl` with the *same* encoded ops the transport is about to
   publish, mark it stale-listed (so `listDir` computes seq 1 again); publish →
   no throw, still exactly one `ops/devA/1.jsonl`, contents unchanged.
3. **Ops collision with different content bumps the seq.** Pre-store
   `ops/devA/1.jsonl` with *different* bytes, stale-listed; publish → the new
   batch lands at `ops/devA/2.jsonl`, and seq 1 is untouched.
4. **devices.json conflict retries.** Mark `devices.json` `conflictOnce`; publish
   → the first PUT 409s, the retry re-reads and succeeds, and the final roster
   contains self.

Existing `GitHubTransportTests` and `SyncEngineTests` must stay green.

## Out of scope

- Reworking the ops cursor model (seqs stay monotonic integers — `fetch` depends
  on them, `GitHubTransport.swift:52-56`).
- The pre-existing `getContent` behavior for files > 1 MB (returns non-base64
  encoding) — unrelated to this bug.
- Any UI change; the error dialog is a generic surface for thrown sync errors and
  needs no change once `publish()` stops throwing on these races.

## Verification

- `cd Core && swift test` — new + existing sync tests green.
- The user-visible acceptance: the "Sync failed: GitHub HTTP 422 … sha wasn't
  supplied" dialog no longer appears during normal local editing. (Not scriptable
  here; validated by the transport tests reproducing the race.)
