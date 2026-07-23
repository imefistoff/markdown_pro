# Cross-round Line Diff — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (or executing-plans). Steps use `- [ ]`. Tasks 1–2 are TDD Core; Tasks 3–4 are renderer/UI verified by app build + manual notes.

**Goal:** Snapshot each review round's document content, diff current vs previous
round, mark the changed blocks in the rendered review pane, and jump between
changes (⌥↑/⌥↓ + N/M counter).

**Architecture:** Core gains a `document_rounds` snapshot table (migration) +
capture in `submitForReview`, and a pure `LineDiff` engine + `roundChanges`
accessor. The renderer tags rendered blocks with their source-line span and gains
`markChanges`/`clearChanges`/`scrollToChange`. The Review Center adds a Changes
toggle + changes-nav wired through `ReviewWebView`.

**Tech Stack:** Swift, `MarkdownProCore` (SQLite, no GRDB), XCTest, marked-based
`renderer-core.js` (CSP `script-src 'self'`), SwiftUI + WKWebView.

## Global Constraints

- Diff base is the **previous round only**; granularity is **block-level**;
  snapshots are **local-only** (not written to the sync op-log).
- Migrations bump `PRAGMA user_version` (currently **4** → new step is `< 5`) and
  are idempotent (`CREATE TABLE IF NOT EXISTS`).
- Renderer changes must stay CSP-safe: no new scripts/sources, no inline JS
  (edit `renderer-core.js` / `renderer.html` only).
- Spec: `docs/superpowers/specs/2026-07-23-cross-round-diff-design.md`.

---

### Task 1: `document_rounds` snapshots (schema + capture) — Core

**Files:**
- Modify: `Core/Sources/MarkdownProCore/Database.swift` (add `if version < 5`)
- Modify: `Core/Sources/MarkdownProCore/Repository.swift` (`submitForReview`; add a
  `roundContent` accessor)
- Test: `Core/Tests/MarkdownProCoreTests/ReviewTests.swift` and
  `MigrationTests.swift`

**Interfaces produced (consumed by Task 2):**
- Table `document_rounds(document_id, round, content, created_at)` PK
  `(document_id, round)`.
- `public func roundContent(documentId: Int64, round: Int) throws -> String?`

- [ ] **Step 1: Failing tests**

In `ReviewTests.swift`:

```swift
    func testSubmitSnapshotsRoundContent() throws {
        let path = NSTemporaryDirectory() + "cr-\(UUID().uuidString).md"
        try "round one".write(toFile: path, atomically: true, encoding: .utf8)
        let docId = try repo.submitForReview(taskId: taskId, path: path)
        XCTAssertEqual(try repo.roundContent(documentId: docId, round: 1), "round one")

        try "round two changed".write(toFile: path, atomically: true, encoding: .utf8)
        _ = try repo.submitForReview(taskId: taskId, path: path)   // round 2
        XCTAssertEqual(try repo.roundContent(documentId: docId, round: 2), "round two changed")
        XCTAssertEqual(try repo.roundContent(documentId: docId, round: 1), "round one",
                       "earlier snapshot is preserved")
        XCTAssertNil(try repo.roundContent(documentId: docId, round: 3))
    }
```

