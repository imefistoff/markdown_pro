# Sync — GitHub Transport (Spec B) — Design

**Date:** 2026-07-15
**Builds on:** Spec A — Sync Core (`2026-07-14-sync-core-design.md`), now merged.
**Status:** Draft — awaiting review

## Goal

Let the two Macs sync through a **private GitHub repository** instead of (or in
addition to) a shared folder. This removes the dependency on Dropbox/Syncthing:
the transport becomes a repo the user owns, reachable from anywhere with a
network connection.

Spec A built the entire sync core behind a `SyncTransport` protocol precisely so
this could slot in. **Spec B adds exactly one new transport** — `GitHubTransport`
— plus a token store and a connect UI. Nothing above the protocol changes:
op recording, the hybrid logical clock, replay/convergence, adoption, the
`SyncEngine`, and the launch/quit/debounced (main-actor) triggers are all
untouched.

## Why these choices

- **Personal Access Token, not OAuth.** A classic PAT the user pastes is the
  simplest possible auth for a personal two-machine tool: no registered OAuth
  app, no embedded client id, no device-flow polling, no callback server. The
  token lives in the macOS Keychain, per Mac.
- **REST API, not a local git clone.** Talking to GitHub's HTTP API with
  `URLSession` keeps the app dependency-free (no `git` binary, no credential
  helper, no libgit2/Octokit) and stateless beyond its own SQLite. A failed call
  is just "sync is a no-op, retry next cycle" — no half-finished clone or merge
  state. The data (task ops + small markdown blobs) is tiny, so git's only real
  edge — delta transfer at scale — does not pay for its costs here.
- **App creates the repo.** On connect the app creates the private repo if it
  is missing, for smoother onboarding. This requires a classic `repo`-scoped
  token (a fine-grained single-repo token cannot create a repo). **Trade-off,
  accepted:** a classic `repo` token can read/write *all* of the user's repos,
  not just the sync repo. Documented so the choice is deliberate.

## Scope

**In:**

- A `GitHubTransport` conforming to the existing `SyncTransport` protocol.
- Classic-PAT auth stored in the macOS Keychain.
- Repo provisioning: verify the token, create `markdownpro-sync` (private) if
  absent, else use it.
- A Settings ▸ Sync transport picker: **Folder** (existing) or **GitHub**.
- Cursor reset when the sync target changes, so a new target is fully seeded.

**Out (YAGNI / later):**

- OAuth / device flow; fine-grained tokens; repo creation avoidance.
- A local git clone, git binary, or credential helper.
- Git LFS, branches, or pull requests.
- Multiple sync repos, or per-project transport selection (the transport is
  app-wide, one active target).
- Log compaction (still deferred, same as Spec A).

## The transport contract (unchanged)

`GitHubTransport` implements the Spec A protocol verbatim:

```swift
public protocol SyncTransport {
    func fetch(since cursors: [String: Int]) throws -> RemoteChanges
    func publish(ops: [Op], blobs: [Blob], selfDevice: SyncDevice) throws
    func fetchBlob(hash: String) throws -> Data?
}
```

Because the `SyncEngine` treats each device's cursor as an opaque `Int`,
`GitHubTransport` is free to define its own cursor meaning (batch sequence
number) without any engine change.

## Repo layout

Inside the private repo:

```
ops/<device-id>/<seq>.jsonl   # immutable op batches — create-only PUT
blobs/<sha256>                # content-addressed document bytes — create-only
devices.json                  # device id → display name
```

Each device writes **only** under its own `ops/<device-id>/` and new `blobs/`,
and reads the others'. **One writer per path** means two machines never modify
the same file, so there is nothing for git to conflict on.

Op batches are **immutable, one per publish** (`<seq>` increments), rather than
one growing file appended in place. This suits REST: every write is a create,
never a read-modify-write, and each `fetch` GETs only *new* batch files — the
log's history is never re-downloaded.

