# QA Checklist

Work through this top to bottom on first run. Each item says what to do
and what you should see. Anything that doesn't match is a bug worth
filing as a task in the app itself ;)

## 1 · First launch

- [ ] App opens to the **Progress** view with stat tiles (Open / In Progress / Done / Overdue).
- [ ] Sidebar shows a seeded **Getting Started** project with 3 tasks and a progress %.
- [ ] Database file exists at `~/Library/Application Support/MarkdownPro/markdownpro.sqlite`.

## 2 · Projects

- [ ] **+** in the sidebar toolbar → create a project with a custom color → it appears sorted by name.
- [ ] Right-click a project → **Delete Project** → it and its tasks disappear.

## 3 · Tasks — board

- [ ] Select a project → board shows 5 columns (Backlog / Todo / In Progress / Done / Canceled) with counts.
- [ ] **⌘N** (or +) → create a task with title, markdown description, priority, due date → card appears in the right column.
- [ ] **Drag a card** to another column → it moves, and the project progress % in the sidebar updates when it lands in Done.
- [ ] Card shows: priority icon, labels, subtask progress (n/m), due date (red when overdue), doc count, `#id`.
- [ ] Toggle to **list view** (toolbar segmented control) → same tasks grouped by status; right-click a row → move / delete works.
- [ ] Label **filter menu** appears once tasks have labels and filters the board.

## 4 · Task detail (click a card)

- [ ] Edit the title, press ⏎ → activity feed logs "renamed to …".
- [ ] Change status via picker → logged as "moved from X to Y" attributed to **You**.
- [ ] Add a subtask, check it, uncheck it, delete it → card counters update after closing.
- [ ] Type in the **+ label** field, press ⏎ → chip appears; right-click chip → remove works.
- [ ] Set a due date, clear it with ⓧ → both logged in activity.
- [ ] Add a note → appears at the top of activity with a person icon.
- [ ] Trash button deletes the task.

## 5 · Progress view

- [ ] Stat tile numbers match reality across all projects.
- [ ] Move a task to Done → **Completed · last 14 days** bar chart gains a bar for today (revisit the view).
- [ ] Per-project progress bars match n done / n total.

## 6 · Reader

- [ ] Sidebar → **Documents** → **Add Folder** → pick `docs/samples` from this repo.
- [ ] Tree shows `architecture.md` and `progress-report.md`; select one.
- [ ] **Mermaid**: flowchart and sequence diagram render as diagrams, not code blocks.
- [ ] Tables, task-list checkboxes, and syntax-highlighted Swift code all render.
- [ ] Toggle macOS dark mode → document and mermaid re-theme without reselecting.
- [ ] **Live reload**: `echo "## added $(date)" >> docs/samples/progress-report.md` in a terminal → view updates within ~2 s.
- [ ] Click a web link in a doc → opens in your default browser, not inside the app.
- [ ] Remove the folder via the ⋯ menu → tree empties.

## 7 · MCP — Claude Code integration

Setup: build and register per README, then in a Claude Code session:

- [ ] *"List my MarkdownPro projects"* → Claude returns the seeded project.
- [ ] *"Create a task 'MCP smoke test' in Getting Started, priority high, labels: claude, with subtasks: one, two"* → **card appears in the app within ~2 s without touching it**.
- [ ] *"Move it to in progress and add a progress note that you started"* → card slides columns; detail shows the note with a ✨ sparkles icon attributed to Claude.
- [ ] *"Mark subtask 'one' done"* → counter on the card becomes 1/2.
- [ ] Ask Claude to write `report.md` somewhere and *"attach it to the task"* → task detail shows the linked doc; **Open in Reader** jumps to Documents and renders it.
- [ ] *"Move it to done"* → Progress view chart ticks up for today.

## 8 · Multi-window / edge cases

- [ ] Quit and relaunch → data, reader folders, and view mode (board/list) persist.
- [ ] Create a task while the MCP server is mid-session → no locking errors (WAL + busy timeout).
- [ ] A markdown file with a broken mermaid block shows an inline mermaid error, not a blank page.

## §8 Review Center

*Headless e2e (submit → feedback → resolve → resubmit → round 2) verified automatically on 2026-07-04; interactive items below need a human pass.*

Setup: scratch DB (`MARKDOWNPRO_DB=/tmp/qa.sqlite`), one project + task, a
proposal `.md` submitted via `submit_for_review` (see mcp-server README or
Task 4 of the review-center plan for the JSON-RPC lines).

- [ ] Sidebar shows **Review** with a badge equal to the number of
      `needs_review` proposals; badge hides at zero.
- [ ] Submitting a proposal while the app runs shows the toast within ~2 s;
      clicking the toast opens Review.
- [ ] Queue rows show title, task, project, round chip (round ≥ 2 only),
      and age; selection follows clicks and stays valid after refresh.
- [ ] Document renders with mermaid + syntax highlighting intact.
- [ ] Selecting text shows "Comment (c)"; both the button and the `c` key
      open the composer with the quote; Save paints a highlight.
- [ ] Selection across a code block and across two paragraphs both anchor.
- [ ] Clicking a highlight scrolls the panel to its comment.
- [ ] Comment context menu → Delete removes comment and highlight.
- [ ] Request Changes is disabled with zero comments; with comments it
      moves doc → changes_requested, task chip → 🟡, queue advances.
- [ ] Approve with unsent comments warns ("FYI notes"); approving moves
      task chip → 🟢 ready to execute.
- [ ] Reject asks for confirmation; task returns to Todo, chip clears.
- [ ] After Claude resubmits (round 2): prior comments listed under
      "Earlier" with green check + reply once resolved; only current-round
      comments paint highlights.
- [ ] Editing the file so a quote disappears flags that comment
      "Unanchored" instead of highlighting the wrong text.
