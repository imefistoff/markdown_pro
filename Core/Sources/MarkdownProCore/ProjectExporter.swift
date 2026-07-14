import Foundation

public enum ExportError: Error, CustomStringConvertible {
    case projectNotFound(Int64)

    public var description: String {
        switch self {
        case .projectNotFound(let id): return "Project \(id) no longer exists."
        }
    }
}

/// Builds a `.mdproz` bundle (a store-only zip) from selected projects.
public enum ProjectExporter {

    public static func export(projectIds: [Int64], repo: Repository) throws -> Data {
        let all = try repo.listProjects(includeArchived: true)
        var entries: [ZipEntry] = []
        var documentIndex = 0

        /// Embeds a document's contents, returning the manifest entry.
        /// A file we cannot read is exported with `file: nil` — a broken link
        /// exports as a broken link rather than failing the whole export.
        func embed(_ document: LinkedDocument) -> ExportedDocument {
            var entryName: String?
            if let contents = FileManager.default.contents(atPath: document.path) {
                documentIndex += 1
                let name = String(format: "documents/%04d-%@", documentIndex, safeFileName(document.path))
                entries.append(ZipEntry(name: name, data: contents))
                entryName = name
            }
            return ExportedDocument(title: document.title,
                                    originalPath: document.path,
                                    file: entryName)
        }

        var projects: [ExportedProject] = []
        for id in projectIds {
            guard let project = all.first(where: { $0.id == id }) else {
                throw ExportError.projectNotFound(id)
            }

            // documents(projectId:) returns project-level AND task-level rows;
            // the project-level ones are those with no task_id.
            let projectDocuments = try repo.documents(projectId: id)
                .filter { $0.taskId == nil }
                .map(embed)

            var tasks: [ExportedTask] = []
            for item in try repo.listTasks(projectId: id) {
                guard let detail = try repo.getTask(id: item.id) else { continue }
                tasks.append(ExportedTask(
                    title: detail.task.title,
                    details: detail.task.details,
                    status: detail.task.status.rawValue,
                    priority: detail.task.priority.rawValue,
                    dueDate: detail.task.dueDate.map(DateCoding.encodeDay),
                    sortOrder: detail.task.sortOrder,
                    createdAt: DateCoding.encode(detail.task.createdAt),
                    updatedAt: DateCoding.encode(detail.task.updatedAt),
                    labels: detail.task.labels.map { ExportedLabel(name: $0.name, color: $0.color) },
                    subtasks: detail.subtasks.map {
                        ExportedSubtask(title: $0.title, done: $0.done, sortOrder: $0.sortOrder)
                    },
                    // getTask returns activity newest-first; the bundle stores it chronologically.
                    activity: detail.activity.reversed().map {
                        ExportedActivity(actor: $0.actor, kind: $0.kind, message: $0.message,
                                         createdAt: DateCoding.encode($0.createdAt))
                    },
                    documents: detail.documents.map(embed)
                ))
            }

            projects.append(ExportedProject(
                name: project.name,
                color: project.color,
                archived: project.archived,
                createdAt: DateCoding.encode(project.createdAt),
                updatedAt: DateCoding.encode(project.updatedAt),
                documents: projectDocuments,
                tasks: tasks
            ))
        }

        let bundle = ExportBundle(formatVersion: ExportBundle.currentFormatVersion,
                                  exportedAt: DateCoding.encode(Date()),
                                  projects: projects)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        entries.insert(ZipEntry(name: ExportBundle.manifestEntryName,
                                data: try encoder.encode(bundle)), at: 0)

        return Zip.archive(entries)
    }

    /// Keeps zip entry names tame. The `%04d-` prefix already guarantees uniqueness,
    /// so this only has to be safe, not distinct.
    private static func safeFileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let safe = String(name.map { character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
                ? character : "-"
        })
        return safe.isEmpty ? "document.md" : safe
    }
}
