import Foundation

/// The `manifest.json` inside a `.mdproz` export bundle.
///
/// Deliberately carries **no database IDs** — row ids are meaningless on another
/// machine. Relationships are expressed by nesting: subtasks inside their task,
/// tasks inside their project.
///
/// All timestamps are strings in `DateCoding` form (ISO-8601 with fractional
/// seconds); `dueDate` is a plain `yyyy-MM-dd`, matching how they are stored.
public struct ExportBundle: Codable, Sendable {
    public static let currentFormatVersion = 1
    public static let manifestEntryName = "manifest.json"

    public var formatVersion: Int
    public var exportedAt: String
    public var projects: [ExportedProject]

    public init(formatVersion: Int, exportedAt: String, projects: [ExportedProject]) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.projects = projects
    }
}

public struct ExportedProject: Codable, Sendable {
    public var name: String
    public var color: String
    public var archived: Bool
    public var createdAt: String
    public var updatedAt: String
    /// Documents attached to the project itself (not to one of its tasks).
    public var documents: [ExportedDocument]
    public var tasks: [ExportedTask]

    public init(name: String, color: String, archived: Bool, createdAt: String, updatedAt: String,
                documents: [ExportedDocument], tasks: [ExportedTask]) {
        self.name = name
        self.color = color
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.documents = documents
        self.tasks = tasks
    }
}

public struct ExportedTask: Codable, Sendable {
    public var title: String
    public var details: String
    /// Raw `TaskStatus` value, e.g. "in_progress".
    public var status: String
    /// Raw `TaskPriority` value, e.g. "high".
    public var priority: String
    public var dueDate: String?
    public var sortOrder: Double
    public var createdAt: String
    public var updatedAt: String
    public var labels: [ExportedLabel]
    public var subtasks: [ExportedSubtask]
    public var activity: [ExportedActivity]
    public var documents: [ExportedDocument]

    public init(title: String, details: String, status: String, priority: String, dueDate: String?,
                sortOrder: Double, createdAt: String, updatedAt: String, labels: [ExportedLabel],
                subtasks: [ExportedSubtask], activity: [ExportedActivity], documents: [ExportedDocument]) {
        self.title = title
        self.details = details
        self.status = status
        self.priority = priority
        self.dueDate = dueDate
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.labels = labels
        self.subtasks = subtasks
        self.activity = activity
        self.documents = documents
    }
}

public struct ExportedLabel: Codable, Sendable {
    public var name: String
    public var color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

public struct ExportedSubtask: Codable, Sendable {
    public var title: String
    public var done: Bool
    public var sortOrder: Double

    public init(title: String, done: Bool, sortOrder: Double) {
        self.title = title
        self.done = done
        self.sortOrder = sortOrder
    }
}

public struct ExportedActivity: Codable, Sendable {
    /// "user" or "claude" — preserved verbatim so imported history keeps its attribution.
    public var actor: String
    /// "note", "status", "created", "field".
    public var kind: String
    public var message: String
    public var createdAt: String

    public init(actor: String, kind: String, message: String, createdAt: String) {
        self.actor = actor
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
    }
}

public struct ExportedDocument: Codable, Sendable {
    public var title: String
    /// The absolute path this document had on the exporting machine. On import,
    /// if this path still exists we link straight to the live file.
    public var originalPath: String
    /// Path of the embedded copy inside the zip, or nil if the file could not be
    /// read at export time (already deleted or moved).
    public var file: String?

    public init(title: String, originalPath: String, file: String?) {
        self.title = title
        self.originalPath = originalPath
        self.file = file
    }
}
