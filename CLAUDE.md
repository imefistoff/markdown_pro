# MarkdownPro — working notes for Claude Code

Fully local macOS app: Linear-style task manager + markdown reader, plus
an MCP server so Claude Code can drive the task board. No network
features, no external Swift dependencies anywhere.

## Layout

- `MarkdownPro/` — SwiftUI app target (macOS 14+). Uses the Xcode 16
  synchronized-folder project: adding a file to this directory adds it to
  the target automatically. `MarkdownPro/Web/` is the bundled renderer
  (marked + mermaid + highlight.js); resources are flattened into
  `Contents/Resources/`, so file names must stay unique.
- `Core/` — local Swift package `MarkdownProCore`: models, SQLite wrapper
  (`import SQLite3`, no GRDB), `Repository` with all CRUD + activity
  logging. Shared by the app and the MCP server — schema or query changes
  happen HERE, once.
- `mcp-server/` — SwiftPM executable `markdownpro-mcp`. Hand-rolled MCP
  stdio JSON-RPC (newline-delimited). Depends on `../Core`.
- `docs/QA_CHECKLIST.md` — manual verification list; walk it after
  significant UI changes.

## Build / run / test

```bash
# App (or use XcodeBuildMCP tools if available)
xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build

# MCP server
cd mcp-server && swift build -c release        # binary: .build/release/markdownpro-mcp

# Core package tests (add tests under Core/Tests/MarkdownProCoreTests)
cd Core && swift test
```

Run the built app from the CLI:
`open ~/Library/Developer/Xcode/DerivedData/MarkdownPro-*/Build/Products/Debug/MarkdownPro.app`

## Conventions & sharp edges

- `Label` is ambiguous between SwiftUI and MarkdownProCore — always
  qualify: `SwiftUI.Label` for the view, `MarkdownProCore.Label` for the
  model. The task model is `TaskItem` (never `Task`, which clashes with
  Swift Concurrency).
- Dates are TEXT columns: ISO-8601 with fractional seconds for
  timestamps, plain `yyyy-MM-dd` for due dates (`DateCoding`).
- Every meaningful mutation goes through `Repository` so activity-log
  attribution stays correct: `actor` is `"user"` from the app, `"claude"`
  from the MCP server.
- The app polls `PRAGMA data_version` (1.5 s) to pick up MCP writes —
  never add a second write path that bypasses the shared SQLite file.
- Schema changes: bump `PRAGMA user_version` and add a migration step in
  `Core/Sources/MarkdownProCore/Database.swift`. Both processes migrate
  on open, so migrations must be idempotent and ordered.
- DB location: `~/Library/Application Support/MarkdownPro/markdownpro.sqlite`,
  overridable via `MARKDOWNPRO_DB` (useful for testing against a scratch DB).
- Export/import lives in `Core`: `Zip.swift` (hand-rolled store-only zip — no
  dependency, no shelling out to `/usr/bin/zip`), `ExportBundle.swift` (the
  `manifest.json` types, carrying no row ids), `ProjectExporter` /
  `ProjectImporter`. Bundles are `.mdproz` files. Import is additive: a name
  collision becomes `<name> (imported)`, never a merge.
  `Repository.insertImportedProject` exists because `createTask` stamps its own
  timestamps and auto-logs a "created" entry — both wrong when restoring real
  history. Note `db.transaction` is not reentrant, so anything called from
  inside it must not open its own transaction.
- Building from a git worktree: `xcodebuild` keys DerivedData by project path,
  so `~/Library/Developer/Xcode/DerivedData/MarkdownPro-*` matches several
  directories. Pass `-derivedDataPath` explicitly, or you will launch a stale
  binary built from the main checkout and debug a ghost.

## Testing a change end-to-end

1. Build the app; fix compile errors.
2. Launch it, exercise the changed flow (XcodeBuildMCP launch + logs, or
   `screencapture -x shot.png` for visual checks).
3. For MCP changes: rebuild `markdownpro-mcp`, then drive it directly —
   it speaks newline-delimited JSON-RPC on stdio:
   `echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./mcp-server/.build/release/markdownpro-mcp`
4. For DB/Repository changes: point `MARKDOWNPRO_DB` at a temp file so
   the real board isn't polluted.
