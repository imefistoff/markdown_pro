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
