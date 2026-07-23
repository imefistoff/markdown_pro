# Round-scope the `open_annotations` Count — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the MCP `open_annotations` scalar report only the current round's
open review comments, matching the app's actionable set, so stale prior-round
opens no longer inflate the count forever.

**Architecture:** Add one round-scoped counting query to `Repository` (Core),
unit-test it there, then call it from both MCP sites (`get_review_feedback`,
`get_task`) in place of the inline all-rounds filter. Plus a one-line tool
description clarification. No schema change, no migration, no UI change.

**Tech Stack:** Swift, `MarkdownProCore` local package (`import SQLite3`, no
GRDB), XCTest, hand-rolled MCP stdio JSON-RPC executable.

## Global Constraints

- Queries and schema logic live in **Core** (`Repository`), once — the app and
  MCP server share it. Do not add a parallel query path.
- macOS 14+; no external Swift dependencies anywhere.
- `Annotation.round` is stamped at creation from `document.round` and is never
  mutated; `round` is monotonic, so no annotation can have `round >
  document.round`.
- Missing-entity lookups throw `RepositoryError.notFound(...)`, matching
  `addAnnotation` / `resolveAnnotation` / `applyVerdict`.
- Dates are TEXT via `DateCoding`; do not introduce new date formats.
- Spec: `docs/superpowers/specs/2026-07-23-round-scope-open-annotations-count-design.md`.

---

### Task 1: Core helper `Repository.openAnnotationCount(documentId:)` + tests

**Files:**
- Modify: `Core/Sources/MarkdownProCore/Repository.swift` (add method after
  `annotations(documentId:)`, currently ending at line 788)
- Test: `Core/Tests/MarkdownProCoreTests/ReviewTests.swift` (add two tests)

**Interfaces:**
- Consumes: existing `Repository.document(id:) -> Document?`,
  `submitForReview(taskId:path:title:)`, `addAnnotation(documentId:...)`,
  `resolveAnnotation(id:reply:)`, `annotations(documentId:)`,
  `RepositoryError.notFound`.
- Produces: `public func openAnnotationCount(documentId: Int64) throws -> Int`
  — count of annotations where `round == document.round && state == .open`;
  throws `RepositoryError.notFound` if the document does not exist. Consumed by
  Task 2.

- [ ] **Step 1: Write the failing tests**

Add to `Core/Tests/MarkdownProCoreTests/ReviewTests.swift` (inside
`final class ReviewTests`, e.g. after `testAnnotationLifecycle`):

```swift
    // open_annotations is round-scoped: only OPEN comments stamped with the
    // document's CURRENT round count. Prior-round opens left behind on
    // resubmit are history, not actionable work.
    func testOpenAnnotationCountIsRoundScoped() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")

        // Round 1: two comments; resolve one, leave the other open.
        let a = try repo.addAnnotation(documentId: docId, quote: "A",
                                       comment: "fix A")
        _ = try repo.addAnnotation(documentId: docId, quote: "B", comment: "fix B")
        try repo.resolveAnnotation(id: a, reply: "done")

        // Resubmit WITHOUT resolving B -> document bumps to round 2, B stays
        // an open round-1 annotation.
        _ = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
        XCTAssertEqual(try repo.document(id: docId)!.round, 2)

        // A fresh open comment on round 2.
        _ = try repo.addAnnotation(documentId: docId, quote: "C", comment: "fix C")

        // Round-scoped: only C is actionable now.
        XCTAssertEqual(try repo.openAnnotationCount(documentId: docId), 1)
        // Sanity: the naive all-rounds filter would over-count (B + C).
        XCTAssertEqual(
            try repo.annotations(documentId: docId).filter { $0.state == .open }.count,
            2)

        // Resolving the current-round comment drains the count to zero;
        // the stale round-1 open still does not resurface it.
        try repo.resolveAnnotation(
            id: try repo.annotations(documentId: docId).first { $0.quote == "C" }!.id,
            reply: "done")
        XCTAssertEqual(try repo.openAnnotationCount(documentId: docId), 0)
    }

    // Missing document id throws, like its sibling lookups.
    func testOpenAnnotationCountThrowsForUnknownDocument() throws {
        XCTAssertThrowsError(try repo.openAnnotationCount(documentId: 999_999)) { error in
            guard case RepositoryError.notFound = error else {
                return XCTFail("expected RepositoryError.notFound, got \(error)")
            }
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter ReviewTests/testOpenAnnotationCountIsRoundScoped`
Expected: FAIL — compile error, `value of type 'Repository' has no member
'openAnnotationCount'`.

