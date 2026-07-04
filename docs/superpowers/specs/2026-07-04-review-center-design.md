# Review Center & Workflow Foundation — Design

**Date:** 2026-07-04
**Status:** Approved for planning
**Scope:** Sub-projects A (workflow foundation) + B (Review Center UI) of the
human-in-the-loop autonomous dev workflow. Dispatch-from-app, navigation
reorg, and the local-LLM executor are explicitly out of scope.

## Problem

MarkdownPro's board is a shared store that both the user and Claude mutate,
but every round-trip ("here's my proposal" → "here's my feedback") happens
out-of-band in chat. The bottleneck of the whole loop is the user's review
throughput. This design adds a first-class review loop: Claude submits
markdown proposals into a queue, the user annotates them inline with a
three-verdict flow, and the verdicts drive task state automatically.

## Decisions (agreed in brainstorming)

1. **Everything needing user input is an MD doc** — proposals, bug analyses,
   question memos. One queue, one UI. No separate lightweight-question type.
2. **Two-dimensional task state** — the 5 existing board statuses stay
   untouched; a new orthogonal `attention` flag carries the workflow.
3. **Rounds + resolved comments, no diffs** — each resubmission is a round;
   prior comments persist as resolved-with-reply. No rendered diffing in v1.
4. **Verdict side-effects** — Approve → `ready_to_execute`; Request changes →
   `changes_requested`; Reject → proposal dead, task back to `todo`.
5. **Annotation surface = the existing web renderer** (approach 1): a JS
   annotation layer in `renderer.html` over the marked/mermaid/highlight.js
   pipeline, native SwiftUI chrome around it. Fallback path if the highlight
   JS proves unworkable: same schema, comments live only in the side panel
   (quote-picker mode) — a degradation, not a redesign.

## Section 1 — Data model & migration (Core)

### `documents` — new columns

| column | type | values / default |
|---|---|---|
| `kind` | TEXT NOT NULL | `note` (default) \| `wiki` \| `proposal` |
| `state` | TEXT NULL | proposals only: `needs_review`, `changes_requested`, `approved`, `rejected`, `superseded` |
| `round` | INTEGER NOT NULL | default 1; incremented on each resubmission |
| `updated_at` | TEXT | ISO-8601 with fractional seconds (`DateCoding`) |

Existing rows migrate as `kind='note'`, `state=NULL`, `round=1`.

### `annotations` — new table (W3C TextQuoteSelector model)

```sql
CREATE TABLE IF NOT EXISTS annotations (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  document_id  INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  round        INTEGER NOT NULL,          -- round the comment was made in
  quote        TEXT NOT NULL,             -- exact selected text
  prefix       TEXT NOT NULL DEFAULT '',  -- ~32 chars of context before
  suffix       TEXT NOT NULL DEFAULT '',  -- ~32 chars of context after
  comment      TEXT NOT NULL,
  author       TEXT NOT NULL,             -- "user" | "claude"
  state        TEXT NOT NULL DEFAULT 'open',  -- open | addressed
  reply        TEXT,                      -- Claude's response when addressed
  created_at   TEXT NOT NULL,
  resolved_at  TEXT
);
```

Anchoring by quote + context: if the quoted text still exists in a later
round's document, the highlight re-attaches; if not, the comment degrades to
an "unanchored" entry in the side panel. Never a silent drop, never a wrong
highlight. Anchor staleness is computed at render time, not stored.

### `tasks` — new column

`attention TEXT NULL` — `needs_review | changes_requested | ready_to_execute
| executing`. NULL means nothing pending. Board statuses are untouched.

### Verdict semantics (Repository, one transaction each, activity-logged)

| action | document | task |
|---|---|---|
| Approve | `approved` | attention → `ready_to_execute` |
| Request changes | `changes_requested` | attention → `changes_requested` |
| Reject | `rejected` | attention → NULL, status → `todo` |
| Claude resubmits | `needs_review`, round += 1 | attention → `needs_review` |

Every transition writes an `activity` row with the correct `actor`
(`"user"` for verdicts from the app, `"claude"` for submissions/resolutions
via MCP).

### Migration

Bump `PRAGMA user_version`; idempotent `ALTER TABLE ... ADD COLUMN` guarded
by column existence checks + `CREATE TABLE IF NOT EXISTS`, following the
existing convention in `Core/Sources/MarkdownProCore/Database.swift`. Both
the app and the MCP server migrate on open; racing on first open is safe.

## Section 2 — MCP surface

New tools:

- **`submit_for_review(task_id, path, title)`** — registers (or re-registers)
  the file as a `proposal` in `needs_review`; bumps `round` on resubmission;
  sets task attention. Fails loudly if `path` does not exist on disk.
- **`get_review_feedback(document_id)`** — returns doc state, round, and
  annotations as `{id, round, quote, prefix, suffix, comment, state, reply}`.
  Open annotations from the latest verdict are the actionable set.
