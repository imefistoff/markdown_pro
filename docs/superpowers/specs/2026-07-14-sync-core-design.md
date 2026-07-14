# Sync Core — Design (Spec A)

**Date:** 2026-07-14
**Status:** Approved
**Follow-on:** Spec B — GitHub transport (OAuth device flow, private repo, REST push/pull, sync UI)

## Goal

Let one project live on two Macs and stay in step: work laptop during the day,
personal laptop in the evening. Changes made on either machine — by the user in
the app, or by Claude through the MCP server — converge on both.

This spec covers the **sync core**: cross-machine identity, an append-only
operation log, deterministic replay, per-project opt-in, and document content
moving between machines. The transport is a **plain folder on disk**.

Networked transport (GitHub) is Spec B. The core is unchanged by it.

## Why not iCloud

CloudKit and iCloud Drive are scoped to the Apple ID signed into macOS. The two
laptops are signed into *different* Apple IDs (work and personal), and there is
no API to choose an Apple ID inside an app — `CKContainer` follows the system
account. So iCloud cannot bridge these two machines, at any price.

`NSPersistentCloudKitContainer` (SwiftData / Core Data mirroring) is also ruled
out for a second, independent reason: it owns its SQLite file, and the MCP
server writes to that same file from another process. That is unsupported and
would corrupt mirroring state. Raw SQLite shared by two processes remains the
right call.

The sync identity must therefore be **ours**, not the machine's. A folder (Spec
A) or a GitHub token (Spec B) is independent of which Apple ID is logged in.

## Scope

**In:**

- Stable cross-machine UUIDs for every syncable entity (schema v3).
- An append-only op log, written inside the same transaction as each mutation.
- Hybrid-logical-clock ordering; last-write-wins **per field**.
- Deterministic, idempotent replay.
- Per-project opt-in; **explicit adopt** on the receiving machine.
- Document content sync (content-addressed blobs); `path` is device-local.
- One transport: a folder on disk.

**Out (Spec B or later):**

- GitHub / any network transport, OAuth, Keychain.
- Live push while both machines are open. Sync is on launch, on quit, and on a
  debounced timer.
- Sharing with another *person*. This is one user, two machines.
- Merge UI / conflict prompts. Conflicts resolve automatically (see below).

## Data model — schema v3

Every syncable entity gains `uuid TEXT NOT NULL UNIQUE`, backfilled for existing
rows during migration and generated on insert thereafter:

`projects`, `tasks`, `subtasks`, `labels`, `documents`, `annotations`,
`activity`.

Local integer ids are untouched. All existing queries, foreign keys and
`ON DELETE CASCADE` rules keep working. The UUID is purely the entity's
cross-machine name.

### New tables

```sql
CREATE TABLE ops (
    id           INTEGER PRIMARY KEY,
    entity       TEXT NOT NULL,      -- 'project' | 'task' | 'subtask' | 'label'
                                     -- | 'document' | 'annotation' | 'activity'
                                     -- | 'task_label'
    entity_uuid  TEXT NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN ('insert','update','delete')),
    field        TEXT,               -- NULL for insert/delete
    value        TEXT,               -- NULL when clearing a field
    parent_uuid  TEXT,               -- owning entity (task for a subtask, …);
                                     -- set on insert so replay can place the row
    device_id    TEXT NOT NULL,
    hlc          TEXT NOT NULL,      -- sortable: "<millis>.<counter>.<device_id>"
    created_at   TEXT NOT NULL
);
CREATE INDEX idx_ops_device ON ops(device_id, id);
CREATE INDEX idx_ops_entity ON ops(entity_uuid);

CREATE TABLE field_stamps (
    entity_uuid  TEXT NOT NULL,
    field        TEXT NOT NULL,
    hlc          TEXT NOT NULL,
    PRIMARY KEY (entity_uuid, field)
);

CREATE TABLE tombstones (
    entity_uuid  TEXT PRIMARY KEY,
    entity       TEXT NOT NULL,
    hlc          TEXT NOT NULL
);

CREATE TABLE sync_devices (
    device_id    TEXT PRIMARY KEY,
    name         TEXT NOT NULL,      -- "Work MacBook"
    is_self      INTEGER NOT NULL DEFAULT 0,
    cursor       INTEGER NOT NULL DEFAULT 0   -- ops applied from this device
);

CREATE TABLE sync_blobs (
    hash         TEXT PRIMARY KEY,   -- SHA-256 of the file bytes
    size         INTEGER NOT NULL,
    created_at   TEXT NOT NULL
);
```