- [ ] **Step 3: Implement the helper**

In `Core/Sources/MarkdownProCore/Repository.swift`, add immediately after the
`annotations(documentId:)` method (after line 788):

```swift
    /// Count of annotations that are actionable *right now*: open comments
    /// stamped with the document's current round. Mirrors the Review Center's
    /// `currentComments` (`ReviewCenterView.swift`) so the MCP's
    /// `open_annotations` scalar and the app's actionable set never disagree.
    /// Prior-round opens — left behind when a proposal is resubmitted without
    /// resolving every comment — are excluded: they are history, not work.
    public func openAnnotationCount(documentId: Int64) throws -> Int {
        guard let doc = try document(id: documentId) else {
            throw RepositoryError.notFound("document \(documentId)")
        }
        return try annotations(documentId: documentId)
            .filter { $0.round == doc.round && $0.state == .open }
            .count
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter ReviewTests`
Expected: PASS — all `ReviewTests` green, including the two new tests.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/MarkdownProCore/Repository.swift \
        Core/Tests/MarkdownProCoreTests/ReviewTests.swift
git commit -m "feat(core): round-scoped openAnnotationCount for review feedback"
```

---

### Task 2: Wire both MCP sites + clarify the tool description

**Files:**
- Modify: `mcp-server/Sources/markdownpro-mcp/MCPServer.swift`
  (`get_task` ~line 141-142, `get_review_feedback` ~line 262)
- Modify: `mcp-server/Sources/markdownpro-mcp/ToolCatalog.swift`
  (`get_review_feedback` description, ~line 158-161)

**Interfaces:**
- Consumes: `Repository.openAnnotationCount(documentId:)` from Task 1.
- Produces: no new symbols; behavior change only.

- [ ] **Step 1: Replace the `get_task` inline filter**

In `MCPServer.swift`, in the `get_task` case, change the per-document mapping.
Current (lines 140-143):

```swift
                if doc.kind.isReviewable {
                    d["open_annotations"] = try repo.annotations(documentId: doc.id)
                        .filter { $0.state == .open }.count
                }
```

Replace with:

```swift
                if doc.kind.isReviewable {
                    d["open_annotations"] = try repo.openAnnotationCount(documentId: doc.id)
                }
```

- [ ] **Step 2: Replace the `get_review_feedback` inline filter**

In `MCPServer.swift`, in the `get_review_feedback` case. Current (line 262):

```swift
            dict["open_annotations"] = annotations.filter { $0.state == .open }.count
```

Replace with:

```swift
            dict["open_annotations"] = try repo.openAnnotationCount(documentId: docId)
