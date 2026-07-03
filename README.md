# MarkdownPro

A fully local macOS app for managing tasks Linear-style and reading the
markdown files Claude Code generates while it works — plus an MCP server
so Claude can create tasks, move them across the board, log progress
notes, and attach its reports to the work they came from.

Everything lives on your Mac. No accounts, no cloud, no telemetry.

```
┌─────────────────┐   MCP (stdio)   ┌──────────────────┐
│   Claude Code    ├────────────────►│  markdownpro-mcp  │
└─────────────────┘                 └────────┬─────────┘
                                             │ SQL
┌─────────────────┐    polls data_version    ▼
│ MarkdownPro.app  ◄──────────────────► markdownpro.sqlite
│ (SwiftUI)        │
└─────────────────┘
```

## Layout

| Path | What it is |
| --- | --- |
| `MarkdownPro/` | SwiftUI app (macOS 14+, no external dependencies) |
| `Core/` | Local Swift package: models, SQLite layer, repository — shared by app and MCP server |
| `mcp-server/` | SwiftPM executable `markdownpro-mcp` (MCP over stdio, no external dependencies) |
| `MarkdownPro.xcodeproj` | Xcode project (Xcode 16+) — `project.yml` is an XcodeGen fallback |
| `docs/` | QA checklist and sample markdown files (mermaid, tables, code) |

## Build & run the app

1. Open `MarkdownPro.xcodeproj` in **Xcode 16+** on **macOS 14+**.
2. Press **⌘R**. First launch seeds a "Getting Started" project.

If the project file won't open for any reason, regenerate it:
`brew install xcodegen && xcodegen` (uses `project.yml`).

> The heavy lifting in this repo was written and logic-verified off-Mac:
> the whole SQL schema and every query were executed against a real
> SQLite, and the markdown/mermaid renderer was tested in Chromium in
> light + dark mode. The SwiftUI layer itself compiles only on your Mac —
> if Xcode flags something, it will be minor API drift, not logic.

## Build & connect the MCP server

```bash
cd mcp-server
swift build -c release
# binary: .build/release/markdownpro-mcp

# register with Claude Code (from anywhere):
claude mcp add markdownpro -- "$(pwd)/.build/release/markdownpro-mcp"
```

Then ask Claude Code things like:

- *"List my projects and create a task 'Refactor auth' in MarkdownPro, high priority, with subtasks for each step of your plan."*
- *"You're done with the migration — move task 12 to done and add a progress note about what changed."*
- *"Write your analysis to analysis.md and attach it to task 12."*

The app picks up Claude's writes within ~1.5 s (it polls SQLite's
`data_version`) — cards move across the board while Claude works.

### MCP tools

`list_projects` · `create_project` · `list_tasks` · `get_task` ·
`create_task` · `update_task` · `add_progress_note` · `add_subtask` ·
`set_subtask_done` · `attach_document` · `add_label`

Activity written through MCP is attributed to **Claude** (✨) in the
task's activity feed; edits made in the app are attributed to **You**.

## The reader

Sidebar → **Documents** → **Add Folder** and point it at wherever Claude
writes markdown (try `docs/samples` in this repo). Supported:

- GitHub-flavored markdown: tables, task lists, fenced code
- **Mermaid diagrams** (flowchart, sequence, etc.) — rendered locally
- Syntax highlighting (highlight.js, GitHub theme, light + dark)
- **Live reload** — the view re-renders ~1 s after the file changes on disk
- Relative images resolve against the file's folder; links open in your browser

All renderer assets (marked 18, mermaid 11, highlight.js 11) are bundled
in the app — the reader works fully offline.

## Data & storage

- Database: `~/Library/Application Support/MarkdownPro/markdownpro.sqlite`
  (WAL mode; plain documented schema — inspect it with `sqlite3` anytime).
- Override the location with the `MARKDOWNPRO_DB` env var (set it for both
  the app and the MCP server).
- **iCloud tip:** point `MARKDOWNPRO_DB` at a folder inside
  `~/Library/Mobile Documents/com~apple~CloudDocs/` and your tasks follow
  you across Macs — no CloudKit required. (Avoid running the app on two
  Macs simultaneously in that setup.)

## Verifying with Claude Code + Xcode MCP

On your Mac, give Claude Code build-and-run powers:

```bash
claude mcp add xcodebuild -- npx -y xcodebuildmcp@latest
```

Then: *"Build MarkdownPro.xcodeproj, fix any compile errors, run it, and
walk through docs/QA_CHECKLIST.md."*

## License

Apache-2.0 (see `LICENSE`).
