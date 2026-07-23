# Spec Launches Open a Worktree — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development. This is a single, self-contained task — implement it directly, TDD.

**Goal:** Make a **spec** launch open a git worktree when the project has
`use_worktree` enabled, so the single spec→plan→implement flow runs isolated
instead of in the main checkout.

**Why:** `claude -w <slug>` works (it creates `<repo>/.claude/worktrees/<slug>`),
but `LaunchScriptBuilder` only passes `-w` for **plan** launches. The real
workflow is one spec launch that writes the plan and continues into
implementation — so with the current rule it never isolates, and two Claude
sessions can end up sharing one working tree. Fix: also request a worktree for
spec launches (they still run in plan permission-mode).

**Scope:** one line in `LaunchScriptBuilder.swift` + one test update. No schema,
no UI, no other behavior change.

## Global Constraints

- Spec launches must **still force plan permission-mode** (`--permission-mode
  plan`) and stay `isUnsafe == false` — only the worktree flag changes.
- Plan launches keep their existing behavior (already worktree-on-when-enabled).
- When `use_worktree` is **off**, neither spec nor plan launches get `-w`.

---

### Task 1: Spec launches honor `use_worktree`

**Files:**
- Modify: `Core/Sources/MarkdownProCore/LaunchScriptBuilder.swift` (line 79)
- Test: `Core/Tests/MarkdownProCoreTests/LaunchTests.swift`
  (replace `testSpecNeverGetsWorktreeAndForcesPlanMode`, lines 84-91)

- [ ] **Step 1: Update the test to the new contract**

Replace the whole `testSpecNeverGetsWorktreeAndForcesPlanMode` function
(`LaunchTests.swift:84-91`) with:

```swift
    func testSpecHonorsWorktreeButForcesPlanMode() throws {
        // Spec launches now isolate in a worktree when enabled, but always run
        // in plan permission-mode (never unsafe).
        let on = try LaunchScriptBuilder.script(
            task: task(), document: doc(.spec), settings: settings(preset: .bypassPermissions, worktree: true))
        XCTAssertTrue(on.command.contains("-w "), "spec launch should open a worktree when enabled")
        XCTAssertNotNil(on.worktreeSlug)
        XCTAssertTrue(on.command.contains("--permission-mode plan"))
        XCTAssertFalse(on.isUnsafe, "planning is always plan-mode, never unsafe")

        let off = try LaunchScriptBuilder.script(
            task: task(), document: doc(.spec), settings: settings(preset: .bypassPermissions, worktree: false))
        XCTAssertFalse(off.command.contains("-w "), "no worktree when disabled")
        XCTAssertNil(off.worktreeSlug)
        XCTAssertTrue(off.command.contains("--permission-mode plan"))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Core && swift test --filter LaunchTests/testSpecHonorsWorktreeButForcesPlanMode`
Expected: FAIL — with the current code a spec launch omits `-w`, so the first
`XCTAssertTrue(on.command.contains("-w "))` fails.

- [ ] **Step 3: Make the one-line change**

In `Core/Sources/MarkdownProCore/LaunchScriptBuilder.swift`, line 79:

```swift
        // before
        let usesWorktree = (document.kind == .plan) && settings.useWorktree
        // after
        let usesWorktree = settings.useWorktree
```

Update the adjacent comment (lines 77-78) to reflect the new behavior, e.g.:
`// Both spec and plan launches isolate in a worktree when enabled; spec still
// forces plan-mode below.`

Leave everything else untouched — `effectivePreset` (line 80) already forces
`.plan` mode for specs, `commandSlug` (line 81) already gates on `usesWorktree`,
and `isUnsafe` (line 96) already stays false for specs.

- [ ] **Step 4: Run the launch tests**

Run: `cd Core && swift test --filter LaunchTests`
Expected: PASS — the updated spec test and the unchanged
`testPlanHonorsWorktreeAndPreset` both green.

- [ ] **Step 5: Run the whole Core suite**

Run: `cd Core && swift test`
Expected: PASS — full suite green (no other test relied on spec-launches
omitting `-w`).

- [ ] **Step 6: Build the app**

Run: `xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/MarkdownProCore/LaunchScriptBuilder.swift \
        Core/Tests/MarkdownProCoreTests/LaunchTests.swift
git commit -m "fix(launch): spec launches also open a worktree when enabled"
```

## How to confirm it worked (manual, after merge + relaunch)

1. Rebuild and relaunch MarkdownPro.app.
2. On a task with an approved **spec** and `use_worktree` on, click **Launch**.
3. In the repo, run `git worktree list` — a new
   `<repo>/.claude/worktrees/task-<id>-<slug>` should appear, and the launched
   session's work should land on branch `worktree-task-<id>-<slug>`, not in the
   main checkout.
