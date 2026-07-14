import SwiftUI
import AppKit
import MarkdownProCore

/// Pick projects, then write a `.mdproz` bundle.
/// Archived projects are listed but start unchecked.
struct ExportSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<Int64>
    @State private var projects: [Project] = []

    init(preselected: Set<Int64>) {
        _selected = State(initialValue: preselected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export Projects")
                .font(.headline)
                .padding(16)

            Divider()

            if projects.isEmpty {
                Text("There are no projects to export.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(projects) { project in
                        Toggle(isOn: binding(for: project.id)) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(hex: project.color))
                                    .frame(width: 9, height: 9)
                                Text(project.name)
                                    .lineLimit(1)
                                if project.archived {
                                    Text("Archived")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(project.taskCount) task\(project.taskCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button("Select All") { selected = Set(projects.map(\.id)) }
                Button("Select None") { selected.removeAll() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
        .onAppear { projects = store.allProjectsIncludingArchived() }
    }

    private func binding(for id: Int64) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFileName()
        panel.canCreateDirectories = true
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Export in the order the board shows them, not in click order.
        let ids = projects.map(\.id).filter { selected.contains($0) }
        store.exportProjects(ids: ids, to: url)
        dismiss()
    }

    private func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "MarkdownPro Export \(formatter.string(from: Date())).mdproz"
    }
}