- [ ] Activity log on the task shows review entries with correct actors
      (user verdicts, claude submissions/resolutions).
- [ ] Plain reader (Documents section) still renders and never shows the
      comment button.

## §9 Export / import

- [ ] **File ▸ Export Projects…** lists every project with its task count; archived
      projects appear but start unchecked.
- [ ] Right-clicking a project in the sidebar offers **Export…**, with that project
      already checked.
- [ ] Exporting writes a `.mdproz` file. `unzip -l <file>` lists `manifest.json`
      and one entry per attached document.
- [ ] A project with no documents exports and imports cleanly.
- [ ] **File ▸ Import Projects…** previews the bundle — project names, task counts,
      and how many documents relink versus restore — before writing anything.
- [ ] Cancelling the import sheet writes nothing.
- [ ] Importing restores tasks with their status, priority, due date, labels,
      subtasks and activity history, with `claude` attribution intact.
- [ ] Importing a bundle whose project name already exists creates
      `<name> (imported)` and leaves the existing project untouched.
- [ ] A document whose original file still exists links to that live file; a
      document whose original is gone is restored under
      `~/Library/Application Support/MarkdownPro/Imported/` and still opens in
      the reader.
- [ ] Importing a non-export file (a random `.zip`, or a `.txt`) shows a clear
      error and changes nothing.
- [ ] A task carrying review state (proposal doc, annotations, attention chip)
      exports and imports without error — review state is **not** carried by the
      bundle, so the imported copy comes back clean.

## §10 Launch (Claude Code from Review)

Setup: scratch DB (`MARKDOWNPRO_DB=/tmp/qa-launch.sqlite`), one project. Right-click
the project → **Project Settings…** → set the repo path to a real git repo.

- [ ] With no repo path, an approved spec/plan shows a **Set repo path…** button
      that opens Project Settings; setting a path turns it into a green **Launch**.
- [ ] Submitting `kind=spec` via `submit_for_review` puts the doc in Review; the
      queue row and document render as before.
- [ ] Approving the spec arms **Launch** on the card and in task detail; approving
      a plain `proposal` arms **no** Launch button.
- [ ] Launch opens a sheet showing the exact script: `cd '<repo>'`, a quoted
      `<<'MDPRO_PROMPT_EOF'` heredoc carrying the prompt, and the `exec claude` line.
- [ ] A spec launch has **no** `-w` and `--permission-mode plan`; a plan launch with
      the worktree toggle on has `-w 'task-N-…'` and the project's preset.
- [ ] With an unsafe preset (auto/dontAsk/bypassPermissions) on a plan launch, the
      sheet shows a red warning band and Return does **not** trigger Run.
- [ ] **Copy** puts the script on the clipboard; pasting into a terminal and running
      it starts the session.
- [ ] **Run** opens a new Warp window in the repo dir running `claude`; the task chip
      flips to **Executing** and the activity log shows a `launch` entry (You).
- [ ] With Warp not installed, Run is replaced by "Warp not found — copy and run
      manually" and Copy still works.
- [ ] If the approved document is deleted from disk, the sheet still opens but Run is
      disabled with a "no longer exists" note.
- [ ] A task stuck **Executing** (session killed) can be cleared via the **Clear**
      button next to the chip in task detail.
- [ ] Editing a project template then **Reset to default** restores the built-in
      prompt and removes the override (relaunch shows the default in the sheet).

## § Sync (GitHub)

GitHub is the only sync mechanism. One-time setup: create an empty **private**
repo (with a README) on GitHub, and a **fine-grained token** scoped to just that
repo (Contents: read/write). The convergence logic is covered automatically by
`GitHubTransportTests` / `SyncEngineTests` / `SyncReplayerTests` in
`Core/Tests/MarkdownProCoreTests` (the engine tests run over `GitHubTransport`);
the items below are the live two-Mac GUI/network walk.

- [ ] Settings ▸ Sync: entering owner/repo + a bad token shows a clear "not found or no access" error and stays disconnected.
- [ ] A valid token connects; the header shows "Connected — GitHub: owner/repo".
- [ ] Toggle a project synced on Mac A → the repo gains `ops/<A>/1.jsonl`, `blobs/…`, and `devices.json` (check on github.com).
- [ ] On Mac B (same repo + its own token), the project appears under "Available to adopt"; adopting materializes tasks, subtasks, labels, activity and documents.
- [ ] Edit different fields of one task on each Mac without syncing between → after sync, both edits survive (field-level merge).
- [ ] Delete a task on A while editing it on B → after sync, it stays deleted on both.
- [ ] An unsynced ("private") project never writes anything into the repo (inspect `ops/` on github.com).
- [ ] Attach a document on A → its content appears on B (managed copy under Application Support/MarkdownPro/Synced).
- [ ] Edit the document on A → the change reaches B on the next sync.
- [ ] Claude (MCP) creates a task in a synced project while the app is closed → it publishes when the app next launches.
- [ ] A change made on either Mac converges to the other after sync (bidirectional).
- [ ] Idempotent re-sync (no new local changes) adds no new commits to the repo.
- [ ] Set one Mac's clock behind the other, then sync — HLC causality still resolves correctly (no reordering of updates).
- [ ] The same label name created independently on both Macs converges to a single label row after sync.
- [ ] Detaching then re-attaching a label on either Mac converges so the label ends up attached.
- [ ] A document whose original file still exists on the peer relinks to it; one whose original is missing restores a managed copy.
- [ ] Revoke/expire the token → sync surfaces a non-blocking "Sync failed" error and the app keeps working; reconnecting with a fresh token resumes.
- [ ] Disconnect clears the token (Keychain) and stops syncing (stays off after relaunch); the repo is untouched.