`devices.json` is the one shared-write file; it is small, self-healing (a lost
entry reappears on that device's next publish), and written last.

## GitHubTransport — the three methods

All requests carry `Authorization: Bearer <PAT>` and target
`https://api.github.com/repos/<owner>/<repo>/…`. `<owner>` is the authenticated
user; `<repo>` defaults to `markdownpro-sync`.

**`publish(ops:blobs:selfDevice:)`**
1. For each new blob, PUT `blobs/<hash>` if it does not already exist
   (create-only; content-addressed, so identical bytes are written once).
2. PUT a new `ops/<self-device>/<nextSeq>.jsonl` containing the batch
   (`OpCodec.encode`). `nextSeq` = (highest existing seq for self) + 1.
3. GET+PUT `devices.json` to register `selfDevice` (id → name).

**`fetch(since cursors:)`**
1. One Git Trees API call (`GET /git/trees/HEAD?recursive=1`) lists the whole
   repo in a single request.
2. For every device directory except our own, take its batch files with
   `seq > cursors[device]`, GET each, `OpCodec.decode`, in seq order.
3. Return `RemoteChanges(ops:, devices:, cursors:)` where each new cursor is the
   highest seq consumed for that device, and `devices` comes from `devices.json`.

**`fetchBlob(hash:)`** — GET `blobs/<hash>` (raw media type); `nil` on 404.

**Errors** — any non-2xx (network down, 401, 403 rate-limit, 404 tree) throws;
the engine treats a failed sync as a no-op and retries next cycle. Malformed
batch lines are already skipped by `OpCodec.decode`.

## Auth & repo provisioning

- The PAT is stored in the **macOS Keychain** (a generic password item keyed to
  the app + repo), never in `UserDefaults` or on disk in plaintext.
- **Connect flow:**
  1. User pastes the token; app calls `GET /user` to verify it and learn the
     owner login. Invalid token → clear error, stay disconnected.
  2. App calls `GET /repos/<owner>/markdownpro-sync`. On 404 it `POST /user/repos`
     with `{ name: "markdownpro-sync", private: true, auto_init: true }`.
  3. On success the token goes to the Keychain and the transport is live.
- **Disconnect** removes the Keychain item and the persisted transport setting;
  it does not touch the repo.

## App wiring & UI

- **Settings ▸ Sync** gains a transport picker with two modes:
  - **Folder** — the existing folder picker (`Store.setSyncFolder`), unchanged.
  - **GitHub** — a token field + **Verify/Connect**, showing the connected repo
    and a **Disconnect** button once linked.
- The chosen transport (`folder | github`) and its config persist in
  `UserDefaults` (the token itself is in the Keychain). `Store` builds either a
  `FolderTransport` or a `GitHubTransport` and hands it to the unchanged
  `SyncEngine`. Triggers (launch, quit, debounced) and the main-actor
  synchronous `syncNow()` are exactly as shipped in Spec A.
- **Switching the sync target resets all cursors** — both the self publish
  cursor and every remote device cursor go to 0 — so the new target is seeded
  from the full local op log and every remote batch is re-read. This is safe
  because replay is idempotent; without it, ops already published to the old
  target would never reach the new one.

## Testing

- **Core (`GitHubTransport`):** drive it against a stubbed `URLProtocol` (no real
  network) that models the repo as an in-memory tree. Cover: publish writes a new
  batch + new blobs; a second publish increments the seq; `fetch` returns only
  batches past the cursor and excludes our own device; blob create-only
  idempotence; `fetchBlob` returns `nil` on 404; a 401/403 surfaces as a thrown
  error (no-op sync).
- **Convergence** is already covered by the transport-agnostic `SyncEngine`
  tests — they run against any `SyncTransport`, so a fake in-memory transport
  proves the engine converges regardless of GitHub specifics.
- **Manual:** connect two Macs to one private repo and re-run the `§ Sync` QA
  checklist end to end; confirm the repo shows `ops/`, `blobs/`, `devices.json`
  populating as expected.

## Risks

- **Classic-token blast radius.** A `repo`-scoped PAT can read/write every repo
  the user owns. Mitigation: it lives only in the Keychain; the connect screen
  states the scope needed and why; a future iteration could support a
  fine-grained single-repo token if repo auto-creation is dropped.
- **Rate limits.** 5,000 authenticated requests/hour. A sync is a handful of
  requests, so this is never approached in normal use; a 403 rate-limit is
  handled as a transient no-op.
- **Contents/tree size ceilings.** The API is happiest with files under ~1 MB.
  Immutable per-batch op files and small markdown blobs keep every object tiny;
  a runaway would be years away and is avoidable by batching. No LFS.
- **Cursor meaning is transport-specific.** Folder cursors (line counts) and
  GitHub cursors (batch seqs) are not interchangeable — hence the mandatory
  cursor reset on target switch.
