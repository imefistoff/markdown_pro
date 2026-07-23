# Round-scope the `open_annotations` Count — Design

**Date:** 2026-07-23
**Status:** Approved for planning
**Scope:** Correctness fix to the MCP review-feedback surface so its
`open_annotations` scalar matches the app's round-scoped actionable set.
Board task: **#20** (project *Markdown Pro*, labels `mcp`, `review-center`).
No schema change, no data migration, no UI change.

## Problem

The MCP server surfaces `open_annotations` as a scalar "work remaining"
signal on two tools:

- `get_review_feedback` (`MCPServer.swift:262`)
- `get_task`, per linked reviewable document (`MCPServer.swift:142`)

Both compute it as *every* open annotation on the document, regardless of
round:

```swift
annotations.filter { $0.state == .open }.count
```

But the app's actionable set is round-scoped. `ReviewCenterView.swift:95-96`
defines the current round's comments as:

```swift
annotations.filter { $0.round == currentRound && $0.state == .open }
```

and buckets everything else (`round < currentRound || state == .addressed`)
into read-only *prior comments*.

**The mismatch.** An `Annotation.round` is stamped at creation from the
document's current round (`addAnnotation` uses `doc.round`); `round` only ever
increases, and neither `resolveAnnotation` nor `applyVerdict` mutates it. So
when Claude resubmits a proposal — bumping the document to round N+1 — while a
round-N comment is still `open`, that stale open annotation:

- drops out of the UI's actionable set (becomes a "prior comment"), but
- stays in the MCP's `open_annotations` count **forever**.

Claude, reading the count, perpetually believes there is unaddressed feedback
that the user no longer considers actionable. The spec's stated contract is
that *"open annotations from the latest verdict are the actionable set."*

## Decision (agreed in brainstorming)

1. **Filter the count — do not merely reword the tool description.** The
   scalar must *mean* what the UI means. A description that tells Claude to
   self-filter by the per-annotation `round` field leaves a misleading number
   in place and offloads correctness onto the reader. Rejected as the primary
   fix; a small wording clarification ships *alongside* the real fix.
2. **The query lives in Core, once.** Per project convention ("schema or query
   changes happen in Core, once"), add a `Repository` helper rather than
   duplicating the round filter at each MCP call site. This makes the logic
   unit-testable at the Core layer.
3. **Do not auto-supersede older open annotations (YAGNI).** Annotations are
   immutable round history; the UI already presents prior-round opens as
   "prior comments". Mutating them to `addressed` on resubmit would require a
   migration and would erase the addressed-vs-never-addressed distinction.
   Scoping the count achieves correctness without touching stored data.

## Section 1 — Core helper (`Repository`)

Add one method beside the existing `annotations(documentId:)`
(`Repository.swift:777`):

```swift
/// Count of annotations that are actionable *right now*: open comments
/// stamped with the document's current round. Mirrors the Review Center's
/// `currentComments` so the MCP's `open_annotations` scalar and the app's
/// actionable set never disagree. Prior-round opens (left behind when a
/// proposal is resubmitted without resolving every comment) are excluded —
/// they are history, not work.
public func openAnnotationCount(documentId: Int64) throws -> Int
```

Behavior:

- Load the document; if it does not exist, throw `RepositoryError.notFound`
  (consistent with `resolveAnnotation` / `applyVerdict`).
- Return the count of annotations where `round == document.round &&
  state == .open`.

Implementation may reuse `annotations(documentId:)` and filter in Swift, or
issue a scoped `SELECT COUNT(*) … WHERE document_id = ? AND round = ? AND
state = 'open'`. Either is acceptable; prefer the `COUNT(*)` query for clarity
and to avoid materializing rows. Because `round` is monotonic and annotations
are only ever created at `doc.round`, no annotation can have `round >
document.round`, so equality with the document's round is exactly the
current-actionable set.

## Section 2 — MCP call sites (`MCPServer.swift`)

Replace the inline filter at both sites with the helper:

- **`get_review_feedback`** (~`:262`): keep returning the full `annotations`
  array (each element already carries its `round` via `Encode.annotation`), so
  no feedback is hidden. Only the summary scalar changes:
  ```swift
  dict["open_annotations"] = try repo.openAnnotationCount(documentId: docId)
  ```
- **`get_task`** (~`:142`), inside the per-document map for reviewable docs:
  ```swift
  d["open_annotations"] = try repo.openAnnotationCount(documentId: doc.id)
  ```

No change to `Encode.annotation`, the returned annotation list, or any other
field.

## Section 3 — Tool description clarification (`ToolCatalog.swift`)

Complementary, low-effort. Where `get_review_feedback` is described (~`:158`),
clarify the meaning of the scalar so Claude reads it correctly:

> `open_annotations`: number of open comments **in the current round** — the
> comments you still need to address before resubmitting. The full
> `annotations` array includes every comment across all rounds, each tagged
> with its `round`.

This is documentation only; the numeric guarantee comes from Section 1–2.

## Section 4 — Test (`Core/Tests/MarkdownProCoreTests/ReviewTests.swift`)

Add a stale-open-annotation test that would fail against the old all-rounds
filter and passes against the round-scoped helper:

1. Create a task; `submitForReview` → document at round 1.
2. `addAnnotation` twice on round 1 (call them A and B).
3. `resolveAnnotation` on A (→ `addressed`); B stays `open`.
4. `submitForReview` the same task+path again → document bumps to round 2; B
   remains an `open` round-1 annotation.
5. `addAnnotation` once more → a new `open` annotation C stamped round 2.
6. **Assert** `openAnnotationCount(documentId:) == 1` (only C), while the raw
   `annotations(documentId:).filter { $0.state == .open }.count` would be 2
   (B and C) — pin both to make the round-scoping explicit.

Add the boundary cases in the same test file:

- All current-round comments resolved → count `0`.
- `openAnnotationCount` on a non-existent document id → throws
  `RepositoryError.notFound`.

## Out of scope

- Auto-superseding or migrating prior-round open annotations (rejected above).
- Any UI change — `ReviewCenterView` already round-scopes correctly.
- The other review-layer follow-ups tracked separately (tasks #21, #22, #23).

## Verification

- `cd Core && swift test` — new + existing `ReviewTests` green.
- `cd mcp-server && swift build -c release`, then drive the rebuilt binary:
  submit a proposal, annotate it, resubmit without resolving, and confirm
  `get_review_feedback` / `get_task` report the current-round open count, not
  the cumulative one (newline-delimited JSON-RPC over stdio, per
  `CLAUDE.md`).
