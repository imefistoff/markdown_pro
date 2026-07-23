# Cancel a Task Mid-Execution — Design + Plan

**Date:** 2026-07-23 · **Task #26** · Status: auto-approved (delegated batch)
**Scope:** Recover a task stuck in `executing` when its Claude session dies.
App-side only; reuses the existing `Repository.setAttention`.

## Behavior (decided with Maxim)

- A "Cancel execution" action clears the `executing` flag and sets the task back
  to **`ready_to_execute`**, so the Launch button reappears and it can be
  relaunched manually. Works regardless of whether the original session is alive
  (it's a plain DB write).

## Changes

- **`Store.cancelExecution(taskId:)`** — `setAttention(.readyToExecute,
  actor: "user")` via the existing `perform` helper (`Store.swift`).
- **Task detail** (`TaskDetailView`): the executing-only button changed from
  "Clear" (which set attention to *nil*, hiding Launch) to **"Cancel execution"**
  → `ready_to_execute`.
- **Board card** (`TaskCardView`): a right-click **"Cancel execution"** context
  menu item, shown only for `executing` cards, for recovery without opening the
  task.

## Why ready_to_execute (not nil / canceled)

The acceptance asks for a *runnable* state. `ready_to_execute` restores the
Launch button immediately; `LaunchButton` self-hides if the approved doc is gone,
so it's safe even in odd states. No status change (task keeps its column).

## Verification

`xcodebuild … build` → BUILD SUCCEEDED. `cd Core && swift test` → unchanged
(`setAttention` already covered by `testSetAttention`). Manual (later): launch a
task (→ executing), kill the session, then "Cancel execution" from the card menu
or detail view → task shows `ready_to_execute` with Launch available again.
