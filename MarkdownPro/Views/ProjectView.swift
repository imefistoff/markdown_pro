import SwiftUI
import UniformTypeIdentifiers
import MarkdownProCore

struct ProjectView: View {
    @EnvironmentObject private var store: Store
    let project: Project

    @AppStorage("projectViewMode") private var viewMode = "board"
    @State private var showNewTask = false
    @State private var selectedTask: TaskItem?
    @State private var filterLabel: String?

    private var tasks: [TaskItem] {
        var result = store.tasks(projectId: project.id)
        if let filterLabel {
            result = result.filter { task in task.labels.contains { $0.name == filterLabel } }
        }
        return result
    }

    private var projectLabels: [String] {
        Array(Set(store.tasks(projectId: project.id).flatMap { $0.labels.map(\.name) })).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewMode == "board" {
                BoardView(tasks: tasks, onSelect: { selectedTask = $0 })
            } else {
                TaskListView(tasks: tasks, onSelect: { selectedTask = $0 })
            }
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItemGroup {
                if !projectLabels.isEmpty {
                    Menu {
                        Button("All labels") { filterLabel = nil }
                        Divider()
                        ForEach(projectLabels, id: \.self) { name in
                            Button(name) { filterLabel = name }
                        }
                    } label: {
                        SwiftUI.Label(filterLabel ?? "Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                Picker("View", selection: $viewMode) {
                    Image(systemName: "square.grid.3x1.below.line.grid.1x2").tag("board")
                    Image(systemName: "list.bullet").tag("list")
                }
                .pickerStyle(.segmented)
                Button {
                    showNewTask = true
                } label: {
                    SwiftUI.Label("New Task", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showNewTask) {
            NewTaskSheet(projectId: project.id)
        }
        .sheet(item: $selectedTask) { task in
            TaskDetailView(taskId: task.id)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: project.color))
                .frame(width: 10, height: 10)
            Text(project.name)
                .font(.title3.bold())
            ProgressView(value: project.progress)
                .frame(maxWidth: 160)
            Text("\(project.doneCount)/\(project.taskCount) done")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Kanban board

struct BoardView: View {
    @EnvironmentObject private var store: Store
    let tasks: [TaskItem]
    let onSelect: (TaskItem) -> Void

    /// Set synchronously when a drag starts so drops can apply without
    /// waiting for the async NSItemProvider round-trip.
    @State private var draggingTaskId: Int64?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(TaskStatus.boardColumns) { status in
                    BoardColumn(status: status,
                                tasks: tasks.filter { $0.status == status },
                                draggingTaskId: $draggingTaskId,
                                onSelect: onSelect)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct BoardColumn: View {
    @EnvironmentObject private var store: Store
    let status: TaskStatus
    let tasks: [TaskItem]
    @Binding var draggingTaskId: Int64?
    let onSelect: (TaskItem) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: status.iconName)
                    .foregroundStyle(status.color)
                Text(status.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("\(tasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCardView(task: task)
                            .onTapGesture { onSelect(task) }
                            .onDrag {
                                draggingTaskId = task.id
                                return NSItemProvider(object: NSString(string: "\(task.id)"))
                            }
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(8)
        .frame(width: 264)
        .accessibilityIdentifier("column-\(status.rawValue)")
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035))
        )
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            // Fast path: the id captured at drag start lets the move apply
            // in the same frame as the drop — no async decode, no flicker.
            if let id = draggingTaskId {
                draggingTaskId = nil
                withAnimation(.easeInOut(duration: 0.15)) {
                    store.moveTask(id: id, to: status)
                }
                return true
            }
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? NSString, let id = Int64(string as String) else { return }
                Task { @MainActor in
                    store.moveTask(id: id, to: status)
                }
            }
            return true
        }
    }
}

struct TaskCardView: View {
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: task.priority.iconName)
                    .font(.caption)
                    .foregroundStyle(task.priority.color)
                Text(task.title)
                    .font(.callout)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            if let attention = task.attention {
                AttentionChip(text: attention.displayName,
                              icon: attention.iconName,
                              color: attention.color)
            }
            LaunchButton(task: task)
            if !task.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(task.labels.prefix(3)) { label in
                        LabelChip(label: label)
                    }
                    if task.labels.count > 3 {
                        Text("+\(task.labels.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                if task.subtaskCount > 0 {
                    SwiftUI.Label("\(task.subtaskDoneCount)/\(task.subtaskCount)", systemImage: "checklist")
                        .font(.caption2)
                        .foregroundStyle(task.subtaskDoneCount == task.subtaskCount ? .green : .secondary)
                }
                if task.documentCount > 0 {
                    SwiftUI.Label("\(task.documentCount)", systemImage: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let due = task.dueDate {
                    SwiftUI.Label(due.shortFormatted, systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(task.isOverdue ? .red : .secondary)
                }
                Spacer()
                Text("#\(task.id)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("taskCard-\(task.title)")
    }
}

// MARK: - List mode

struct TaskListView: View {
    @EnvironmentObject private var store: Store
    let tasks: [TaskItem]
    let onSelect: (TaskItem) -> Void

    var body: some View {
        List {
            ForEach(TaskStatus.boardColumns) { status in
                let items = tasks.filter { $0.status == status }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { task in
                            TaskRow(task: task)
                                .contentShape(Rectangle())
                                .onTapGesture { onSelect(task) }
                                .contextMenu {
                                    ForEach(TaskStatus.boardColumns) { target in
                                        Button("Move to \(target.displayName)") {
                                            store.moveTask(id: task.id, to: target)
                                        }
                                        .disabled(target == task.status)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        store.deleteTask(id: task.id)
                                    }
                                }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: status.iconName)
                                .foregroundStyle(status.color)
                            Text("\(status.displayName) · \(items.count)")
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.priority.iconName)
                .font(.caption)
                .foregroundStyle(task.priority.color)
                .frame(width: 16)
            Text(task.title)
                .lineLimit(1)
            ForEach(task.labels.prefix(3)) { label in
                LabelChip(label: label)
            }
            Spacer()
            if task.subtaskCount > 0 {
                Text("\(task.subtaskDoneCount)/\(task.subtaskCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let due = task.dueDate {
                Text(due.shortFormatted)
                    .font(.caption)
                    .foregroundStyle(task.isOverdue ? .red : .secondary)
            }
            Text(task.updatedAt.timeAgo)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - New task

struct NewTaskSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let projectId: Int64

    @State private var title = ""
    @State private var details = ""
    @State private var status: TaskStatus = .todo
    @State private var priority: TaskPriority = .none
    @State private var hasDueDate = false
    @State private var dueDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Task")
                .font(.headline)
            TextField("Task title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            TextEditor(text: $details)
                .font(.body)
                .frame(height: 90)
                .overlay(alignment: .topLeading) {
                    if details.isEmpty {
                        Text("Description (markdown)")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack(spacing: 14) {
                Picker("Status", selection: $status) {
                    ForEach(TaskStatus.boardColumns) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .fixedSize()
                Picker("Priority", selection: $priority) {
                    ForEach(TaskPriority.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .fixedSize()
            }
            HStack {
                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("", selection: $dueDate, displayedComponents: .date)
                        .labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Task", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func create() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.createTask(projectId: projectId, title: trimmed, details: details,
                         status: status, priority: priority,
                         dueDate: hasDueDate ? dueDate : nil)
        dismiss()
    }
}
