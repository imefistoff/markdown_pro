# Cross-round Line Diff in the Review Center — Design

**Date:** 2026-07-23
**Status:** Draft — awaiting Maxim's review
**Task:** #29 · **Supersedes the deferred half of** #12 (which shipped as
annotation-jump only, because the app stores no per-round document content).

## Goal

When a proposal is reviewed over 2+ rounds, let the reviewer **see what actually
changed** since the previous round and **jump between the changes** (‹/› + an
"N of M" counter), directly in the Review Center's rendered document — not just
between annotations.

## The blocker this removes

Today the review file at `document.path` is **overwritten** each round; only the
latest content exists. Annotations carry a `round`, but document *content* has no
history, so there's nothing to diff. This design adds per-round content snapshots
and a diff pipeline on top of them.

## Decisions (flagged for review — change any before I plan)

1. **Granularity = block-level, marked in the rendered view.** The review pane
   shows *rendered* markdown, not source. Exact per-character line marking would
   require source→DOM mapping the renderer doesn't do. Instead we diff the
   **source** at line level, then mark the **rendered block** (paragraph, list
   item, heading, code block, table…) that contains any changed line. The task
   itself listed "line-level vs. block/section-level" as open — this picks
   block-level as the pragmatic, accurate-enough unit. *(Alternative if you'd
   rather: a separate source-level unified-diff view. Say the word and I'll
   re-spec around that instead.)*
2. **Diff base = the immediately previous round (N-1),** not cumulative across
   all rounds. "What changed since I last looked" is the review need.
3. **Snapshots are local-only (not synced) in v1.** Review happens on one
   machine; syncing full per-round content would bloat the op-log. Cross-device
   diff is a later enhancement (the sync layer's content-addressed blobs could
   carry it). Consequence: a doc whose rounds happened on another device shows
   no diff there.
4. **Removed-only regions** (lines deleted with nothing added) are shown as a
   thin "content removed" marker between the surrounding blocks — not navigable
   as a full change in v1 (they have no rendered block to anchor). Added and
   modified blocks are the navigable set.
5. **Pre-existing proposals** (submitted before this feature) have no prior
   snapshot; the Changes toggle is simply disabled with a tooltip.

## Section 1 — Per-round snapshots (Core)

### Schema (`Database.swift`, next `user_version` migration)

```sql
CREATE TABLE IF NOT EXISTS document_rounds (
    document_id INTEGER NOT NULL,
    round       INTEGER NOT NULL,
    content     TEXT    NOT NULL,
    created_at  TEXT    NOT NULL,
    PRIMARY KEY (document_id, round)
);
```

