# Repository-level Proposal Guards — Design

**Date:** 2026-07-23
**Status:** Approved for planning
**Scope:** Close two Core-level integrity gaps in the review layer so invalid
review operations fail loudly instead of silently corrupting document/task
state. Board task: **#21** (project *Markdown Pro*, labels `core`,
`review-center`). No schema change, no migration, no MCP-layer change, no UI
change.

## Problem

Two `Repository` methods trust input that the review workflow's invariants say
they should reject:

1. **`applyVerdict` trusts its document** (`Repository.swift:835`). It looks up
   the document and its task, then writes state + attention for whichever
   verdict was passed — with no check on the document's `kind` or current
   `state`. Consequences:
   - A verdict on a non-reviewable document (`note`, `wiki`) silently stamps a
     `DocumentState` onto a row whose kind has no review lifecycle, and flips
     the task's `attention`.
   - A *second* verdict on an already-settled document (approved / rejected /
     superseded / changes_requested) silently overwrites the prior outcome. On
     `.reject` it also moves the task back to `todo` (`Repository.swift:857`),
     so a stray double-verdict can regress task status.
   - The app never does either — `reviewQueue()` only surfaces
     `kind IN ('proposal','spec','plan') AND state = 'needs_review'`
     (`Repository.swift:890`) — but nothing at the data layer enforces it, so
     any other caller (future code, a bug, a direct MCP call) can.

2. **`attachDocument` accepts reviewable kinds** (`Repository.swift:575`). Its
   INSERT has no `state` column (`Repository.swift:581-586`), so a document
   attached with `kind` `proposal` / `spec` / `plan` lands with **`state =
   NULL`**. Such a row is invisible to `reviewQueue` (which requires
   `state = 'needs_review'`) and can never be reviewed or launched — a
   permanently orphaned "proposal". The MCP `attach_document` handler already
   rejects reviewable kinds (`MCPServer.swift:217`), but Core does not, so the
   invariant holds only for that one caller.

The shared rule both gaps violate: **a reviewable document (`proposal` /
`spec` / `plan`) may only enter the system through `submitForReview` — which
stamps `state = 'needs_review'` — and may only receive a verdict while it is
in `needs_review`.**

## Decisions (agreed in brainstorming)

1. **`applyVerdict` kind guard = `isReviewable`, not `== .proposal`.** The
   task's original note predates the `spec` / `plan` kinds. Both are reviewable
   (`DocumentKind.isReviewable`, `Models.swift`) and go through the same
   verdict path — approving a `spec` or `plan` is the launch-button flow. A
   `== .proposal` guard would break it. The guard is `doc.kind.isReviewable`.
2. **`applyVerdict` state guard = `needs_review` only.** This is exactly the
   set `reviewQueue` surfaces, so it matches what the app ever calls
   `applyVerdict` on. It rejects double-verdicts, verdicts on settled or
   `changes_requested` documents (which leave the queue until a resubmit sets
   `needs_review` again), and NULL-state rows.
3. **`attachDocument` rejects reviewable kinds at the Core level.** Move the
   invariant into Core so it binds every caller; the MCP handler's existing
   check stays as harmless defense-in-depth (not removed).
4. **Reuse `RepositoryError.invalidArgument`** for all three guards — the same
   error `submitForReview` already throws for a non-reviewable kind
   (`Repository.swift:654`). No new error case.

## Section 1 — `applyVerdict` guards (`Repository.swift`)

Insert two guards immediately after the existing document-lookup guard
(`Repository.swift:836-838`), before the task lookup and the transaction. They
depend only on `doc`:

```swift
public func applyVerdict(_ verdict: ReviewVerdict, documentId: Int64, actor: String = "user") throws {
    guard let doc = try document(id: documentId) else {
        throw RepositoryError.notFound("document \(documentId)")
    }
    guard doc.kind.isReviewable else {
        throw RepositoryError.invalidArgument(
            "cannot apply a verdict to a \(doc.kind.rawValue) document")
    }
    guard doc.state == .needsReview else {
        throw RepositoryError.invalidArgument(
            "cannot apply a verdict; document state is \(doc.state?.rawValue ?? "none")")
    }
    guard let taskId = doc.taskId, let task = try getTask(id: taskId)?.task else {
        throw RepositoryError.notFound("task for document \(documentId)")
    }
    // ... unchanged transaction body ...
}
```