- **`resolve_annotation(annotation_id, reply)`** — marks a comment
  `addressed` with Claude's reply and `resolved_at`.
- **`set_attention(task_id, value)`** — lets Claude flip a task to
  `executing` (or clear attention) when starting/finishing implementation.

Extended tools:

- `attach_document` gains an optional `kind` parameter (`note` default,
  `wiki` for wiki pages).
- `list_tasks` gains an optional `attention` filter — the executor-agnostic
  hook a future watcher or local-LLM dispatcher will poll.
- `get_task` includes per-document `kind`, `state`, `round`, and open
  annotation counts.

All writes go through `Repository`; no second write path. The app picks up
changes via the existing `PRAGMA data_version` poll (1.5 s).

## Section 3 — Review Center UI (app)

### Sidebar

New top-level **Review** item above Projects, badge = count of docs in
`needs_review`. When the poll detects a newly submitted doc, the badge
updates and a subtle in-app toast appears ("Proposal ready: <title> —
Review"). No macOS system notifications in v1.

### Layout

Two panes, built for minimum clicks:

- **Left — queue.** Docs awaiting verdict, newest round first. Row: title,
  task, project, round badge, age. `⌘↓`/`⌘↑` or click to navigate;
  issuing a verdict auto-advances to the next item.
- **Right — document.** The existing `WKWebView` renderer with the
  annotation layer, a slim comments panel, and a verdict bar pinned at the
  bottom.

### Annotation interaction

1. Select text → floating "Comment" button appears at the selection.
2. Click or press `C` → popover with text field; `⌘↵` saves.
3. Selection gets a persistent highlight via the **CSS Custom Highlight
   API** (no DOM mutation — mermaid and code blocks stay intact). Highlight
   and panel entry are linked both ways (click ⇄ scroll).
4. Comments persist to the `annotations` table immediately (crash-safe),
   state `open`, and stay editable/deletable until a verdict is issued.
   The *verdict* — not the comment — is what signals Claude to act: the
   actionable set for `get_review_feedback` is open annotations on a doc
   in `changes_requested` (or, as FYI notes, on an `approved` doc).

JS ↔ Swift: `window.getSelection()` capture → `{quote, prefix, suffix}` via
`WKScriptMessageHandler`; Swift pushes saved annotations back for painting.

### Verdict bar

- **Approve** (`⌘⏎`) — if unsent comments exist, warn: "You have N comments —
  approve anyway? They'll be sent as FYI notes."
- **Request changes** (`⌘⇧⏎`) — requires ≥ 1 comment.
- **Reject** — confirmation dialog (it also moves the task to `todo`).

### Rounds in the panel

Comments grouped by round. Prior rounds render resolved: original quote +
comment, Claude's `reply` beneath, green check. Only current-round
annotations paint highlights in the doc. Quotes that no longer match the
revised text appear in the panel flagged **unanchored**.

### Board alignment

Kanban cards get an attention chip: 🟠 needs review, 🟡 changes requested,
🟢 ready to execute, 🔵 executing. `TaskDetailView` shows the chip plus each
attached document's review state.

## Section 4 — End-to-end flow

1. A task exists; Claude brainstorms (typically in a worktree) and writes
   `docs/proposals/<slug>.md` in the target repo.
2. Claude calls `submit_for_review` → Review badge lights up.
3. User reads, drops inline comments, hits **Request changes**.
4. Claude calls `get_review_feedback`, revises the doc,
   `resolve_annotation`s each comment with a reply, resubmits → round 2.
5. User verifies resolved comments, hits **Approve** → task goes
   🟢 `ready_to_execute`.
6. Dispatch is manual for now ("implement task #42"); Claude sets
   `executing` while working. The `attention` filter on `list_tasks` is the
   forward hook for automated dispatch / local-LLM executors later.

## Error handling

- Unanchored comments degrade visibly in the panel, never silently.
- `submit_for_review` with a missing file fails at the MCP layer.
- Verdicts are single transactions — no doc-approved-but-task-unflagged
  states.
- Idempotent migration tolerates app/MCP racing on first open.

## Testing

- **Core** gets its first test suite (`Core/Tests/MarkdownProCoreTests`):
  migration from a legacy-schema fixture DB, verdict state transitions,
  annotation CRUD, round bumping — all against `MARKDOWNPRO_DB` temp files
  via `swift test`.
- **MCP**: drive the new tools directly with newline-delimited JSON-RPC via
  `echo ... | markdownpro-mcp` against a scratch DB.
- **Annotation JS / UI**: new section in `docs/QA_CHECKLIST.md` (selection
  over code blocks, over mermaid, cross-paragraph selection, unanchored
  degradation, verdict keyboard shortcuts, queue auto-advance).

## Out of scope

Dispatch-from-app, navigation reorg (project-first nav + Docs wiki section),
rendered diffs between rounds, comment threading, macOS system
notifications, the local-LLM executor. The `attention` flag and `list_tasks`
filter are the only forward-compatibility bought now.
