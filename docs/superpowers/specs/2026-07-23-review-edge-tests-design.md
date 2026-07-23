# Review-layer Edge-case Tests + Annotation Guards — Design + Plan

**Date:** 2026-07-23 · **Task #23** · Status: auto-approved (delegated batch)
**Scope:** Close three untested edge cases in the review data layer; one is a
small behavior change (agreed with Maxim). Core + tests only.

## Changes

1. **`updateAnnotation` / `deleteAnnotation` throw on an unknown id** (was: silent
   no-op) — now consistent with `resolveAnnotation`. Each guards existence at the
   top of its transaction and throws `RepositoryError.notFound`
   (`Repository.swift`). Tests: `testUpdateAnnotationThrowsForUnknownId`,
   `testDeleteAnnotationThrowsForUnknownId`.

2. **Reject verdict when the task is already `todo`** — the branch that skips the
   redundant status-move was untested. Test
   `testRejectVerdictLeavesAlreadyTodoTaskUnchanged`: doc → rejected, attention
   cleared, task stays `todo`, and **no** "moved…" status activity is emitted.

3. **`reviewQueue()` multi-item ordering** — newest-first via
   `COALESCE(updated_at, created_at) DESC, id DESC`. Test
   `testReviewQueueOrdersNewestFirst`: the more recently submitted proposal sorts
   ahead of the older one.

## Verification

`cd Core && swift test` → **166 tests, 0 failures** (162 prior + 4 new). No app
or MCP change: `updateAnnotation`/`deleteAnnotation` are called from the review
UI with valid ids in normal use, so the new guard only fires on genuine misuse.
