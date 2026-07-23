# Task Description Image Attachments (v1) — Design + Plan

**Date:** 2026-07-23 · **Task #13** · Status: auto-approved (delegated batch)
**Scope:** Minimal, file-based image paste for task descriptions. App-side only —
no DB/schema change, **not synced** across devices (agreed scope).

## Behavior

- Paste an image (⌘V) into the Description editor → the image is saved and an
  `[image N]` token is appended to the description text; a thumbnail strip below
  the editor lists the task's images; clicking a thumbnail opens a full-size
  preview sheet.

## Design

- **Storage** (`TaskAttachments`, `MarkdownPro/Views/TaskAttachments.swift`):
  images live under `…/Application Support/MarkdownPro/attachments/task-<id>/`,
  numbered `1.png, 2.png, …`. Pasted `NSImage` re-encoded to PNG. Keyed by task
  id, so they persist across launches and are rebuilt from disk on open. No DB
  row, no sync.
- **Paste** (`TaskDetailView`): `.onPasteCommand(of: [.image])` on the
  `TextEditor` reads `NSImage(pasteboard:)`, calls `TaskAttachments.save`, appends
  the `[image N]` token, and commits the description. Text paste is unaffected
  (only `public.image` content triggers the handler).
- **Thumbnails + preview**: a horizontal strip of 48×48 buttons under the editor;
  each opens `ImagePreviewSheet` (scaled-to-fit `NSImage`) via a sheet keyed on an
  `AttachmentPreview` id.

## Non-goals (v1)

- No sync of images (explicitly out of scope).
- No inline rendering of the token inside the plain-text editor; no delete-from-UI
  (files can be managed on disk). Revisit if needed.

## Verification

`xcodebuild … build` → BUILD SUCCEEDED. `cd Core && swift test` → unchanged (no
Core touched). Manual (later): paste an image into a task description → `[image 1]`
token appears, thumbnail shows below, click previews; reopen the task → thumbnail
persists.
