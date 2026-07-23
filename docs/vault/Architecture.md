---
type: reference
tags: [project, macos, architecture, sqlite]
---

# MarkdownPro — Architecture

Part of [[MarkdownPro]].

## Stack
- **Language**: Swift 5 · **Min macOS**: 14 · **UI**: SwiftUI
- **Storage**: raw SQLite via `import SQLite3` (no GRDB, no SwiftData) · WAL mode
- **No external Swift dependencies** anywhere — app, Core, and MCP server are all dependency-free.

> Why raw SQLite and not SwiftData: two separate processes (the app and the MCP server) share one on-disk store, and the app must see the MCP server's writes. SwiftData assumes single-process ownership; a plain SQLite file with WAL + `data_version` polling is what makes the two-process design work.

## Three cooperating pieces
```
Claude Code ──MCP (stdio JSON-RPC)──► markdownpro-mcp ──┐
                                                        │ SQL
MarkdownPro.app ──polls PRAGMA data_version (1.5 s)──► markdownpro.sqlite
```
- **`MarkdownPro/`** — SwiftUI app. `Store.swift` is the app-side view model; `Views/` the screens (board, task detail, review center, stats, sync settings, export/import sheets); `Reader/` the markdown/review WebViews; `Web/` the bundled renderer.
- **`Core/` (`MarkdownProCore`)** — the shared brain. Models, SQLite wrapper, `Repository`, export/import, sync. Both processes link it, so **schema and query changes happen here once**.
- **`mcp-server/` (`markdownpro-mcp`)** — thin stdio server over `Repository`. See [[MCP Server]].

## Core source layout (`Core/Sources/MarkdownProCore/`)
- **`Database.swift`** — connection, schema, migrations (`PRAGMA user_version`).
- **`SQLite.swift`** — thin `SQLite3` wrapper (statements, binding, transactions).
- **`Models.swift`** — `TaskItem` (never `Task` — clashes with Swift Concurrency), `MarkdownProCore.Label` (qualify — ambiguous with `SwiftUI.Label`), project/subtask/activity types.
- **`Repository.swift`** — all CRUD + activity logging. Every meaningful mutation routes here so `actor` attribution stays correct.
- **Export/import** — `Zip.swift` (hand-rolled store-only zip, no shelling out to `/usr/bin/zip`), `ExportBundle.swift` (`manifest.json` types, carry no row ids), `ProjectExporter` / `ProjectImporter`. Bundles are `.mdproz`. Import is **additive**: a name collision becomes `<name> (imported)`, never a merge. `Repository.insertImportedProject` bypasses the auto-timestamp/auto-log path so restored history stays intact.
- **Sync** — `SyncEngine`, `SyncTransport`, `GitHubTransport`, `GitHubAPI`, `SyncClock`, `SyncModels`, `SyncState`, `SyncReplayer`. See [[Sync]].
- **Launch** — `Launch.swift`, `LaunchScriptBuilder.swift` (app-launch helper wiring; app side is `MarkdownPro/Launch/WarpLauncher.swift`).

## Storage rules & sharp edges
- **Dates are TEXT columns**: ISO-8601 with fractional seconds for timestamps, plain `yyyy-MM-dd` for due dates (`DateCoding`).
- **Attribution**: `actor` is `"user"` from the app, `"claude"` from the MCP server. Never add a second write path that bypasses the shared SQLite file.
- **Change pickup**: the app polls `PRAGMA data_version` every 1.5 s to notice MCP writes.
- **Migrations**: bump `PRAGMA user_version` and add an ordered, **idempotent** migration step in `Database.swift` — both processes migrate on open.
- **`db.transaction` is not reentrant**: anything called from inside a transaction must not open its own.
- **DB location**: `~/Library/Application Support/MarkdownPro/markdownpro.sqlite`, overridable via `MARKDOWNPRO_DB`.

## Renderer (`MarkdownPro/Web/`)
Bundled marked 18 + mermaid 11 + highlight.js 11 (GitHub theme, light + dark) + `renderer.html` / `renderer-core.js` / `review-annotations.js`. Flattened into `Contents/Resources/`, so **file names must stay unique**. Fully offline; live-reloads ~1 s after a file changes.
