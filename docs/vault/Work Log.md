---
type: log
tags: [project, macos, worklog]
---

# MarkdownPro — Work Log

Part of [[MarkdownPro]]. Reverse-chronological notes on active work, decisions, and gotchas.

## 2026-07-23
- Started tracking this project in an **in-repo Obsidian vault** at `docs/vault/` (created the [[MarkdownPro]] MOC + [[Architecture]], [[MCP Server]], [[Sync]], and this log). Same shape as the imamed / ICDigital notes, but single-project — this vault ships inside the repo and travels with a `git clone`.
- **Context**: `main` just merged **GitHub-only sync (Spec B)** (`7b1bb52`). The design was narrowed from folder+GitHub to GitHub-only mid-flight — `FolderTransport` removed, engine tests migrated to `GitHubTransport`.
- **Latest sync fixes** (`d15f15d`): on-demand adoption refresh, surfaced Keychain errors, guard against non-base64 contents from the GitHub API. Earlier: durable disconnect + genuine-switch cursor reset, GitHub token moved to the Keychain.
- Per-machine Obsidian layout files (`workspace.json`, `workspace-mobile.json`, `workspace.json.bak`) added to `.gitignore` so window state doesn't create merge noise; the rest of `.obsidian/` (shared config) stays tracked.