```

Leave the surrounding lines untouched — the full `annotations` array is still
returned via `dict["annotations"] = annotations.map(Encode.annotation)` (line
261), so no feedback is hidden.

- [ ] **Step 3: Clarify the tool description**

In `ToolCatalog.swift`, in the `get_review_feedback` tool description (the
string block around lines 158-161), append a sentence explaining the scalar.
Current (lines 158-161):

```swift
        tool("get_review_feedback",
             "Fetch the user's review verdict and inline annotations on a submitted document. "
             + "Returns the document state plus every annotation — "
             + "each has the quoted text plus surrounding context and the user's comment.",
```

Replace the description string with:

```swift
        tool("get_review_feedback",
             "Fetch the user's review verdict and inline annotations on a submitted document. "
             + "Returns the document state plus every annotation — "
             + "each has the quoted text plus surrounding context and the user's comment. "
             + "`open_annotations` counts only the open comments in the current round "
             + "(what you still need to address before resubmitting); the full `annotations` "
             + "array spans all rounds, each tagged with its `round`.",
```

Keep the rest of the `tool(...)` call (parameters/schema) unchanged.

- [ ] **Step 4: Build the MCP server**

Run: `cd mcp-server && swift build -c release`
Expected: build succeeds, binary at `.build/release/markdownpro-mcp`.

- [ ] **Step 5: Drive it against a scratch DB to confirm round-scoping**

Use a throwaway DB so the real board is untouched (`MARKDOWNPRO_DB`). This
reproduces the stale-open scenario end-to-end over stdio JSON-RPC.

```bash
cd mcp-server
export MARKDOWNPRO_DB="$(mktemp -t mdpro-manual).sqlite"
BIN=.build/release/markdownpro-mcp

# Create a project + task, submit a proposal, annotate it, resubmit without
# resolving, annotate again, then read feedback. Each line is one JSON-RPC call.
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_project","arguments":{"name":"Scratch"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_task","arguments":{"project_id":1,"title":"T"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"submit_for_review","arguments":{"task_id":1,"path":"'"$MARKDOWNPRO_DB"'"}}}' \
  | "$BIN"
echo "--- inspect: expect open_annotations reflects only current-round opens ---"
```

Expected: the `submit_for_review` result reports `"round": 1`. (Annotations are
authored by the user in the app, so a full stdio repro of B-stays-open is
covered by the Task 1 unit test; this manual step confirms the rebuilt binary
starts, speaks JSON-RPC, and the `open_annotations` key is present and an
integer on `get_review_feedback` / `get_task` output.) Then clean up:

```bash
rm -f "$MARKDOWNPRO_DB" "$MARKDOWNPRO_DB"-wal "$MARKDOWNPRO_DB"-shm
unset MARKDOWNPRO_DB
```

> Authoritative correctness is the Task 1 unit test; Task 2 is wiring, verified
> by a green build and a smoke-drive of the binary.

- [ ] **Step 6: Commit**

```bash
git add mcp-server/Sources/markdownpro-mcp/MCPServer.swift \
        mcp-server/Sources/markdownpro-mcp/ToolCatalog.swift
git commit -m "fix(mcp): round-scope open_annotations in get_task and get_review_feedback"
```

---

## Self-Review

**Spec coverage:**
- Decision 1 (filter the count, not description-only) → Task 2 Steps 1-2. ✅
- Decision 2 (query in Core, once) → Task 1 Step 3. ✅
- Decision 3 (no auto-supersede/migration) → nothing mutates annotations; helper
  is read-only. ✅
- Section 1 (Core helper, notFound behavior) → Task 1 Step 3 + Step 1 tests. ✅
- Section 2 (both MCP sites, full annotation list preserved) → Task 2 Steps 1-2. ✅
- Section 3 (tool description clarification) → Task 2 Step 3. ✅
- Section 4 (stale-open test + boundary cases) → Task 1 Step 1 (round-scoped,
  all-resolved→0, notFound). ✅
- Verification section (`swift test`, rebuild + drive binary) → Task 1 Step 4,
  Task 2 Steps 4-5. ✅

**Placeholder scan:** none — every code step shows complete code; commands have
expected output.

**Type consistency:** `openAnnotationCount(documentId: Int64) throws -> Int`
used identically in Task 1 (definition) and Task 2 (both call sites).
`RepositoryError.notFound`, `AnnotationState.open`, `Document.round`, and
`Annotation.round`/`.state` match their Core definitions.
