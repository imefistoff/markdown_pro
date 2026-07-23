# Review Annotation-Jump Navigation — Design + Plan

**Date:** 2026-07-23 · **Task #12** · Status: auto-approved (delegated batch)
**Scope:** Keyboard/button navigation to cycle through a proposal's annotations.
Rescoped (agreed with Maxim) from cross-round content-diffing — which the app
can't do because it doesn't snapshot per-round document content — to jumping
between the annotations that ARE stored (`annotation.round`). UI only.

## Behavior

- In the Review Center's verdict bar: **‹ / ›** buttons + an **i/N** counter,
  bound to **⌥← / ⌥→**, cycle an "active" annotation across all rounds
  (current-round comments first, then earlier). Each step scrolls the comments
  panel to that annotation and outlines its row.

## Design (`ReviewDocumentView` in `ReviewCenterView.swift`)

- `navAnnotations = currentComments + pastComments` — visual (top-to-bottom)
  order of every annotation shown in the panel.
- `jump(±1)` advances `navIndex` (wrapping) and sets `scrollTarget`, reusing the
  existing `ScrollViewReader` that already scrolls the panel on annotation click.
- Past-round rows gained `.id(a.id)` so they're scroll-targetable; both current
  and past rows get an `activeBorder` overlay when active.
- `navIndex` resets on `load()` (doc switch / round bump) but **not** on the
  1.5 s poll reload, so a poll can't reset the user's position; `jump` and
  `activeBorder` are index-safe if the list shrinks.

## Why ⌥+arrows (not bare arrows)

Bare arrow keys would hijack normal scrolling in the document/panel. ⌥←/⌥→ give
the requested arrow-key feel without stealing plain-arrow behavior; the buttons
are the discoverable primary.

## Non-goals

- No line-level diff of document text between rounds (needs per-round content
  snapshots the app doesn't store — a separate, larger feature).

## Verification

`xcodebuild … build` → BUILD SUCCEEDED. `cd Core && swift test` → unchanged.
Manual (later): open a multi-annotation proposal → ⌥→/⌥← walk the annotations,
counter updates, panel scrolls, active row outlined.
