# MarkdownPro Architecture

This sample doc exercises everything the reader supports — it's also a
real description of how the app works. Open it in **Documents → Add
Folder → `docs/samples`**.

## System overview

```mermaid
flowchart LR
    subgraph Mac["Your Mac (fully local)"]
        A[MarkdownPro.app<br/>SwiftUI] -->|reads/writes| DB[(SQLite<br/>markdownpro.sqlite)]
        M[markdownpro-mcp<br/>Swift CLI] -->|reads/writes| DB
        A -->|polls data_version| DB
        C[Claude Code] -->|MCP over stdio| M
        A -->|WKWebView| R[renderer.html<br/>marked + mermaid + hljs]
    end
```

## How a task flows

```mermaid
sequenceDiagram
    participant You
    participant Claude as Claude Code
    participant MCP as markdownpro-mcp
    participant App as MarkdownPro.app

    You->>Claude: "plan this feature and track it"
    Claude->>MCP: create_task(title, subtasks, labels)
    MCP-->>Claude: task 42 created
    Claude->>MCP: update_task(42, status=in_progress)
    Note over App: board updates within ~1.5s
    Claude->>MCP: add_progress_note(42, tests passing)
    Claude->>MCP: attach_document(42, report.md)
    Claude->>MCP: update_task(42, status=done)
    App-->>You: card lands in Done ✅
```

## Feature checklist

- [x] Kanban board with drag & drop
- [x] Labels, subtasks, due dates
- [x] Activity feed per task (you vs. Claude)
- [ ] iOS companion app (someday)

## Status values

| Status | Meaning | Board column |
| --- | --- | --- |
| `backlog` | Someday/maybe | Backlog |
| `todo` | Ready to pick up | Todo |
| `in_progress` | Being worked on | In Progress |
| `done` | Finished | Done |
| `canceled` | Won't do | Canceled |

## Example: creating a task from Swift

```swift
let repo = Repository(db: try Database.open())
let id = try repo.createTask(
    projectId: 1,
    title: "Ship the reader",
    priority: .high,
    labels: ["feature"],
    subtasks: ["Render mermaid", "Live reload"]
)
```

> **Tip:** point the reader at the folder where Claude writes its reports
> and they re-render live every time the file changes on disk.
