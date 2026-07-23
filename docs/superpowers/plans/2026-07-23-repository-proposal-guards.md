# Repository-level Proposal Guards — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Repository.applyVerdict` and `Repository.attachDocument` reject
invalid review operations (verdicts on the wrong kind/state; reviewable kinds
attached out-of-band) instead of silently corrupting document/task state.

**Architecture:** Add three `guard` clauses across two existing `Repository`
methods, all throwing the existing `RepositoryError.invalidArgument`, plus four
XCTest cases. Validation only — no schema, no migration, no new types.

**Tech Stack:** Swift, `MarkdownProCore` local package (`import SQLite3`, no
GRDB), XCTest.

## Global Constraints

- All logic lives in **Core** (`Repository`). Do not touch the MCP server or
  the app — the MCP `attach_document` kind check stays as defense-in-depth.
- The reviewable kinds are `proposal`, `spec`, `plan` — use the existing
  `DocumentKind.isReviewable` computed property; never enumerate them by hand.
- A reviewable document may receive a verdict only while its state is
  `needs_review` (`DocumentState.needsReview`) — exactly what `reviewQueue()`
  surfaces.
- Reuse `RepositoryError.invalidArgument` (already thrown at
  `Repository.swift:654`); do not add a new error case.
- `LinkedDocument.state` is `DocumentState?` (optional) — handle `nil`.
- Spec: `docs/superpowers/specs/2026-07-23-repository-proposal-guards-design.md`.

---

### Task 1: Add the guards + tests

**Files:**
- Modify: `Core/Sources/MarkdownProCore/Repository.swift`
  - `applyVerdict` (starts line 835) — insert two guards after the
    document-lookup guard (after line 838), before the task lookup.
  - `attachDocument` (starts line 575) — insert one guard as the first
    statement of the method body (before `try db.transaction {` at line 577).
- Test: `Core/Tests/MarkdownProCoreTests/ReviewTests.swift` (add four tests).

**Interfaces:**
- Consumes (all existing): `Repository.applyVerdict(_:documentId:actor:)`,
  `attachDocument(taskId:projectId:path:title:kind:)`,
  `submitForReview(taskId:path:title:kind:actor:)`, `document(id:)`,
  `getTask(id:)`, `RepositoryError.invalidArgument`,
  `DocumentKind.isReviewable`, `DocumentState.needsReview`.
- Produces: no new symbols — behavior change only (invalid operations now
  throw `RepositoryError.invalidArgument`).

- [ ] **Step 1: Write the four failing tests**

Add to `Core/Tests/MarkdownProCoreTests/ReviewTests.swift`, inside
`final class ReviewTests` (e.g. after the existing annotation tests):

```swift
    // applyVerdict refuses a non-reviewable kind (a plain note is not a proposal).
    func testApplyVerdictRejectsNonReviewableKind() throws {
        let noteId = try repo.attachDocument(taskId: taskId, projectId: nil,
                                             path: "/tmp/n.md", title: "note", kind: .note)
        XCTAssertThrowsError(try repo.applyVerdict(.approve, documentId: noteId)) { error in
            guard case RepositoryError.invalidArgument = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    // applyVerdict refuses a second verdict; the first outcome stands.
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

    // Regression: spec/plan are reviewable and must stay approvable (launch flow).
    func testApplyVerdictApprovesSpecKind() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/s.md", kind: .spec)
        try repo.applyVerdict(.approve, documentId: docId)
        XCTAssertEqual(try repo.document(id: docId)!.state, .approved)
        XCTAssertEqual(try repo.getTask(id: taskId)!.task.attention, .readyToExecute)
    }

    // attachDocument refuses reviewable kinds — they must go through submitForReview.
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

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter ReviewTests/testApplyVerdictRejectsNonReviewableKind`
Expected: FAIL — `applyVerdict` currently does not throw for a note, so the
`XCTAssertThrowsError` fails ("did not throw an error"). (The other three new
tests likewise fail: the two guard tests because no throw happens, and they
compile against existing APIs.)

- [ ] **Step 3: Add the two `applyVerdict` guards**

In `Core/Sources/MarkdownProCore/Repository.swift`, in `applyVerdict`, insert
the two guards between the existing document-lookup guard (ends line 838) and
the task-lookup guard (line 839). Result:

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
        // ... existing transaction body unchanged ...
```

Leave everything from `try db.transaction {` onward exactly as-is.

- [ ] **Step 4: Add the `attachDocument` guard**

In the same file, make the guard the first statement of `attachDocument`,
before `try db.transaction {` (currently line 577):

```swift
    public func attachDocument(taskId: Int64?, projectId: Int64?, path: String, title: String?,
                               kind: DocumentKind = .note) throws -> Int64 {
        guard !kind.isReviewable else {
            throw RepositoryError.invalidArgument(
                "kind \(kind.rawValue) must go through submitForReview, not attachDocument")
        }
        try db.transaction {
            // ... existing body unchanged ...
```

- [ ] **Step 5: Run the full ReviewTests suite to verify green**

Run: `cd Core && swift test --filter ReviewTests`
Expected: PASS — all `ReviewTests` green, including the four new tests and the
pre-existing `testAttachDocumentKind` (which attaches only `note`/`wiki`, so
the new guard does not affect it).

- [ ] **Step 6: Run the whole Core suite (guard against fallout)**

Run: `cd Core && swift test`
Expected: PASS — full suite green. In particular confirm no existing test
attached a reviewable kind via `attachDocument` or verdicted a settled/
non-reviewable doc; if one fails, it has surfaced a real prior misuse — stop
and report it rather than weakening the guard.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/MarkdownProCore/Repository.swift \
        Core/Tests/MarkdownProCoreTests/ReviewTests.swift
git commit -m "fix(core): guard applyVerdict kind/state and attachDocument reviewable kinds"
```

---

## Self-Review

**Spec coverage:**
- Section 1 (applyVerdict kind + state guards) → Step 3. ✅
- Section 2 (attachDocument reviewable-kind guard) → Step 4. ✅
- Section 3 test 1 (kind guard) → `testApplyVerdictRejectsNonReviewableKind`. ✅
- Section 3 test 2 (double verdict) → `testApplyVerdictRejectsSecondVerdict`. ✅
- Section 3 test 3 (spec regression) → `testApplyVerdictApprovesSpecKind`. ✅
- Section 3 test 4 (attach rejection) → `testAttachDocumentRejectsReviewableKind`. ✅
- Out-of-scope (no schema/MCP/UI change) → plan touches only two Core files. ✅
- Verification (`swift test`) → Steps 5-6. ✅

**Placeholder scan:** none — every code step shows complete code; commands have
expected output.

**Type consistency:** `RepositoryError.invalidArgument`, `DocumentKind.isReviewable`,
`DocumentState.needsReview`, `LinkedDocument.state` (optional), and
`TaskAttention.readyToExecute` all match their Core definitions and are used
identically across guards and tests.
