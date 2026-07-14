import Foundation
import MarkdownProCore

/// Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Implemented by hand on Foundation only — no external dependencies.
final class MCPServer {
    private let repo: Repository
    private let stdout = FileHandle.standardOutput
    private let stderr = FileHandle.standardError

    init() throws {
        repo = Repository(db: try Database.open())
    }

    func run() {
        log("markdownpro-mcp started, db: \(Database.defaultPath())")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            handle(trimmed)
        }
    }

    private func log(_ message: String) {
        stderr.write(Data(("[markdownpro-mcp] " + message + "\n").utf8))
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        stdout.write(data)
        stdout.write(Data([0x0A]))
    }

    private func sendResult(id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func sendError(id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log("could not parse request line")
            return
        }
        let method = request["method"] as? String ?? ""
        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]

        // Notifications (no id) never get a response.
        guard let id else {
            if method == "notifications/initialized" { log("client initialized") }
            return
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2024-11-05"
            sendResult(id: id, [
                "protocolVersion": requested,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "markdownpro", "version": "1.0.0"]
            ])
        case "ping":
            sendResult(id: id, [String: Any]())
        case "tools/list":
            sendResult(id: id, ["tools": ToolCatalog.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try callTool(name: name, arguments: arguments)
                sendResult(id: id, [
                    "content": [["type": "text", "text": text]],
                    "isError": false
                ])
            } catch {
                sendResult(id: id, [
                    "content": [["type": "text", "text": "Error: \(error)"]],
                    "isError": true
                ])
            }
        default:
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tool dispatch

    enum ToolError: Error, CustomStringConvertible {
        case badArgument(String)
        case notFound(String)

        var description: String {
            switch self {
            case .badArgument(let m): return "invalid argument: \(m)"
            case .notFound(let m): return "not found: \(m)"
            }
        }
    }

    private func callTool(name: String, arguments args: [String: Any]) throws -> String {
        switch name {
        case "list_projects":
            let projects = try repo.listProjects(includeArchived: bool(args, "include_archived") ?? false)
            return jsonText(projects.map(Encode.project))

        case "create_project":
            let projectName = try requireString(args, "name")
            let id = try repo.createProject(name: projectName, color: string(args, "color") ?? "#5E6AD2")
            return jsonText(["project_id": id, "message": "Created project “\(projectName)”"])

        case "list_tasks":
            let status = try string(args, "status").map { raw -> TaskStatus in
                guard let s = TaskStatus(rawValue: raw) else {
                    throw ToolError.badArgument("status must be one of backlog|todo|in_progress|done|canceled")
                }
                return s
            }
            let attention = try string(args, "attention").map { raw -> TaskAttention in
                guard let a = TaskAttention(rawValue: raw) else {
                    throw ToolError.badArgument("attention must be one of needs_review|changes_requested|ready_to_execute|executing")
                }
                return a
            }
            let tasks = try repo.listTasks(projectId: int(args, "project_id"),
                                           status: status,
                                           labelName: string(args, "label"),
                                           attention: attention)
            return jsonText(tasks.map(Encode.taskSummary))

        case "get_task":
            let id = try requireInt(args, "task_id")
            guard let detail = try repo.getTask(id: id) else { throw ToolError.notFound("task \(id)") }
            var dict = Encode.taskDetail(detail)
            dict["linked_documents"] = try detail.documents.map { doc -> [String: Any] in
                var d = Encode.document(doc)
                if doc.kind == .proposal {
                    d["open_annotations"] = try repo.annotations(documentId: doc.id)
                        .filter { $0.state == .open }.count
                }
                return d
            }
            return jsonText(dict)

        case "create_task":
            let projectId = try requireInt(args, "project_id")
            let title = try requireString(args, "title")
            let status = string(args, "status").flatMap(TaskStatus.init(rawValue:)) ?? .todo
            let priority = string(args, "priority").flatMap(TaskPriority.init(rawValue:)) ?? .none
            let labels = stringArray(args, "labels")
            let subtasks = stringArray(args, "subtasks")
            let id = try repo.createTask(projectId: projectId, title: title,
                                         details: string(args, "details") ?? "",
                                         status: status, priority: priority,
                                         dueDate: string(args, "due_date"),
                                         labels: labels, subtasks: subtasks, actor: "claude")
            guard let detail = try repo.getTask(id: id) else { throw ToolError.notFound("task \(id)") }
            return jsonText(Encode.taskDetail(detail))

        case "update_task":
            let id = try requireInt(args, "task_id")
            var changes = Repository.TaskChanges()
            changes.title = string(args, "title")
            changes.details = string(args, "details")
            if let raw = string(args, "status") {
                guard let s = TaskStatus(rawValue: raw) else {
                    throw ToolError.badArgument("status must be one of backlog|todo|in_progress|done|canceled")
                }
                changes.status = s
            }
            if let raw = string(args, "priority") {
                guard let p = TaskPriority(rawValue: raw) else {
                    throw ToolError.badArgument("priority must be one of urgent|high|medium|low|none")
                }
                changes.priority = p
            }
            if args["due_date"] != nil {
                // Explicit null clears the due date; a string sets it.
                changes.dueDate = .some(string(args, "due_date"))
            }
            changes.projectId = int(args, "project_id")
            try repo.updateTask(id: id, changes: changes, actor: "claude")
            guard let detail = try repo.getTask(id: id) else { throw ToolError.notFound("task \(id)") }
            return jsonText(Encode.taskDetail(detail))

        case "add_progress_note":
            let id = try requireInt(args, "task_id")
            let message = try requireString(args, "message")
            guard try repo.getTask(id: id) != nil else { throw ToolError.notFound("task \(id)") }
            try repo.logActivity(taskId: id, actor: "claude", kind: "note", message: message)
            return jsonText(["message": "Note added to task \(id)"])

        case "add_subtask":
            let id = try requireInt(args, "task_id")
            let title = try requireString(args, "title")
            guard try repo.getTask(id: id) != nil else { throw ToolError.notFound("task \(id)") }
            let subtaskId = try repo.addSubtask(taskId: id, title: title)
            return jsonText(["subtask_id": subtaskId, "message": "Subtask added"])

        case "set_subtask_done":
            let id = try requireInt(args, "subtask_id")
            let done = bool(args, "done") ?? true
            try repo.setSubtaskDone(id: id, done: done)
            return jsonText(["message": "Subtask \(id) marked \(done ? "done" : "not done")"])

        case "attach_document":
            let path = try requireString(args, "path")
            let taskId = int(args, "task_id")
            let projectId = int(args, "project_id")
            guard taskId != nil || projectId != nil else {
                throw ToolError.badArgument("provide task_id and/or project_id")
            }
            var kind = DocumentKind.note
            if let raw = string(args, "kind") {
                guard let parsed = DocumentKind(rawValue: raw), parsed != .proposal else {
                    throw ToolError.badArgument("kind must be note or wiki (proposals go through submit_for_review)")
                }
                kind = parsed
            }
            let id = try repo.attachDocument(taskId: taskId, projectId: projectId,
                                             path: path, title: string(args, "title"), kind: kind)
            return jsonText(["document_id": id, "message": "Document attached"])

        case "add_label":
            let id = try requireInt(args, "task_id")
            let labelName = try requireString(args, "name")
            guard try repo.getTask(id: id) != nil else { throw ToolError.notFound("task \(id)") }
            try repo.addLabel(taskId: id, name: labelName, color: string(args, "color") ?? "#8B5CF6")
            return jsonText(["message": "Label “\(labelName)” added to task \(id)"])

        case "submit_for_review":
            let taskId = try requireInt(args, "task_id")
            let path = try requireString(args, "path")
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ToolError.badArgument("file does not exist: \(expanded)")
            }
            guard try repo.getTask(id: taskId) != nil else { throw ToolError.notFound("task \(taskId)") }
            let docId = try repo.submitForReview(taskId: taskId, path: expanded, title: string(args, "title"))
            guard let doc = try repo.document(id: docId) else { throw ToolError.notFound("document \(docId)") }
            return jsonText(["document_id": docId, "state": "needs_review", "round": doc.round,
                             "message": "Submitted “\(doc.title)” for review (round \(doc.round))"])

        case "get_review_feedback":
            let docId = try requireInt(args, "document_id")
            guard let doc = try repo.document(id: docId) else { throw ToolError.notFound("document \(docId)") }
            let annotations = try repo.annotations(documentId: docId)
            var dict = Encode.document(doc)
            dict["annotations"] = annotations.map(Encode.annotation)
            dict["open_annotations"] = annotations.filter { $0.state == .open }.count
            return jsonText(dict)

        case "resolve_annotation":
            let annotationId = try requireInt(args, "annotation_id")
            let reply = try requireString(args, "reply")
            try repo.resolveAnnotation(id: annotationId, reply: reply)
            return jsonText(["message": "Annotation \(annotationId) marked addressed"])

        case "set_attention":
            let taskId = try requireInt(args, "task_id")
            guard try repo.getTask(id: taskId) != nil else { throw ToolError.notFound("task \(taskId)") }
            var attention: TaskAttention?
            if let raw = string(args, "attention") {
                guard let parsed = TaskAttention(rawValue: raw) else {
                    throw ToolError.badArgument("attention must be one of needs_review|changes_requested|ready_to_execute|executing")
                }
                attention = parsed
            }
            try repo.setAttention(taskId: taskId, attention: attention)
            return jsonText(["message": attention.map { "Attention set to \($0.rawValue)" } ?? "Attention cleared"])

        default:
            throw ToolError.notFound("tool \(name)")
        }
    }

    // MARK: - Argument helpers

    private func string(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }

    private func requireString(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String, !v.isEmpty else { throw ToolError.badArgument("\(key) is required") }
        return v
    }

    private func int(_ args: [String: Any], _ key: String) -> Int64? {
        if let v = args[key] as? Int { return Int64(v) }
        if let v = args[key] as? Int64 { return v }
        if let v = args[key] as? Double { return Int64(v) }
        if let v = args[key] as? String { return Int64(v) }
        return nil
    }

    private func requireInt(_ args: [String: Any], _ key: String) throws -> Int64 {
        guard let v = int(args, key) else { throw ToolError.badArgument("\(key) is required") }
        return v
    }

    private func bool(_ args: [String: Any], _ key: String) -> Bool? {
        args[key] as? Bool
    }

    private func stringArray(_ args: [String: Any], _ key: String) -> [String] {
        (args[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private func jsonText(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Converts Core models to JSON-friendly dictionaries.
enum Encode {
    static func project(_ p: Project) -> [String: Any] {
        [
            "id": p.id,
            "name": p.name,
            "color": p.color,
            "archived": p.archived,
            "task_count": p.taskCount,
            "done_count": p.doneCount,
            "progress": (p.progress * 100).rounded() / 100
        ]
    }

    static func taskSummary(_ t: TaskItem) -> [String: Any] {
        var dict: [String: Any] = [
            "id": t.id,
            "project_id": t.projectId,
            "title": t.title,
            "status": t.status.rawValue,
            "priority": t.priority.rawValue,
            "labels": t.labels.map { $0.name },
            "subtasks_done": t.subtaskDoneCount,
            "subtasks_total": t.subtaskCount,
            "documents": t.documentCount,
            "updated_at": DateCoding.encode(t.updatedAt)
        ]
        if let due = t.dueDate { dict["due_date"] = DateCoding.encodeDay(due) }
        if !t.details.isEmpty { dict["details"] = t.details }
        if let attention = t.attention { dict["attention"] = attention.rawValue }
        return dict
    }

    static func taskDetail(_ d: TaskDetail) -> [String: Any] {
        var dict = taskSummary(d.task)
        dict["details"] = d.task.details
        dict["subtasks"] = d.subtasks.map { s -> [String: Any] in
            ["id": s.id, "title": s.title, "done": s.done]
        }
        dict["activity"] = d.activity.prefix(20).map { a -> [String: Any] in
            ["actor": a.actor, "kind": a.kind, "message": a.message, "at": DateCoding.encode(a.createdAt)]
        }
        dict["linked_documents"] = d.documents.map(Encode.document)
        return dict
    }

    static func document(_ d: LinkedDocument) -> [String: Any] {
        var dict: [String: Any] = ["id": d.id, "title": d.title, "path": d.path,
                                   "kind": d.kind.rawValue, "round": d.round]
        if let state = d.state { dict["state"] = state.rawValue }
        if let taskId = d.taskId { dict["task_id"] = taskId }
        return dict
    }

    static func annotation(_ a: MarkdownProCore.Annotation) -> [String: Any] {
        var dict: [String: Any] = ["id": a.id, "round": a.round, "quote": a.quote,
                                   "prefix": a.prefix, "suffix": a.suffix,
                                   "comment": a.comment, "author": a.author,
                                   "state": a.state.rawValue]
        if let reply = a.reply { dict["reply"] = reply }
        return dict
    }
}
