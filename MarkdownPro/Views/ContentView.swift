import SwiftUI
import MarkdownProCore

enum SidebarItem: Hashable {
    case stats
    case review
    case document(String)   // a markdown file path, selected in the sidebar
    case project(Int64)
}

/// User-selectable window appearance, persisted across launches.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// nil = follow the OS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var docs = DocumentsModel()
    @State private var selection: SidebarItem? = .stats
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, docs: docs)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            switch selection {
            case .stats, nil:
                StatsView()
            case .review:
                ReviewCenterView()
            case .document(let path):
                DocumentRender(docs: docs, path: path)
            case .project(let id):
                if let project = store.projects.first(where: { $0.id == id }) {
                    ProjectView(project: project)
                } else {
                    ContentUnavailableView("Project not found", systemImage: "folder.badge.questionmark")
                }
            }
        }
        .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme)
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThickMaterial))
                    .shadow(radius: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture {
                        selection = .review
                        store.toast = nil
                    }
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        store.toast = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.toast)
        .onChange(of: selection) { _, sel in
            if case .document(let path) = sel { docs.activate(path) }
        }
        .onChange(of: store.pendingReaderURL) { _, url in
            guard let url else { return }
            store.pendingReaderURL = nil
            docs.ensureFolder(for: url.path)
            selection = .document(url.path)
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

/// The detail pane for a selected document: the rendered markdown, full width,
/// nothing else. Live-reloads as `docs.markdown` changes on disk.
private struct DocumentRender: View {
    @ObservedObject var docs: DocumentsModel
    let path: String

    var body: some View {
        MarkdownWebView(markdown: docs.markdown, baseURL: docs.activeBaseURL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationSubtitle((path as NSString).deletingLastPathComponent)
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: Store
    @Binding var selection: SidebarItem?
    @ObservedObject var docs: DocumentsModel
    @State private var showNewProject = false
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue

    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .system }

    var body: some View {
        List(selection: $selection) {
            Section("Overview") {
                SwiftUI.Label("Progress", systemImage: "chart.bar.xaxis")
                    .tag(SidebarItem.stats)
                SwiftUI.Label("Review", systemImage: "text.badge.checkmark")
                    .badge(store.reviewQueue.count)
                    .tag(SidebarItem.review)
                    .accessibilityIdentifier("reviewSidebarItem")
            }
            documentsSection
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
                    .accessibilityIdentifier("projectRow-\(project.name)")
                    .contextMenu {
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
                Menu {
                    Picker("Appearance", selection: $appearanceRaw) {
                        ForEach(AppAppearance.allCases) { option in
                            SwiftUI.Label(option.label, systemImage: option.icon).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    SwiftUI.Label("Appearance", systemImage: appearance.icon)
                }
                .help("Appearance: \(appearance.label)")
                .accessibilityIdentifier("appearanceMenu")
            }
            ToolbarItem {
                Button {
                    showNewProject = true
                } label: {
                    SwiftUI.Label("New Project", systemImage: "folder.badge.plus")
                }
                .help("New Project")
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .accessibilityIdentifier("newProjectButton")
            }
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet()
        }
    }

    /// The document navigator, inlined into the sidebar. Folders disclose their
    /// markdown files; selecting a file renders it in the detail pane.
    @ViewBuilder
    private var documentsSection: some View {
        Section {
            if docs.tree.isEmpty {
                Button {
                    docs.addFolder()
                } label: {
                    SwiftUI.Label("Add Folder…", systemImage: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                OutlineGroup(docs.tree, children: \.children) { node in
                    if node.isDirectory {
                        SwiftUI.Label(node.name, systemImage: "folder")
                            .contextMenu {
                                if docs.isRoot(node.url.path) {
                                    Button("Remove Folder", role: .destructive) {
                                        docs.removeFolder(node.url.path)
                                    }
                                }
                            }
                    } else {
                        SwiftUI.Label(node.name, systemImage: "doc.text")
                            .tag(SidebarItem.document(node.url.path))
                    }
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text("Documents")
                Spacer()
                Button {
                    docs.addFolder()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Add Folder")
            }
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
                .accessibilityIdentifier("projectNameField")
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
                    .accessibilityIdentifier("createProjectButton")
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
