import SwiftUI
import MarkdownProCore

enum SidebarItem: Hashable {
    case stats
    case docs
    case project(Int64)
}

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @State private var selection: SidebarItem? = .stats

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            switch selection {
            case .stats, nil:
                StatsView()
            case .docs:
                ReaderView()
            case .project(let id):
                if let project = store.projects.first(where: { $0.id == id }) {
                    ProjectView(project: project)
                } else {
                    ContentUnavailableView("Project not found", systemImage: "folder.badge.questionmark")
                }
            }
        }
        .onChange(of: store.pendingReaderURL) { _, url in
            if url != nil { selection = .docs }
        }
        .sheet(item: $store.activeSheet) { sheet in
            switch sheet {
            case .export(let preselected):
                ExportSheet(preselected: preselected)
                    .environmentObject(store)
            case .importBundle(let preview, let url):
                ImportSheet(preview: preview, url: url)
                    .environmentObject(store)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: Store
    @Binding var selection: SidebarItem?
    @State private var showNewProject = false

    var body: some View {
        List(selection: $selection) {
            Section("Overview") {
                SwiftUI.Label("Progress", systemImage: "chart.bar.xaxis")
                    .tag(SidebarItem.stats)
                SwiftUI.Label("Documents", systemImage: "doc.richtext")
                    .tag(SidebarItem.docs)
            }
            Section("Projects") {
                ForEach(store.projects) { project in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: project.color))
                            .frame(width: 9, height: 9)
                        Text(project.name)
                            .lineLimit(1)
                        Spacer()
                        if project.taskCount > 0 {
                            Text("\(Int((project.progress * 100).rounded()))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .tag(SidebarItem.project(project.id))
                    .contextMenu {
                        Button("Export…") {
                            store.activeSheet = .export(preselected: [project.id])
                        }
                        Divider()
                        Button("Delete Project", role: .destructive) {
                            if case .project(project.id) = selection { selection = .stats }
                            store.deleteProject(id: project.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    showNewProject = true
                } label: {
                    SwiftUI.Label("New Project", systemImage: "folder.badge.plus")
                }
                .help("New Project")
            }
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet()
        }
    }
}

struct NewProjectSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = "#5E6AD2"

    private let palette = ["#5E6AD2", "#26B5CE", "#4CB782", "#F2C94C", "#F2994A", "#EB5757", "#BB87FC"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(.headline)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack(spacing: 8) {
                ForEach(palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 20, height: 20)
                        .overlay {
                            if hex == color {
                                Circle().strokeBorder(.primary, lineWidth: 2)
                            }
                        }
                        .onTapGesture { color = hex }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.createProject(name: trimmed, color: color)
        dismiss()
    }
}
