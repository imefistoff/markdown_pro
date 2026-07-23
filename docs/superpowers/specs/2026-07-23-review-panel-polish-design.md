# Review Panel Polish — Design + Plan

**Date:** 2026-07-23 · **Task #22** · Status: auto-approved (delegated batch)
**Scope:** Three cosmetic follow-ups in the Review Center. UI/JS only; no Core,
schema, or data change.

## Fixes

1. **Live reload when an annotation is resolved without a resubmit.**
   `ReviewCenterView` only reloaded annotations on `item.document.round` change.
   When Claude resolves an annotation without resubmitting, the round is
   unchanged, so the panel kept showing it. **Fix:** reload annotations whenever
   the poll refreshes the queue — `.onReceive(store.$reviewQueue) { _ in
   reloadAnnotations() }` (`ReviewCenterView.swift`).

2. **Transient "Unanchored" flash on re-render.** `Coordinator.push` set
   annotations against the *old* DOM before `renderMarkdown` replaced it, so new
   annotations briefly failed to anchor. **Fix:** render first, then set
   annotations, so they anchor against the current DOM (`renderMarkdown`'s
   trailing `__reviewRepaint()` still covers the no-render case)
   (`ReviewWebView.swift`).

3. **Only one toast when several proposals land in one poll.** `Store.refresh()`
   toasted just the first fresh proposal. **Fix:** count fresh proposals — one →
   "Proposal ready: <title>"; more than one → "N proposals ready"
   (`Store.swift`).

## Verification

- `xcodebuild … build` → BUILD SUCCEEDED.
- `cd Core && swift test` → unchanged (no Core touched).
- Manual (later): resolve an annotation via MCP with the doc open (panel drops
  it); resubmit a round (no anchor flash); land two proposals in one poll (one
  "2 proposals ready" toast).
