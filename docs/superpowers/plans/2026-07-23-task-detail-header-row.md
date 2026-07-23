# Task-detail Header Action Row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the `TaskDetailView` header overflow so a `ready_to_execute` + launchable task shows an intact "Ready to execute" chip and a full `Launch` button instead of a one-character-per-line strip and a `▶ …` truncation.

**Architecture:** Two composing SwiftUI-only fixes: (1) a universal never-wrap safeguard on `AttentionChip` so the capsule always renders at intrinsic single-line width; (2) split the single overloaded header `HStack` into a metadata row (Status / Priority / Due) plus a conditional action row (chip + optional Clear + right-aligned Launch) rendered only when the task has an attention flag.

**Tech Stack:** SwiftUI (macOS 14+), Xcode 16 synchronized-folder project. No external Swift dependencies.

## Context

Board task **#25** (project *Markdown Pro*, id 3; labels `bug`, `design`). The approved design spec is `docs/superpowers/specs/2026-07-23-task-detail-header-row-design.md` (linked doc id 13, state `approved`).

`TaskDetailView`'s header currently crams six controls into one `HStack` (`MarkdownPro/Views/TaskDetailView.swift:67-97`): Status picker, Priority picker, due-date control, optional `AttentionChip`, optional `Clear` button (only when `attention == .executing`), and `LaunchButton`. In a narrow detail pane with a `ready_to_execute` + launchable task these compete for horizontal space: `AttentionChip` (`MarkdownPro/Helpers.swift:106-120`) has no line limit, so under compression its `SwiftUI.Label` wraps to one character per line and the chip becomes a vertical strip; `LaunchButton` truncates to `▶ …`. Intended outcome: chip stays a single-line capsule, Launch shows its full label, both on a dedicated row below the pickers.

## Global Constraints

- **Platform:** macOS 14+, SwiftUI only.
- **No Core / MCP / schema / persistence change.** Edits are confined to the app target's SwiftUI layer.
- **No external Swift dependencies** (project-wide rule).
- **No API/behavior change** to `LaunchButton` or `AttentionChip` beyond Task 1's never-wrap modifiers. `Status` / `Priority` / due-date controls and their bindings unchanged. Everything below the header (Labels row, Description, `TaskDetailView.swift:99+`) untouched.
- **Verification is visual** (build + screenshot), not XCUITest — SwiftUI layout is a poor unit-test fit (spec §Decisions/4). `cd Core && swift test` is a regression sanity check only; no Core change is expected, so it must stay green.

---

## File Structure

- `MarkdownPro/Helpers.swift` — `AttentionChip` view (Task 1). Also holds `TaskAttention.iconName` / `.color` (unchanged).
- `MarkdownPro/Views/TaskDetailView.swift` — header layout (Task 2). The two HStacks are siblings inside the existing enclosing `VStack(alignment: .leading)` that also holds the Labels row and Description below.
- Unchanged but consumed: `MarkdownPro/Views/LaunchViews.swift` (`LaunchButton`, self-hides unless `attention == .readyToExecute && launchKind != nil`); `Core/Sources/MarkdownProCore/Models.swift` (`TaskStatus.boardColumns`, `TaskPriority.allCases`, `TaskAttention`, `TaskItem.attention` / `.launchKind`).

---

### Task 1: `AttentionChip` never-wrap safeguard

Self-contained: the chip can never collapse into a vertical strip again, independent of its container. Stands on its own even without Task 2.

**Files:**
- Modify: `MarkdownPro/Helpers.swift:112-119` (the `AttentionChip.body`)

**Interfaces:**
- Consumes: nothing new.
- Produces: no API change — `AttentionChip(text:icon:color:)` init and behavior are identical; only intrinsic sizing is constrained.

- [ ] **Step 1: Add `.lineLimit(1)` and `.fixedSize` to the chip's `Label`**

Apply both modifiers to the `SwiftUI.Label` *before* the padding/background so the capsule hugs the single-line text. Replace the current `body`:

```swift
    var body: some View {
        SwiftUI.Label(text, systemImage: icon)
            .font(.caption2)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
```

`.lineLimit(1)` + `.fixedSize(horizontal: true, vertical: false)` guarantees the capsule renders at intrinsic single-line width and never wraps under compression.

- [ ] **Step 2: Build the app to verify it compiles**

Run:
```bash
xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add MarkdownPro/Helpers.swift
git commit -m "fix(ui): AttentionChip never wraps — lineLimit(1) + fixedSize"
```

---

### Task 2: Split the header into a metadata row and a conditional action row

**Files:**
- Modify: `MarkdownPro/Views/TaskDetailView.swift:67-97` (the single `// Status / priority / due date` HStack)

