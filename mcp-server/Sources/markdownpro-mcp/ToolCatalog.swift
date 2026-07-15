import Foundation

/// MCP tool definitions (JSON Schema) advertised via tools/list.
enum ToolCatalog {
    private static func tool(_ name: String, _ description: String,
                             properties: [String: [String: Any]],
                             required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required
            ] as [String: Any]
        ]
    }

    private static let statusProp: [String: Any] = [
        "type": "string",
        "enum": ["backlog", "todo", "in_progress", "done", "canceled"],
        "description": "Task status"
    ]

    private static let priorityProp: [String: Any] = [
        "type": "string",
        "enum": ["urgent", "high", "medium", "low", "none"],
        "description": "Task priority"
    ]

    private static let attentionProp: [String: Any] = [
        "type": "string",
        "enum": ["needs_review", "changes_requested", "ready_to_execute", "executing"],
        "description": "Workflow attention flag"
    ]

    static let definitions: [[String: Any]] = [
        tool("list_projects",
             "List all projects with task counts and progress. Call this first to find project ids.",
             properties: [
                "include_archived": ["type": "boolean", "description": "Include archived projects (default false)"]
             ]),

        tool("create_project",
             "Create a new project.",
             properties: [
                "name": ["type": "string", "description": "Project name"],
                "color": ["type": "string", "description": "Hex color like #5E6AD2 (optional)"]
             ],
             required: ["name"]),

        tool("list_tasks",
             "List tasks, optionally filtered by project, status, or label. Returns summaries with ids.",
             properties: [
                "project_id": ["type": "integer", "description": "Filter by project id"],
                "status": statusProp,
                "label": ["type": "string", "description": "Filter by label name"],
                "attention": attentionProp
             ]),

        tool("get_task",
             "Get full detail for one task: description, subtasks, labels, activity log, linked documents.",
             properties: [
                "task_id": ["type": "integer", "description": "Task id"]
             ],
             required: ["task_id"]),

        tool("create_task",
             "Create a task in a project. Use this to turn a plan into tracked work items.",
             properties: [
                "project_id": ["type": "integer", "description": "Project id (from list_projects)"],
                "title": ["type": "string", "description": "Short task title"],
                "details": ["type": "string", "description": "Markdown description (optional)"],
                "status": statusProp,
                "priority": priorityProp,
                "due_date": ["type": "string", "description": "Due date as YYYY-MM-DD (optional)"],
                "labels": ["type": "array", "items": ["type": "string"], "description": "Label names; created if missing"],
                "subtasks": ["type": "array", "items": ["type": "string"], "description": "Checklist item titles"]
             ],
             required: ["project_id", "title"]),

        tool("update_task",
             "Update task fields. Only provided fields change. Move a task by setting status " +
             "(e.g. status=in_progress when you start work, status=done when finished). " +
             "Changes are recorded in the task's activity log attributed to Claude.",
             properties: [
                "task_id": ["type": "integer", "description": "Task id"],
                "title": ["type": "string", "description": "New title"],
                "details": ["type": "string", "description": "New markdown description"],
                "status": statusProp,
                "priority": priorityProp,
                "due_date": ["type": ["string", "null"], "description": "YYYY-MM-DD, or null to clear"],
                "project_id": ["type": "integer", "description": "Move to another project"]
             ],
             required: ["task_id"]),

        tool("add_progress_note",
             "Append a timestamped progress note to a task's activity feed. " +
             "Use this to report what you did, decisions made, or blockers found.",
             properties: [
                "task_id": ["type": "integer", "description": "Task id"],
                "message": ["type": "string", "description": "The progress note"]
             ],
             required: ["task_id", "message"]),

        tool("add_subtask",
             "Add a checklist item to a task.",
             properties: [
                "task_id": ["type": "integer", "description": "Task id"],
                "title": ["type": "string", "description": "Subtask title"]
             ],
             required: ["task_id", "title"]),

        tool("set_subtask_done",
             "Check or uncheck a subtask. Subtask ids come from get_task.",
             properties: [
                "subtask_id": ["type": "integer", "description": "Subtask id"],
                "done": ["type": "boolean", "description": "true = done (default true)"]
             ],
             required: ["subtask_id"]),

        tool("attach_document",
             "Link a markdown file on disk to a task and/or project so it appears in the app's reader. " +
             "Use this after writing a report, plan, or analysis file.",
             properties: [
                "task_id": ["type": "integer", "description": "Task to attach to"],
                "project_id": ["type": "integer", "description": "Project to attach to"],
                "path": ["type": "string", "description": "Absolute path to the .md file"],
                "title": ["type": "string", "description": "Display title (defaults to file name)"],
                "kind": ["type": "string", "enum": ["note", "wiki"],
                         "description": "Document kind (default note). Use submit_for_review for proposals."]
             ],
             required: ["path"]),

        tool("add_label",
             "Add a label to a task (label is created if it doesn't exist).",
             properties: [
                "task_id": ["type": "integer", "description": "Task id"],
                "name": ["type": "string", "description": "Label name, e.g. bug, feature, claude"],
                "color": ["type": "string", "description": "Hex color (optional)"]
             ],
             required: ["task_id", "name"]),

        tool("submit_for_review",
             "Submit a markdown document for the user's review. Registers the file on the task, " +
             "flags the task needs_review, and puts it in the app's Review queue. Use kind=spec for a " +
             "design/spec, kind=plan for an implementation plan, or the default proposal otherwise. " +
             "Resubmitting the same file after addressing feedback starts a new round.",
             properties: [
                "task_id": ["type": "integer", "description": "Task the document belongs to"],
                "path": ["type": "string", "description": "Absolute path to the .md file (must exist)"],
                "title": ["type": "string", "description": "Display title (defaults to file name)"],
                "kind": ["type": "string", "enum": ["proposal", "spec", "plan"],
                         "description": "Review stage (default proposal). Only spec and plan arm a Launch button."]
             ],
             required: ["task_id", "path"]),

        tool("get_review_feedback",
             "Get the review state and the user's inline annotations for a proposal. " +
             "Open annotations on a changes_requested doc are the actionable feedback: " +
             "each has the quoted text plus surrounding context and the user's comment.",
             properties: [
                "document_id": ["type": "integer", "description": "Document id (from submit_for_review or get_task)"]
             ],
             required: ["document_id"]),

        tool("resolve_annotation",
             "Mark a review annotation as addressed, with a short reply describing what you did. " +
             "Do this for every open annotation before resubmitting a revised proposal.",
             properties: [
                "annotation_id": ["type": "integer", "description": "Annotation id (from get_review_feedback)"],
                "reply": ["type": "string", "description": "What you changed in response"]
             ],
             required: ["annotation_id", "reply"]),

        tool("set_attention",
             "Set or clear a task's workflow attention flag. Set executing when you start " +
             "implementing an approved proposal; clear it (omit attention) when done.",
             properties: [
                "task_id": ["type": "integer", "description": "Task id"],
                "attention": attentionProp
             ],
             required: ["task_id"])
    ]
}
