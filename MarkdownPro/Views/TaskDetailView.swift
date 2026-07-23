import SwiftUI
import MarkdownProCore

struct TaskDetailView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let taskId: Int64

    @State private var detail: TaskDetail?
    @State private var title = ""
    @State private var details = ""
    @State private var newSubtask = ""
    @State private var newLabel = ""
    @State private var newNote = ""

    var body: some View {
        VStack(spacing: 0) {
            if let detail {
                content(detail)
            } else {
                ContentUnavailableView("Task not found", systemImage: "questionmark.circle")
                    .frame(width: 560, height: 300)
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        detail = store.taskDetail(id: taskId)
        if let detail {
            title = detail.task.title
            details = detail.task.details
        }
    }

    private func content(_ detail: TaskDetail) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("#\(detail.task.id)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
                Button {
                    store.deleteTask(id: taskId)
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete task")
                Button("Done") { commitTextEdits(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Title", text: $title, axis: .vertical)
                        .font(.title2.bold())
                        .textFieldStyle(.plain)
                        .onSubmit(commitTextEdits)
                        .accessibilityIdentifier("taskTitleField")

                    // Metadata: status / priority / due date
                    HStack(spacing: 16) {
                        Picker("Status", selection: statusBinding(detail)) {
                            ForEach(TaskStatus.boardColumns) { s in
                                SwiftUI.Label(s.displayName, systemImage: s.iconName).tag(s)
                            }
                        }
                        .fixedSize()
                        Picker("Priority", selection: priorityBinding(detail)) {
                            ForEach(TaskPriority.allCases) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .fixedSize()
                        dueDateControl(detail)
                        Spacer()
                    }

                    // Actions: attention chip + optional Clear + right-aligned Launch
                    if let attention = detail.task.attention {
                        HStack(spacing: 12) {
                            AttentionChip(text: attention.displayName,
                                          icon: attention.iconName,
                                          color: attention.color)
                            if attention == .executing {
                                Button("Clear") {
                                    store.clearAttention(taskId: taskId)
                                    reload()
                                }
                                .controlSize(.small)
                                .help("Clear the Executing flag if the session was stopped")
                            }
                            Spacer()
                            LaunchButton(task: detail.task)
                        }
                    }

                    // Labels
                    HStack(spacing: 6) {
                        ForEach(detail.task.labels) { label in
                            LabelChip(label: label)
                                .contextMenu {
                                    Button("Remove label") {
                                        store.removeLabel(taskId: taskId, labelId: label.id)
                                        reload()
                                    }
                                }
                        }
                        TextField("+ label", text: $newLabel)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .frame(width: 80)
                            .onSubmit {
                                let name = newLabel.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                store.addLabel(taskId: taskId, name: name)
                                newLabel = ""
                                reload()
                            }
                    }

                    // Description
                    section("Description") {
                        TextEditor(text: $details)
                            .font(.body.monospaced())
                            .frame(minHeight: 80, maxHeight: 180)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                        if details != detail.task.details {
                            Button("Save description", action: commitTextEdits)
                                .controlSize(.small)
                        }
                    }

                    // Subtasks
                    section("Subtasks \(detail.subtasks.isEmpty ? "" : "· \(detail.subtasks.filter(\.done).count)/\(detail.subtasks.count)")") {
                        ForEach(detail.subtasks) { subtask in
                            HStack(spacing: 8) {
                                Button {
                                    store.setSubtaskDone(id: subtask.id, done: !subtask.done)
                                    reload()
                                } label: {
                                    Image(systemName: subtask.done ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(subtask.done ? Color.accentColor : .secondary)
                                }
                                .buttonStyle(.plain)
                                Text(subtask.title)
                                    .strikethrough(subtask.done)
                                    .foregroundStyle(subtask.done ? .secondary : .primary)
                                Spacer()
                                Button {
                                    store.deleteSubtask(id: subtask.id)
                                    reload()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        TextField("Add subtask…", text: $newSubtask)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                let text = newSubtask.trimmingCharacters(in: .whitespaces)
                                guard !text.isEmpty else { return }
                                store.addSubtask(taskId: taskId, title: text)
                                newSubtask = ""
                                reload()
                            }
                    }

                    // Linked documents
                    if !detail.documents.isEmpty {
                        section("Linked documents") {
                            ForEach(detail.documents) { doc in
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(doc.title)
                                        Text(doc.path)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    if let state = doc.state {
                                        AttentionChip(text: state.displayName,
                                                      icon: "doc.badge.ellipsis",
                                                      color: state.color)
                                    }
                                    Spacer()
                                    Button("Open in Reader") {
                                        store.openInReader(path: doc.path)
                                        dismiss()
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    // Activity
                    section("Activity") {
                        HStack(spacing: 8) {
                            TextField("Add a note…", text: $newNote)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addNote)
                            Button("Add", action: addNote)
                                .disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        ForEach(detail.activity) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: entry.actor == "claude" ? "sparkles" : "person.fill")
                                    .font(.caption)
                                    .foregroundStyle(entry.actor == "claude" ? Color.orange : Color.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.message)
                                        .font(.callout)
                                    Text("\(entry.actor == "claude" ? "Claude" : "You") · \(entry.createdAt.timeAgo)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 580, height: 640)
    }

    @ViewBuilder
    private func section(_ heading: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            body()
        }
    }

    private func statusBinding(_ detail: TaskDetail) -> Binding<TaskStatus> {
        Binding(get: { detail.task.status }, set: { newValue in
            store.updateTask(id: taskId, changes: .init(status: newValue))
            reload()
        })
    }

    private func priorityBinding(_ detail: TaskDetail) -> Binding<TaskPriority> {
        Binding(get: { detail.task.priority }, set: { newValue in
            store.updateTask(id: taskId, changes: .init(priority: newValue))
            reload()
        })
    }

    @ViewBuilder
    private func dueDateControl(_ detail: TaskDetail) -> some View {
        if let due = detail.task.dueDate {
            HStack(spacing: 4) {
                DatePicker("Due", selection: Binding(get: { due }, set: { newValue in
                    store.updateTask(id: taskId, changes: .init(dueDate: .some(DateCoding.encodeDay(newValue))))
                    reload()
                }), displayedComponents: .date)
                Button {
                    store.updateTask(id: taskId, changes: .init(dueDate: .some(nil)))
                    reload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear due date")
            }
        } else {
            Button("Set due date") {
                store.updateTask(id: taskId, changes: .init(dueDate: .some(DateCoding.encodeDay(Date()))))
                reload()
            }
            .controlSize(.small)
        }
    }

    private func commitTextEdits() {
        var changes = Repository.TaskChanges()
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        if !trimmedTitle.isEmpty, trimmedTitle != detail?.task.title {
            changes.title = trimmedTitle
        }
        if details != detail?.task.details {
            changes.details = details
        }
        if changes.title != nil || changes.details != nil {
            store.updateTask(id: taskId, changes: changes)
            reload()
        }
    }

    private func addNote() {
        let text = newNote.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        store.addNote(taskId: taskId, message: text)
        newNote = ""
        reload()
    }
}