In `MigrationTests.swift` (follow the file's existing old-DB pattern), assert a DB
migrated to current version has a usable `document_rounds` table (insert + select
round-trips).

- [ ] **Step 2: Run → fail** (`cd Core && swift test --filter testSubmitSnapshotsRoundContent`) — `roundContent` doesn't exist / table missing.

- [ ] **Step 3: Migration** — in `Database.swift` after the `if version < 4 {…}` block:

```swift
        if version < 5 {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS document_rounds (
                    document_id INTEGER NOT NULL,
                    round       INTEGER NOT NULL,
                    content     TEXT    NOT NULL,
                    created_at  TEXT    NOT NULL,
                    PRIMARY KEY (document_id, round)
                )
                """)
            try db.execute("PRAGMA user_version = 5")
        }
```

- [ ] **Step 4: Capture** — in `Repository.submitForReview`, inside the
transaction just before `try setAttentionColumn(taskId: taskId,
TaskAttention.needsReview.rawValue)`:

```swift
            // Snapshot this round's content for cross-round diff (local-only,
            // best-effort — not recorded in the sync op-log).
            if let snapRound = try document(id: docId)?.round,
               let content = try? String(contentsOfFile: expanded, encoding: .utf8) {
                try db.execute("""
                    INSERT INTO document_rounds (document_id, round, content, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(document_id, round) DO UPDATE SET content = excluded.content
                    """, [.integer(docId), .integer(Int64(snapRound)), .text(content), .text(now())])
            }
```

- [ ] **Step 5: Accessor** — add near `document(id:)`:

```swift
    /// The stored content snapshot for a document round, or nil if none.
    public func roundContent(documentId: Int64, round: Int) throws -> String? {
        try db.query("SELECT content FROM document_rounds WHERE document_id = ? AND round = ?",
                     [.integer(documentId), .integer(Int64(round))]).first?.string("content")
    }
```

- [ ] **Step 6: Run → pass** (`cd Core && swift test`) — full suite green.
- [ ] **Step 7: Commit** — `git commit -m "feat(core): per-round document content snapshots (#29)"`

---

### Task 2: `LineDiff` engine + `roundChanges` — Core

**Files:**
- Create: `Core/Sources/MarkdownProCore/LineDiff.swift`
- Modify: `Core/Sources/MarkdownProCore/Repository.swift` (`roundChanges`)
- Test: `Core/Tests/MarkdownProCoreTests/LineDiffTests.swift`

**Interfaces produced (consumed by Task 4):**
- `LineChange { added, modified }`, `ChangedRange { startLine, endLine, kind }`
  (1-based, inclusive over the NEW document), `LineDiff.changedRanges(old:new:) ->
  [ChangedRange]`, and `Repository.roundChanges(documentId:) throws ->
  [ChangedRange]`.

- [ ] **Step 1: Failing tests** — `LineDiffTests.swift`:

```swift
import XCTest
@testable import MarkdownProCore

final class LineDiffTests: XCTestCase {
    private func ranges(_ old: String, _ new: String) -> [ChangedRange] {
        LineDiff.changedRanges(old: old, new: new)
    }
    func testIdenticalHasNoChanges() { XCTAssertEqual(ranges("a\nb\nc", "a\nb\nc"), []) }
    func testAppendedLinesAreAdded() {
        XCTAssertEqual(ranges("a\nb", "a\nb\nc\nd"), [ChangedRange(startLine: 3, endLine: 4, kind: .added)])
    }
    func testChangedMiddleLineIsModified() {
        XCTAssertEqual(ranges("a\nb\nc", "a\nB\nc"), [ChangedRange(startLine: 2, endLine: 2, kind: .modified)])
    }
    func testInsertionInMiddleIsAdded() {
        XCTAssertEqual(ranges("a\nc", "a\nb\nc"), [ChangedRange(startLine: 2, endLine: 2, kind: .added)])
    }
    func testEmptyOldMarksAllAdded() {
        XCTAssertEqual(ranges("", "a\nb"), [ChangedRange(startLine: 1, endLine: 2, kind: .added)])
    }
}
```

- [ ] **Step 2: Run → fail** (compile error, no `LineDiff`).

- [ ] **Step 3: Implement `LineDiff.swift`** (LCS over lines; contiguous
new-only runs become ranges; a run with an adjacent deletion is `modified`, else
`added`). Starting implementation — **make the Step-1 tests pass; adjust if a case
fails**:

```swift
import Foundation

public enum LineChange: Equatable, Sendable { case added, modified }

public struct ChangedRange: Equatable, Sendable {
    public let startLine: Int   // 1-based, inclusive, in the NEW document
    public let endLine: Int
    public let kind: LineChange
    public init(startLine: Int, endLine: Int, kind: LineChange) {
        self.startLine = startLine; self.endLine = endLine; self.kind = kind
    }
}

public enum LineDiff {
    public static func changedRanges(old: String, new: String) -> [ChangedRange] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let n = a.count, m = b.count
        // LCS length table.
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i+1][j+1] + 1 : max(lcs[i+1][j], lcs[i][j+1])
                }
            }
        }
        // Walk: classify each b-line as matched or added; track deletions.
        var addedB = Array(repeating: false, count: m)
        var deleteBefore = Array(repeating: false, count: m + 1)  // a-line deleted before b-index j
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { i += 1; j += 1 }
            else if lcs[i+1][j] >= lcs[i][j+1] { deleteBefore[j] = true; i += 1 }
            else { addedB[j] = true; j += 1 }
        }
        while j < m { addedB[j] = true; j += 1 }
        while i < n { deleteBefore[m] = true; i += 1 }
        // Coalesce runs of added b-lines into ranges; modified if a deletion touches the run.
        var out: [ChangedRange] = []
        var k = 0
        while k < m {
            if !addedB[k] { k += 1; continue }
            let start = k
            while k < m && addedB[k] { k += 1 }
            let end = k - 1
            let touchedDelete = deleteBefore[start] || deleteBefore[end + 1]
            out.append(ChangedRange(startLine: start + 1, endLine: end + 1,
                                    kind: touchedDelete ? .modified : .added))
        }
        return out
    }
}
```

- [ ] **Step 4: `roundChanges`** — in `Repository.swift`:

```swift
    /// Changed line ranges for a document's current round vs the previous round,
    /// or [] when there is no previous snapshot.
    public func roundChanges(documentId: Int64) throws -> [ChangedRange] {
        guard let doc = try document(id: documentId), doc.round > 1,
              let new = try roundContent(documentId: documentId, round: doc.round),
              let old = try roundContent(documentId: documentId, round: doc.round - 1)
        else { return [] }
        return LineDiff.changedRanges(old: old, new: new)
    }
```

- [ ] **Step 5: Run → pass** (`cd Core && swift test`). If `testChangedMiddleLineIsModified` or another fails, adjust the coalescing/`touchedDelete` logic until all pass (this is the TDD gate).
- [ ] **Step 6: Commit** — `git commit -m "feat(core): line-diff engine + roundChanges accessor (#29)"`

---

### Task 3: Renderer source-line mapping + change decorations — JS

**Files:**
- Modify: `MarkdownPro/Web/renderer-core.js`
- Modify: `MarkdownPro/Web/renderer.html` (CSS for `.mdblock`, `.changed-added`,
  `.changed-modified`, `.change-gutter`)

**Interfaces produced (consumed by Task 4, called from Swift via
`evaluateJavaScript`):**
- `window.markChanges(ranges)` — `ranges = [{start,end,kind}]`; returns the count
  of marked blocks.
- `window.clearChanges()`
- `window.scrollToChange(index)`

- [ ] **Step 1: Source-line block wrapping** — in `renderMarkdown`, replace the
single `content.innerHTML = marked.parse(markdown, {gfm:true})` with a
per-top-level-token render that wraps each block:
  - `const tokens = marked.lexer(markdown, {gfm:true})`
  - for each token: `const start = line; const eline = line + (token.raw.match(/\n/g)||[]).length; html += '<div class="mdblock" data-sline="'+start+'" data-eline="'+eline+'">' + marked.parser([token], {gfm:true}) + '</div>'; line = eline + 1;` (initialize `line = 1`).
  - assign `content.innerHTML = html`. Keep the subsequent mermaid/highlight passes
    unchanged (they query inside `content`).
  - Note: `__reviewRepaint()` / annotation anchoring operate on text content and
    are unaffected by the wrapper divs.

- [ ] **Step 2: `markChanges` / `clearChanges` / `scrollToChange`** — add:
  - `clearChanges()`: remove `changed-added`/`changed-modified` classes and any
    inserted gutter nodes; reset the internal `changedBlocks` list.
  - `markChanges(ranges)`: for each `.mdblock`, if `[sline,eline]` intersects any
    range, add `changed-added` or `changed-modified` (modified wins) and push it to
    an ordered `changedBlocks` array; return `changedBlocks.length`.
  - `scrollToChange(index)`: `changedBlocks[index]?.scrollIntoView({block:'center'})`
    and pulse via a transient class.

- [ ] **Step 3: CSS** in `renderer.html`: left gutter bar + subtle background for
`.changed-added` (green) / `.changed-modified` (amber); a `.pulse` animation. No
external assets.

- [ ] **Step 4: Verify render** — `xcodebuild … build` succeeds. Manual check
deferred to Task 4 (needs the Swift wiring to call these).
- [ ] **Step 5: Commit** — `git commit -m "feat(renderer): block source-line mapping + change decorations (#29)"`

---

### Task 4: Review Center Changes toggle + nav — SwiftUI

**Files:**
- Modify: `MarkdownPro/Reader/ReviewWebView.swift` (accept + push changes)
- Modify: `MarkdownPro/Views/ReviewCenterView.swift` (toggle, nav, load
  `roundChanges`)

- [ ] **Step 1: `ReviewWebView`** — add inputs `var changes: [ChangedRange] = []`
and `var showChanges: Bool = false`. In `Coordinator.push` (after annotations),
serialize `changes` to `[{start,end,kind}]` and call
`window.markChanges(...)` when `showChanges`, else `window.clearChanges()`; guard
on a `lastChangesKey` like the annotations block so it isn't re-pushed needlessly.
Add a `scrollToChange(_ index:)` coordinator method the view can call. Expose the
marked count back to the view via a new `onChangeCount: (Int) -> Void` callback (or
reuse the return of `markChanges`).

- [ ] **Step 2: `ReviewDocumentView` state + load** — add `@State private var
roundChanges: [ChangedRange] = []`, `@State private var showChanges = false`,
`@State private var changeIndex = -1`, `@State private var changeCount = 0`. In
`load()`: `roundChanges = (try? store.repoRoundChanges(documentId:)) ?? []`
(add a thin `Store` passthrough `func roundChanges(documentId:) -> [ChangedRange]`
mirroring `annotations`). Reset `showChanges`/`changeIndex` on load.

- [ ] **Step 3: Toggle + nav in `verdictBar`** — when `currentRound >= 2 &&
!roundChanges.isEmpty`, show a `Toggle("Changes", isOn: $showChanges)` (compact)
and, when on, a `◇ ‹ i/N ›` control bound to **⌥↑ / ⌥↓** that calls
`jumpChange(±1)` (mirrors `jump` from #12 but drives `scrollToChange` via the web
coordinator; ⌥←/⌥→ stay with annotations). Counter uses `changeCount`.

- [ ] **Step 4: Wire `ReviewWebView`** in the doc pane: pass `changes:
roundChanges, showChanges: showChanges`, and `onChangeCount: { changeCount = $0 }`.
`jumpChange` advances `changeIndex` (wrapping over `changeCount`) and asks the
coordinator to `scrollToChange(changeIndex)`.

- [ ] **Step 5: Build + manual** — `xcodebuild … build` succeeds. Manual: submit a
proposal, resubmit an edited copy, open in Review Center → "Changes" toggle
enabled; on → edited blocks highlighted, ⌥↑/⌥↓ walk them with the N/M counter; a
round-1 proposal → toggle hidden/disabled.
- [ ] **Step 6: Commit** — `git commit -m "feat(review): cross-round changes toggle + jump nav (#29)"`

---

## Self-Review

- Spec §1 (snapshots) → Task 1. §2 (diff engine + accessor) → Task 2. §3
  (renderer mapping + JS API) → Task 3. §4 (toggle + nav + webview wiring) →
  Task 4. §5 (tests) → Tasks 1–2 tests. ✅
- Decisions honored: block-level (Task 3 wrapping), prev-round-only
  (`roundChanges`), local-only (no `recordInsert` on the snapshot), ⌥↑/⌥↓ distinct
  from #12's ⌥←/⌥→. ✅
- Placeholder scan: LCS code is complete and TDD-gated; JS steps name exact
  functions and behaviors. ✅
- Type consistency: `ChangedRange(startLine,endLine,kind)` / `LineChange` used
  identically across Tasks 2 and 4; `roundContent`/`roundChanges` signatures match
  between Tasks 1, 2, 4. ✅