### Altered columns

```sql
ALTER TABLE projects  ADD COLUMN synced INTEGER NOT NULL DEFAULT 0;
ALTER TABLE documents ADD COLUMN content_hash TEXT;   -- SHA-256, NULL if unreadable
```

`documents.path` is **not synced**. It is a device-local answer to "where is this
file on *this* Mac". `content_hash` is what travels.

`projects.synced = 0` means the project emits no ops at all. Work projects are
invisible to sync; nothing about them can reach the transport.

## The op log

One op = one field change (or one insert / delete).

- **insert** — `kind='insert'`, `parent_uuid` set, no `field`. Creates the row
  with defaults; the field values follow as `update` ops in the same batch.
- **update** — `field` + `value`. `value = NULL` clears the field.
- **delete** — tombstones the entity.

`value` is a string; numbers, booleans and dates use the existing `DateCoding`
and raw-enum conventions, so the log is readable and matches what is stored.

Ops are appended **inside the same `db.transaction` as the mutation**. If the
write rolls back, so does the op. There is no window in which the database and
the log disagree.

Because both the app and the MCP server go through `Repository`, Claude's writes
are logged with no MCP-side changes.

### Containment check

Before recording, `Repository` resolves the entity to its project (subtask → task
→ project; annotation → document → task → project; and so on). If that project
has `synced = 0`, no op is written.

## Ordering — hybrid logical clock

Each device keeps an HLC. On every local op:

```
now = max(wallClockMillis, lastMillis)
counter = (now == lastMillis) ? counter + 1 : 0
```

On receiving remote ops, the device advances its clock past the highest stamp it
has seen. That guarantees causality: an edit you make *after* syncing in a remote
change always sorts after it, even if this machine's clock is behind.

Stamps sort lexicographically as `<zero-padded millis>.<counter>.<device_id>`;
the device id makes ordering total, so both machines reach the same answer.

Plain wall-clock time was rejected: a drifting clock would make one machine's
writes systematically win or lose, producing silent, unreproducible data loss.

## Replay

Merge incoming ops with local ones and apply in HLC order.

- An **update** is applied only if its HLC is newer than `field_stamps` for that
  (entity, field). Otherwise it is dropped. This is what makes last-write-wins
  per field true, and what lets replay be incremental rather than re-deriving
  history from the beginning.
- An **insert** for a UUID that already exists is a no-op.
- A **delete** writes a tombstone. **Deletes are final:** any op referencing a
  tombstoned UUID is ignored, even a newer one. Letting a late edit resurrect a
  deleted task is worse than losing that edit. This applies only to entities with
  *generated* UUIDs — never to label links, whose ids are derived (see below).
- Ops for an entity whose project is not adopted on this machine are ignored.

Replay is idempotent: `sync_devices.cursor` records how far into each remote
device's log we have read, and `field_stamps` rejects anything already applied.
Syncing twice changes nothing.

**Labels merge by name.** `labels.name` is globally `UNIQUE`, so two machines
that each create "feature" must converge on one row. The label op carries the
name; replay reuses an existing label of that name and keeps that label's
existing colour. This mirrors the rule `Repository.addLabel` and the import path
already use.

**Label links.** `task_labels` is a join table with no id of its own, so it has
no UUID to carry. A link uses the deterministic composite
`entity_uuid = "<task_uuid>:<label_name>"`, and is modelled as a single
last-write-wins field: an `update` on `attached`, with value `"1"` or `"0"`.

It is deliberately **not** an insert/delete pair. A link's id is derived rather
than generated, so a `delete` would tombstone it permanently — and because
deletes are final, detaching a label from a task would make it impossible to ever
re-attach that label to that task. Modelling presence as an LWW boolean makes
attach → detach → attach converge correctly, which is ordinary behaviour a user
expects to just work.

## Documents

The transport holds a content-addressed blob area keyed by SHA-256.

**Publishing:** for each document in a synced project, hash the file. If the hash
is new, upload the bytes. The op log carries the document's identity, metadata
(`title`, `kind`, `state`, `round`) and `content_hash` — never the bytes.

**Receiving:** resolve a local path for the document, in this order:

1. If a local file is already associated with this document UUID and still
   exists, keep it. On the machine where the doc was attached, that is the real
   file in your repo — so Claude rewriting a spec still shows live in the app,
   and the Review Center keeps working exactly as it does today.
2. Otherwise write the blob to
   `~/Library/Application Support/MarkdownPro/Synced/<project>/<file>.md`
   and point the document there.