**Interfaces:**
- Consumes: existing `statusBinding(_:)`, `priorityBinding(_:)`, `dueDateControl(_:)`, `reload()`, `store` (`@EnvironmentObject`), `taskId` (`let`), and the shadowed non-optional `detail` parameter of `content(_:)` — all unchanged.
- Produces: no new symbols; purely a layout restructure.

- [ ] **Step 1: Replace the single header HStack with two sibling HStacks**

Replace lines 67-97 (the block starting `// Status / priority / due date` through its closing `}`) with the following two sibling views. They remain direct children of the existing enclosing `VStack(alignment: .leading)`, so the action row stacks below the metadata row; keep the same surrounding indentation and leave the code above line 67 and below line 97 untouched.

```swift
                    // Metadata: status / priority / due date
                    HStack(spacing: 16) {
                        Picker("Status", selection: statusBinding(detail)) {
                            ForEach(TaskStatus.boardColumns) { s in
                                SwiftUI.Label(s.displayName, systemImage: s.iconName).tag(s)
                            }
                        }
                        .fixedSize()
                        Picker("Priority", selection: priorityBinding(detail)) {
                            ForEach(TaskPriority.allCases) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .fixedSize()
                        dueDateControl(detail)
                        Spacer()
                    }

                    // Actions: attention chip + optional Clear + right-aligned Launch
                    if let attention = detail.task.attention {
                        HStack(spacing: 12) {
                            AttentionChip(text: attention.displayName,
                                          icon: attention.iconName,
                                          color: attention.color)
                            if attention == .executing {
                                Button("Clear") {
                                    store.clearAttention(taskId: taskId)
                                    reload()
                                }
                                .controlSize(.small)
                                .help("Clear the Executing flag if the session was stopped")
                            }
                            Spacer()
                            LaunchButton(task: detail.task)
                        }
                    }
```

Notes for the implementer:
- The metadata row keeps its trailing `Spacer()` so pickers stay left-aligned.
- The action row is gated on `attention != nil`: Launch requires `readyToExecute` (which implies attention is set), so this single condition covers every case with row-2 content; when attention is nil the row is omitted entirely (no empty gap).
- `LaunchButton` keeps its own self-hiding logic (`attention == .readyToExecute && launchKind != nil`, `LaunchViews.swift:14`) — it renders nothing when its conditions aren't met, so placing it unconditionally at the end of the action row is correct.
- Do not alter the enclosing `VStack`'s alignment or spacing; the two HStacks inherit it.

**Visibility matrix (expected result):**

| Task state | Action row |
|---|---|
| no attention | omitted (only the metadata row shows) |
| attention set, not launchable (e.g. `needs_review`) | chip alone (+ `Clear` if `.executing`) |
| `readyToExecute` + launchable | chip on the left, `Launch` right-aligned |

- [ ] **Step 2: Build the app to verify it compiles**

Run:
```bash
xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add MarkdownPro/Views/TaskDetailView.swift
git commit -m "fix(ui): split TaskDetailView header into metadata + action rows (#25)"
```

---

## Verification (visual)

Per `CLAUDE.md`: build, launch the built app, and use `screencapture -x shot.png` for shots. Narrow the detail pane to reproduce the original overflow, and exercise three states:

1. **`ready_to_execute` + launchable spec/plan** — confirm the "Ready to execute" chip stays a single-line capsule and `Launch` shows its full label (no `▶ …`), on their own row below the pickers.
2. **Attention set but not launchable** (e.g. `needs_review`) — action row shows the chip alone; no truncation.
3. **No attention** — only the metadata row renders; no empty second row.

In all three, confirm row 1's Status / Priority / Due controls are visually intact.

Launch the built app:
```bash
open ~/Library/Developer/Xcode/DerivedData/MarkdownPro-*/Build/Products/Debug/MarkdownPro.app
```

Regression sanity check (no Core change expected — must stay green):
```bash
cd Core && swift test
```

---

## Self-Review

- **Spec coverage:** §1 never-wrap → Task 1; §2 two-row split → Task 2; visibility matrix → Task 2 table; visual verification + `swift test` → Verification section. Out-of-scope guardrails → Global Constraints. All spec sections mapped.
- **Placeholders:** none — every code step shows the full replacement code and exact build/commit commands.
- **Type consistency:** `AttentionChip(text:icon:color:)`, `statusBinding`/`priorityBinding`/`dueDateControl`/`reload`, `store.clearAttention(taskId:)`, `TaskStatus.boardColumns`, `TaskPriority.allCases`, `TaskAttention.displayName`/`.iconName`/`.color`, `LaunchButton(task:)` all match the verified current code.