Nothing inside the transaction changes. `doc.state` is `DocumentState?`
(`LinkedDocument.state`), hence the `?? "none"` in the message.

## Section 2 — `attachDocument` guard (`Repository.swift`)

Add a guard at the top of `attachDocument` (before the transaction, so it
throws without side effects):

```swift
public func attachDocument(taskId: Int64?, projectId: Int64?, path: String, title: String?,
                           kind: DocumentKind = .note) throws -> Int64 {
    guard !kind.isReviewable else {
        throw RepositoryError.invalidArgument(
            "kind \(kind.rawValue) must go through submitForReview, not attachDocument")
    }
    try db.transaction {
        // ... unchanged body ...
    }
}
```

The default `kind: .note` is unaffected; existing `note` / `wiki` callers keep
working.

## Section 3 — Tests (`Core/Tests/MarkdownProCoreTests/ReviewTests.swift`)

Add four assertions covering both guards and the regression. The class's
`setUpWithError` already provides `repo`, `projectId`, `taskId`.

1. **`applyVerdict` kind guard** — attach a `note` to the task, verdict it,
   expect `invalidArgument`:
   ```swift
   func testApplyVerdictRejectsNonReviewableKind() throws {
       let noteId = try repo.attachDocument(taskId: taskId, projectId: nil,
                                            path: "/tmp/n.md", title: "note", kind: .note)
       XCTAssertThrowsError(try repo.applyVerdict(.approve, documentId: noteId)) { error in
           guard case RepositoryError.invalidArgument = error else {
               return XCTFail("expected invalidArgument, got \(error)")
           }
       }
   }
   ```

2. **`applyVerdict` state guard (double verdict)** — submit, approve, approve
   again; the second call throws and the first outcome stands:
   ```swift
   func testApplyVerdictRejectsSecondVerdict() throws {
       let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
       try repo.applyVerdict(.approve, documentId: docId)
       XCTAssertThrowsError(try repo.applyVerdict(.reject, documentId: docId)) { error in
           guard case RepositoryError.invalidArgument = error else {
               return XCTFail("expected invalidArgument, got \(error)")
           }
       }
       XCTAssertEqual(try repo.document(id: docId)!.state, .approved)
       XCTAssertEqual(try repo.getTask(id: taskId)!.task.attention, .readyToExecute)
   }
   ```

3. **Regression: spec still approvable** — proves the `isReviewable` widening
   keeps the launch flow working:
   ```swift
   func testApplyVerdictApprovesSpecKind() throws {
       let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/s.md", kind: .spec)
       try repo.applyVerdict(.approve, documentId: docId)
       XCTAssertEqual(try repo.document(id: docId)!.state, .approved)
       XCTAssertEqual(try repo.getTask(id: taskId)!.task.attention, .readyToExecute)
   }
   ```

4. **`attachDocument` kind guard** — the missing Core test named in the task;
   proposals must not be attachable:
   ```swift
   func testAttachDocumentRejectsReviewableKind() throws {
       XCTAssertThrowsError(
           try repo.attachDocument(taskId: taskId, projectId: nil,
                                   path: "/tmp/p.md", title: "p", kind: .proposal)
       ) { error in
           guard case RepositoryError.invalidArgument = error else {
               return XCTFail("expected invalidArgument, got \(error)")
           }
       }
   }
   ```

## Out of scope

- No schema change and no migration — the fix is validation only.
- No change to the MCP layer; `attach_document`'s existing kind check
  (`MCPServer.swift:217`) stays as defense-in-depth.
- No UI change — the app already only verdicts `needs_review` reviewable docs.
- `updateAnnotation` / `deleteAnnotation` silent no-op behavior (a separate
  concern tracked under task #23) is not touched here.

## Verification

- `cd Core && swift test` — the four new tests plus the existing suite green.
- No app or MCP rebuild required for correctness, but `cd mcp-server && swift
  build -c release` should still succeed (Core is a shared dependency).