**Local edits propagate:** on each sync, re-hash every synced document. A changed
hash emits an `update` op on `content_hash` and uploads the new blob. So editing
the managed copy at home, or letting Claude rewrite the original at work, both
flow to the other machine.

If two machines edit the same file between syncs, last-write-wins on
`content_hash` — the losing version is still in the blob store, and still in git
history once Spec B lands, so nothing is unrecoverable.

## Opt-in and adoption

**Publishing** is per project: a "Sync this project" toggle. Only synced projects
emit ops.

**Adoption is explicit.** A project appearing in the transport does *not*
materialise on the other machine by itself. The receiving Mac lists it under
"Available to adopt", and the user chooses. Nothing lands on the work laptop
without a deliberate action — which is the point, on a machine you do not own.

Once adopted, the project syncs in both directions and its ops apply normally.

## Transport

```swift
public protocol SyncTransport {
    /// Remote device logs (excluding our own) and the blobs we ask for.
    func fetch(since cursors: [String: Int]) throws -> RemoteChanges
    func publish(ops: [Op], blobs: [Blob]) throws
    func fetchBlob(hash: String) throws -> Data
}
```

Spec A ships one implementation, `FolderTransport`, over a directory:

```
<folder>/
  ops/<device-id>.jsonl      # append-only; exactly one writer per file
  blobs/<sha256>             # content-addressed document bytes
  devices.json               # device id → display name
```

**One writer per file** is the property that makes this safe under naive file
sync and, later, under git: two machines never edit the same file, so there is
nothing to conflict. Each machine appends only to its own log and reads the
others'.

Pointing `FolderTransport` at a Dropbox or Syncthing directory already yields
working two-machine sync. Spec B replaces the folder with GitHub; nothing above
the protocol changes.

## Sync triggers

On app launch, on quit, and on a debounced timer (a few seconds after changes
settle). The app already polls `PRAGMA data_version` to notice MCP writes, so
Claude's changes are picked up and published on the same cycle.

The MCP server itself does not sync — it only writes ops. They publish next time
the app runs. (A future daemon could change this; not now.)

## Errors

- Transport unreachable → sync is a no-op; ops accumulate locally and go out on
  the next successful sync. Nothing blocks the UI.
- Malformed remote op (unknown entity, bad HLC) → skipped and logged, never
  fatal. One bad line must not poison the log.
- Missing blob for a `content_hash` → the document row still appears, with no
  local file, and resolves on a later sync when the blob arrives.
- All sync work happens off the main thread; failures surface through the
  existing `errorMessage` alert.

## Testing

`Core` tests, against scratch databases (`MARKDOWNPRO_DB`) and a temp folder:

- **Convergence** — two repositories over one folder; mutate on A, sync both,
  assert B matches; mutate on B, sync, assert A matches.
- **Field-level merge** — change `priority` on A and `title` on B without
  syncing between; after sync **both** survive. This is the case row-level
  snapshots would have lost, and is the reason for the design.
- **Idempotence** — syncing twice applies nothing the second time.
- **HLC causality** — with A's clock set behind B's, an edit A makes *after*
  seeing B's change still wins.
- **Deletes are final** — delete on A, edit the same task on B, sync: the task
  stays deleted.
- **Containment** — an unsynced project emits zero ops; nothing about it appears
  in the folder. Asserted by reading the folder, not just the tables.
- **Labels** — both machines create "feature"; one label row survives, keeping
  the existing colour.
- **Label links re-attach** — attach a label, detach it, attach it again, syncing
  each time: it ends up attached. (A tombstone-based link would leave it
  permanently detached; this test exists to prevent that regression.)
- **Documents** — relink when the original path exists; restore a managed copy
  when it does not; a local edit re-hashes and propagates.
- **Adoption** — an unadopted project's ops are ignored; adopting materialises
  it with tasks and documents.

Then a manual pass with two scratch databases and one folder, driving the real
app.

## Risks

- **Every write path must record.** Missing one produces a silent sync gap.
  Mitigation: recording lives in `Repository` (the single funnel both processes
  use), and a test asserts each of the 21 mutating methods emits at least one op
  for a synced project.
- **Log growth.** Ops are small, but unbounded. Compaction (snapshot current
  state, discard superseded ops) is deliberately deferred — with a personal
  board it is years away. Revisit if a log passes a few megabytes.
- **Schema v3 must be idempotent and ordered**, like v1 and v2, because both
  processes migrate on open.