Bump `user_version`; migration is idempotent (`CREATE TABLE IF NOT EXISTS`), so
both processes migrate cleanly (per the project's migration rules).

### Capture (`Repository.submitForReview`)

`submitForReview` already resolves the document row and its (new or bumped)
round. After that, read the file at the expanded `path` and upsert the snapshot:

```swift
if let content = try? String(contentsOfFile: expanded, encoding: .utf8) {
    try db.execute("""
        INSERT INTO document_rounds (document_id, round, content, created_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(document_id, round) DO UPDATE SET content = excluded.content
        """, [.integer(docId), .integer(Int64(round)), .text(content), .text(now())])
}
```

Snapshotting failure (unreadable file) is non-fatal — it just means no diff for
that round. Not recorded in the sync op-log (local-only, per decision 3).

## Section 2 — Line diff engine (Core)

New pure type `LineDiff` (`Core/Sources/MarkdownProCore/LineDiff.swift`):

```swift
public enum LineChange: Equatable, Sendable { case added, modified }

/// A run of consecutive changed lines in the NEW document (1-based, inclusive).
public struct ChangedRange: Equatable, Sendable {
    public let startLine: Int
    public let endLine: Int
    public let kind: LineChange
}

public enum LineDiff {
    /// Changed line ranges in `new` relative to `old`, via LCS. Pure/testable.
    public static func changedRanges(old: String, new: String) -> [ChangedRange]
}
```

- Standard LCS over the two line arrays; runs of new-side lines with no LCS match
  are `added`; a delete immediately adjacent to an add coalesces into `modified`.
- Deletions with no adjacent add are reported separately as removed-anchor points
  (a companion `removedAfterLine: [Int]` on the return, used for decision 4's
  markers) — kept minimal.

### Repository accessor

```swift
/// Changed ranges for a document's current round vs its previous round,
/// or [] when there is no previous snapshot.
public func roundChanges(documentId: Int64) throws -> [ChangedRange]
```

Loads snapshot(round) and snapshot(round-1) from `document_rounds` and returns
`LineDiff.changedRanges(old:new:)`.

## Section 3 — Renderer: block source-line mapping (`renderer-core.js`)

`renderMarkdown` currently does `content.innerHTML = marked.parse(md)`. Add
source-line tagging so changed source lines map to rendered blocks:

- Lex first (`marked.lexer(md)`), then render **per top-level token**, wrapping
  each in a block element carrying its source span:
  `<div class="mdblock" data-sline="S" data-eline="E">…</div>`, computing S/E by
  accumulating newline counts of each `token.raw`. (Keeps the existing single
  `innerHTML` assignment; just builds the string per block.)
- New JS API on `window`:
  - `markChanges(ranges)` — `ranges` = `[{start,end,kind}]`; add class
    `changed-added` / `changed-modified` to every `.mdblock` whose `[sline,eline]`
    intersects a range, plus a left gutter bar; insert a thin `removed` marker at
    the given removed-anchor lines. Returns the ordered list of marked block ids
    so Swift can drive nav.
  - `clearChanges()` — remove all change decorations.
  - `scrollToChange(index)` — scroll the index-th marked block into view and pulse
    it.
- Styling in `renderer.html`'s stylesheet (CSP-safe, already `script-src 'self'`).
  No new network/sources — nothing here touches the CSP.

## Section 4 — Review UI (`ReviewCenterView.swift`, `ReviewWebView.swift`)

- **Toggle:** in the verdict bar, a `Changes since round N-1` toggle, shown only
  when `currentRound >= 2 && !roundChanges.isEmpty`. Off by default.
- **When on:** call `markChanges(roundChanges)` on the web view; the annotation
  highlights stay, changes get their own gutter/coloring. A compact
  `◇ ‹ 2/7 ›` changes-nav appears (mirrors #12's control but drives
  `scrollToChange`, not annotations). ⌥↑/⌥↓ bound to prev/next change (⌥←/⌥→ stay
  with annotation-jump from #12, so the two navs don't collide).
- **When off:** `clearChanges()`; nav hidden.
- `ReviewWebView` gains a `changes: [ChangedRange]` + `showChanges: Bool` input
  and a coordinator method to push `markChanges`/`clearChanges`, following the
  existing `push` pattern (render → annotations → changes, in that order so
  changes decorate the current DOM).
- `roundChanges` loaded in `load()` alongside annotations; recomputed on round
  bump.

## Section 5 — Tests

- **Core `LineDiffTests`:** added-only, removed-only, modified block,
  move/reorder, identical inputs (→ []), leading/trailing edits, empty old (round
  1 semantics → treat all as added or return [] when no prior — assert chosen
  behavior).
- **`ReviewTests` snapshot capture:** submit round 1 → `document_rounds` has
  (doc,1,content); resubmit with changed file → (doc,2,newContent);
  `roundChanges` returns the expected ranges; a doc with only round 1 →
  `roundChanges == []`.
- **`MigrationTests`:** an old DB (pre-feature `user_version`) migrates and gains
  `document_rounds`; idempotent on re-open.

## Section 6 — Out of scope (v1)

- Cross-device diff (snapshots local-only).
- Cumulative multi-round diff (base is N-1 only).
- Word/character-level intra-line highlighting (block-level only).
- Editing/reverting changes from the review view (read-only marking).

## Verification

- `cd Core && swift test` — diff + snapshot + migration tests green.
- App build succeeds; manual: submit a proposal, resubmit an edited version, open
  it in the Review Center → toggle Changes → edited blocks are marked, ⌥↑/⌥↓ walk
  them with an N/M counter; a first-round proposal shows the toggle disabled.
