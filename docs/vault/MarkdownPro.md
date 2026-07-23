---
type: project-moc
platform: macOS (SwiftUI)
tags: [project, macos, swift, mcp, markdownpro]
---

# MarkdownPro — Project MOC

> Fully local macOS app: a **Linear-style task manager** + **markdown reader**, plus an **MCP server** so Claude Code can drive the task board (create/move tasks, log progress, attach its reports). Everything lives on the Mac — no accounts, no cloud, no telemetry, no external Swift dependencies anywhere.

Repo: `~/Documents/Developer/markdown_pro` (branch `main`) · Platform: macOS 14+ / Xcode 16 · Store: local SQLite (`markdownpro.sqlite`) · License: Apache-2.0

Vault home for this project. This note is the index — start here.

## Related notes
- [[Architecture]] — three-process shape, shared SQLite, schema/migration rules
- [[MCP Server]] — the `markdownpro-mcp` stdio server, tool catalog, attribution
- [[Sync]] — GitHub-only sync (Spec B): transport, engine, Keychain token
- [[Work Log]] — ongoing work & decisions

## Key repo documents
- `CLAUDE.md` — working notes / conventions (source of truth for sharp edges)
- `README.md` — product framing + build/connect instructions
- `docs/QA_CHECKLIST.md` — manual verification list; walk it after UI changes
- `docs/superpowers/specs/` · `docs/superpowers/plans/` — specs & implementation plans

## What it is (three cooperating pieces)
- **`MarkdownPro/`** — SwiftUI app target (macOS 14+). Task board + markdown reader. Uses the Xcode 16 synchronized-folder project (dropping a file in the folder adds it to the target). `MarkdownPro/Web/` is the bundled renderer (marked 18 + mermaid 11 + highlight.js 11), flattened into `Contents/Resources/` — so resource file names must stay unique.
- **`Core/`** — local Swift package `MarkdownProCore`: models, hand-rolled SQLite wrapper (`import SQLite3`, no GRDB), `Repository` with all CRUD + activity logging, export/import, and the sync layer. **Shared by the app and the MCP server** — schema or query changes happen here, once.
- **`mcp-server/`** — SwiftPM executable `markdownpro-mcp`. Hand-rolled MCP stdio JSON-RPC (newline-delimited). Depends on `../Core`. See [[MCP Server]].

## The task board
Linear-style projects → tasks → subtasks, with priorities, labels, statuses, an activity feed, and a **Review queue** (specs submitted for review, with annotations). Mutations go through `Repository` so activity-log **attribution** stays correct: `user` from the app, `claude` from the MCP server. Export/import moves whole projects as `.mdproz` bundles (hand-rolled store-only zip, additive import — never a merge).

## The reader
Point **Documents → Add Folder** at wherever Claude writes markdown (e.g. `docs/samples`). GitHub-flavored markdown, mermaid diagrams, syntax highlighting (light + dark), **live reload** (~1 s after the file changes), relative images resolve against the file's folder. All renderer assets are bundled — the reader works fully offline.

## Current state (as of 2026-07-23)
- Branch `main` — **GitHub-only sync (Spec B) just merged** (`7b1bb52`). Latest fixes: on-demand adoption refresh, surfaced Keychain errors, guard against non-base64 contents (`d15f15d`). See [[Sync]].
- Sync was deliberately **narrowed from folder+GitHub to GitHub-only**: `FolderTransport` removed, engine tests migrated to `GitHubTransport`.
- Core is heavily tested (`Core/Tests/MarkdownProCoreTests` — repository, migrations, export/import, and the whole sync stack). The SwiftUI layer compiles only on a Mac.

## Build & test
```bash
# App
xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build
# MCP server
cd mcp-server && swift build -c release      # binary: .build/release/markdownpro-mcp
# Core package tests
cd Core && swift test
```
- DB location: `~/Library/Application Support/MarkdownPro/markdownpro.sqlite`; override with `MARKDOWNPRO_DB` (point it at a scratch file so the real board isn't polluted).
- Building from a git worktree: pass `-derivedDataPath` explicitly — `xcodebuild` keys DerivedData by project path, so a bare `MarkdownPro-*` glob can launch a stale binary from the main checkout.
