import SwiftUI
import AppKit
import MarkdownProCore

/// A node in the documents file tree.
struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct ReaderView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("readerRootsData") private var rootsData = Data()

    @State private var tree: [FileNode] = []
    @State private var selectedPath: String?
    @State private var markdown: String = ""
    @State private var lastModified: Date?
    @State private var reloadTimer: Timer?

    private var roots: [String] {
        (try? JSONDecoder().decode([String].self, from: rootsData)) ?? []
    }

    private func setRoots(_ newRoots: [String]) {
        rootsData = (try? JSONEncoder().encode(newRoots)) ?? Data()
        rebuildTree()
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 380)
            viewer
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            rebuildTree()
            startWatching()
            consumePendingURL()
        }
        .onDisappear {
            reloadTimer?.invalidate()
            reloadTimer = nil
        }
        .onChange(of: store.pendingReaderURL) { _, _ in
            consumePendingURL()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedPath) {
                ForEach(tree) { root in
                    Section(root.name) {
                        OutlineGroup(root.children ?? [], children: \.children) { node in
                            SwiftUI.Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
                                .tag(node.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedPath) { _, path in
                loadSelected(path)
            }
            Divider()
            HStack {
                Button {
                    addFolder()
                } label: {
                    SwiftUI.Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                if !roots.isEmpty {
                    Menu {
                        ForEach(roots, id: \.self) { root in
                            Button("Remove \((root as NSString).lastPathComponent)") {
                                setRoots(roots.filter { $0 != root })
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var viewer: some View {
        if selectedPath != nil {
            MarkdownWebView(markdown: markdown,
                            baseURL: selectedPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
        } else {
            ContentUnavailableView {
                SwiftUI.Label("No document selected", systemImage: "doc.richtext")
            } description: {
                Text(roots.isEmpty
                     ? "Add a folder with markdown files — for example where Claude writes its reports."
                     : "Pick a markdown file from the list.")
            } actions: {
                Button("Add Folder") { addFolder() }
            }
        }
    }

    // MARK: - Actions

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        if panel.runModal() == .OK, let url = panel.url {
            var updated = roots
            if !updated.contains(url.path) {
                updated.append(url.path)
                setRoots(updated)
            }
        }
    }

    private func consumePendingURL() {
        guard let url = store.pendingReaderURL else { return }
        store.pendingReaderURL = nil
        // Make sure the file's folder is available in the tree.
        let folder = url.deletingLastPathComponent().path
        if !roots.contains(where: { url.path.hasPrefix($0 + "/") || $0 == folder }) {
            setRoots(roots + [folder])
        } else {
            rebuildTree()
        }
        selectedPath = url.path
        loadSelected(url.path)
    }

    // MARK: - Tree building

    private func rebuildTree() {
        tree = roots.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return FileNode(url: url, isDirectory: true, children: scan(url, depth: 0))
        }
    }

    /// Recursively collects .md files (and directories that contain them).
    private func scan(_ directory: URL, depth: Int) -> [FileNode] {
        guard depth < 6 else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        var nodes: [FileNode] = []
        for url in contents.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                let children = scan(url, depth: depth + 1)
                if !children.isEmpty {
                    nodes.append(FileNode(url: url, isDirectory: true, children: children))
                }
            } else if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                nodes.append(FileNode(url: url, isDirectory: false, children: nil))
            }
        }
        // Files before folders reads better in a docs tree.
        return nodes.sorted { !$0.isDirectory && $1.isDirectory }
    }

    // MARK: - Loading & live reload

    private func loadSelected(_ path: String?) {
        guard let path, !FileNode.isDirectoryPath(path) else { return }
        markdown = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "*Could not read file.*"
        lastModified = modificationDate(path)
    }

    private func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Polls the selected file once a second; reloads when Claude rewrites it.
    private func startWatching() {
        reloadTimer?.invalidate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard let path = selectedPath else { return }
                let current = modificationDate(path)
                if current != lastModified {
                    loadSelected(path)
                }
            }
        }
    }
}

extension FileNode {
    static func isDirectoryPath(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }
}
