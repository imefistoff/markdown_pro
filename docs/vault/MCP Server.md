---
type: reference
tags: [project, mcp, jsonrpc]
---

# MarkdownPro — MCP Server

Part of [[MarkdownPro]].

`markdownpro-mcp` is a SwiftPM executable that lets Claude Code drive the task board. It speaks **newline-delimited MCP JSON-RPC on stdio** (hand-rolled, no MCP SDK) and talks to the same store as the app through `MarkdownProCore.Repository`. See [[Architecture]].

## Source (`mcp-server/Sources/markdownpro-mcp/`)
- **`main.swift`** — entry point, stdio read/write loop.
- **`MCPServer.swift`** — JSON-RPC dispatch (`initialize`, `tools/list`, `tools/call`).
- **`ToolCatalog.swift`** — the tool definitions + argument decoding → `Repository` calls.

## Tools
`list_projects` · `create_project` · `list_tasks` · `get_task` · `create_task` · `update_task` · `add_progress_note` · `add_subtask` · `set_subtask_done` · `attach_document` · `add_label`
Plus review-flow tools: `submit_for_review` · `get_review_feedback` · `resolve_annotation` · `set_attention`.

## Attribution
Everything written through MCP is logged with `actor = "claude"` (shows as ✨ Claude in the activity feed); app edits are `actor = "user"` (You). This only holds because every mutation goes through `Repository` — never bypass it.

## Build & drive it directly
```bash
cd mcp-server && swift build -c release      # binary: .build/release/markdownpro-mcp

# register with Claude Code (from anywhere):
claude mcp add markdownpro -- "$(pwd)/.build/release/markdownpro-mcp"

# smoke-test over stdio:
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./.build/release/markdownpro-mcp
```
- For DB/Repository changes, point `MARKDOWNPRO_DB` at a temp file so the real board isn't polluted.
- The app picks up the server's writes within ~1.5 s (`data_version` polling) — cards move on the board while Claude works.
