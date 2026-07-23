# Task-detail Header Action Row — Design

**Date:** 2026-07-23
**Status:** Approved for planning
**Scope:** Fix the `TaskDetailView` header overflow when a task is
`ready_to_execute` with a launchable spec/plan. Board task: **#25** (project
*Markdown Pro*, labels `bug`, `design`). SwiftUI-only; no Core, MCP, schema, or
data change.

## Problem

`TaskDetailView`'s header crams six controls into one `HStack`
(`TaskDetailView.swift:68-97`): `Status` picker, `Priority` picker, the
due-date control, an optional `AttentionChip`, an optional `Clear` button (only
when `attention == .executing`), and `LaunchButton`. In a narrow detail pane
with a `ready_to_execute` + launchable task, they compete for horizontal space:

- `AttentionChip` (`Helpers.swift:107`) is a `SwiftUI.Label` with no line
  limit, so under compression it wraps to **one character per line** — the
  "Ready to execute" chip becomes a vertical strip.
- `LaunchButton` truncates to `▶ …`.

## Decisions (agreed in brainstorming)

1. **Two composing fixes:** a universal never-wrap safeguard on `AttentionChip`,
   plus a structural split so the controls stop sharing one row.
2. **Two rows, not a flow layout or overflow menu.** Simplest, most legible,
   matches the app's existing sectioned header, lowest risk. macOS 14 has no
   built-in wrap layout, and an overflow menu hides discoverable actions.
3. **Row 2 is conditional on `attention != nil`.** Launch requires
   `readyToExecute` (which implies attention is set), so this single condition
   covers every case where row 2 has content; when attention is nil the row is
   omitted entirely (no empty gap).
4. **Verification is visual (screenshot), not an XCUITest.** SwiftUI layout is
   a poor unit-test fit; an XCUITest for this is high-maintenance for low
   signal.

## Section 1 — `AttentionChip` never-wrap safeguard (`Helpers.swift`)

Add two modifiers to the chip's `body` so it always renders at intrinsic width:

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

`.lineLimit(1)` + `.fixedSize(horizontal: true, vertical: false)` guarantees the
capsule can never collapse into a vertical strip, independent of the container.
Apply `.lineLimit`/`.fixedSize` to the `Label` (before the padding/background)
so the capsule hugs the single-line text. This fix stands on its own even apart
from Section 2.

## Section 2 — Split the header into two rows (`TaskDetailView.swift`)

Replace the single header `HStack` (`TaskDetailView.swift:68-97`) with two.

**Row 1 — metadata** (existing controls, unchanged bindings):

```swift
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
```

**Row 2 — actions** (rendered only when the task has an attention flag):

```swift
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

**Visibility matrix:**

| Task state | Row 2 |
|---|---|
| no attention | omitted (only the metadata row shows) |
| attention set, not launchable | chip (+ `Clear` if `.executing`) |
| `readyToExecute` + launchable | chip on the left, `Launch` right-aligned |

`LaunchButton` keeps its own self-hiding logic
(`task.attention == .readyToExecute && task.launchKind != nil`,
`LaunchViews.swift:14`) untouched — it simply renders nothing when its
conditions aren't met, so placing it unconditionally at the end of row 2 is
correct.

## Out of scope / guardrails

- No change to `LaunchButton` or `AttentionChip` behavior/API beyond Section 1's
  never-wrap modifier.
- `Status` / `Priority` / due-date controls and their bindings unchanged.
- The Labels row, Description section, and everything below the header
  (`TaskDetailView.swift:99+`) untouched.
- No Core, MCP, schema, or persistence change.

## Verification (visual)

Build and launch the app (per `CLAUDE.md`: `xcodebuild` or XcodeBuildMCP, then
`open` the built app; `screencapture -x` for shots). Exercise three states,
narrowing the detail pane to reproduce the original overflow:

1. **`ready_to_execute` + launchable spec/plan** — confirm the "Ready to
   execute" chip stays a single-line capsule and `Launch` shows its full label
   (no `▶ …`), on their own row below the pickers.
2. **Attention set but not launchable** (e.g. `needs_review`) — row 2 shows the
   chip alone; no truncation.
3. **No attention** — only the metadata row renders; no empty second row.

Confirm row 1's Status/Priority/Due controls are visually intact in all three.
Run `cd Core && swift test` as a regression sanity check (no Core change is
expected, so it must stay green).
