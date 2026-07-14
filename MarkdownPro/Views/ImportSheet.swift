import SwiftUI
import MarkdownProCore

/// Shows what a `.mdproz` bundle contains and imports the chosen projects.
/// Nothing is written until the user confirms.
struct ImportSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    let preview: ImportPreview
    let url: URL

    @State private var selected: Set<Int>

    init(preview: ImportPreview, url: URL) {
        self.preview = preview
        self.url = url
        // Everything is checked by default — you picked this file on purpose.
        _selected = State(initialValue: Set(preview.projects.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Projects")
                    .font(.headline)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            List {
                ForEach(preview.projects) { project in
                    Toggle(isOn: binding(for: project.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                            Text(summary(for: project))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(alignment: .center) {
                Text("Imported projects are added to the board. Nothing existing is changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: performImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 420)
    }

    private func binding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func performImport() {
        let indices = preview.projects.map(\.id).filter { selected.contains($0) }
        store.finishImport(url: url, selecting: indices)
        dismiss()
    }

    private func summary(for project: ImportPreviewProject) -> String {
        var parts = ["\(project.taskCount) task\(project.taskCount == 1 ? "" : "s")"]
        if project.relinkCount > 0 {
            parts.append("\(project.relinkCount) document\(project.relinkCount == 1 ? "" : "s") linked to existing files")
        }
        if project.restoreCount > 0 {
            parts.append("\(project.restoreCount) document\(project.restoreCount == 1 ? "" : "s") restored from the export")
        }
        return parts.joined(separator: " · ")
    }
}
