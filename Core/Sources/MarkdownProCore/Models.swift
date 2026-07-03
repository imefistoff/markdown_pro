import Foundation

public enum TaskStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case backlog
    case todo
    case inProgress = "in_progress"
    case done
    case canceled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .backlog: return "Backlog"
        case .todo: return "Todo"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        case .canceled: return "Canceled"
        }
    }

    /// Columns shown on the kanban board, in order.
    public static var boardColumns: [TaskStatus] {
        [.backlog, .todo, .inProgress, .done, .canceled]
    }
}

public enum TaskPriority: String, CaseIterable, Codable, Identifiable, Sendable {
    case urgent
    case high
    case medium
    case low
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "No priority"
        default: return rawValue.capitalized
        }
    }

    /// Sort weight: urgent first.
    public var weight: Int {
        switch self {
        case .urgent: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        case .none: return 4
        }
    }
}

public struct Project: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var color: String
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Aggregates for sidebar / stats.
    public var taskCount: Int
    public var doneCount: Int

    public init(id: Int64, name: String, color: String, archived: Bool,
                createdAt: Date, updatedAt: Date, taskCount: Int = 0, doneCount: Int = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.taskCount = taskCount
        self.doneCount = doneCount
    }

    /// Progress over tasks that are not canceled.
    public var progress: Double {
        taskCount > 0 ? Double(doneCount) / Double(taskCount) : 0
    }
}

public struct Label: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var color: String

    public init(id: Int64, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }
}

public struct Subtask: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var taskId: Int64
    public var title: String
    public var done: Bool
    public var sortOrder: Double

    public init(id: Int64, taskId: Int64, title: String, done: Bool, sortOrder: Double) {
        self.id = id
        self.taskId = taskId
        self.title = title
        self.done = done
        self.sortOrder = sortOrder
    }
}

public struct ActivityEntry: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var taskId: Int64
    /// "user" (the app) or "claude" (the MCP server).
    public var actor: String
    /// "note", "status", "created", "field"
    public var kind: String
    public var message: String
    public var createdAt: Date

    public init(id: Int64, taskId: Int64, actor: String, kind: String, message: String, createdAt: Date) {
        self.id = id
        self.taskId = taskId
        self.actor = actor
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
    }
}

public struct LinkedDocument: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var taskId: Int64?
    public var projectId: Int64?
    public var path: String
    public var title: String
    public var createdAt: Date

    public init(id: Int64, taskId: Int64?, projectId: Int64?, path: String, title: String, createdAt: Date) {
        self.id = id
        self.taskId = taskId
        self.projectId = projectId
        self.path = path
        self.title = title
        self.createdAt = createdAt
    }
}

/// A task row as shown on the board / list (with light-weight aggregates).
/// Named `TaskItem` to avoid clashing with Swift Concurrency's `Task`.
public struct TaskItem: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var projectId: Int64
    public var title: String
    public var details: String
    public var status: TaskStatus
    public var priority: TaskPriority
    public var dueDate: Date?
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var labels: [Label]
    public var subtaskCount: Int
    public var subtaskDoneCount: Int
    public var documentCount: Int

    public init(id: Int64, projectId: Int64, title: String, details: String,
                status: TaskStatus, priority: TaskPriority, dueDate: Date?,
                sortOrder: Double, createdAt: Date, updatedAt: Date,
                labels: [Label] = [], subtaskCount: Int = 0, subtaskDoneCount: Int = 0,
                documentCount: Int = 0) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.details = details
        self.status = status
        self.priority = priority
        self.dueDate = dueDate
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.labels = labels
        self.subtaskCount = subtaskCount
        self.subtaskDoneCount = subtaskDoneCount
        self.documentCount = documentCount
    }

    public var isOverdue: Bool {
        guard let dueDate, status != .done, status != .canceled else { return false }
        return dueDate < Calendar.current.startOfDay(for: Date())
    }
}

/// Full detail for one task (detail sheet / MCP get_task).
public struct TaskDetail: Sendable {
    public var task: TaskItem
    public var subtasks: [Subtask]
    public var activity: [ActivityEntry]
    public var documents: [LinkedDocument]

    public init(task: TaskItem, subtasks: [Subtask], activity: [ActivityEntry], documents: [LinkedDocument]) {
        self.task = task
        self.subtasks = subtasks
        self.activity = activity
        self.documents = documents
    }
}

public enum DateCoding {
    /// ISO-8601 with fractional seconds; what we store in TEXT columns.
    public static func encode(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public static func decode(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: string) { return d }
        // Plain dates like "2026-07-03" (due dates).
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: string)
    }

    /// Due dates are stored as plain "yyyy-MM-dd".
    public static func encodeDay(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}
