import SwiftUI
import AppKit

/// A node in the documents file tree.
struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    static func isDirectoryPath(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }
}

/// Owns the document navigator that now lives inside the app's main sidebar:
/// the set of watched folders, the file tree, the active file, and its live
/// markdown (reloaded when the file changes on disk).
@MainActor
final class DocumentsModel: ObservableObject {
    @Published private(set) var roots: [String] = []
    @Published private(set) var tree: [FileNode] = []
    @Published private(set) var activePath: String?
    @Published private(set) var markdown: String = ""

    private var lastModified: Date?
    private var timer: Timer?
    private let rootsKey = "readerRootsData"

    init() {
        loadRoots()
        rebuildTree()
        startWatching()
    }

    var activeBaseURL: URL? {
        activePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }

    var activeName: String? {
        activePath.map { ($0 as NSString).lastPathComponent }
    }

    // MARK: - Roots

    private func loadRoots() {
        if let data = UserDefaults.standard.data(forKey: rootsKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            roots = decoded.filter { FileManager.default.fileExists(atPath: $0) }
        }
    }

    private func saveRoots() {
        UserDefaults.standard.set((try? JSONEncoder().encode(roots)) ?? Data(), forKey: rootsKey)
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        if panel.runModal() == .OK, let url = panel.url, !roots.contains(url.path) {
            roots.append(url.path)
            saveRoots()
            rebuildTree()
        }
    }

    func removeFolder(_ path: String) {
        roots.removeAll { $0 == path }
        saveRoots()
        rebuildTree()
        if let active = activePath, active.hasPrefix(path + "/") || active == path {
            activePath = nil
            markdown = ""
        }
    }

    /// True for a root folder the user explicitly added (offers "Remove folder").
    func isRoot(_ path: String) -> Bool { roots.contains(path) }

    // MARK: - Selection

    /// Make a file active and load it (from a sidebar click or "Open in Reader").
    func activate(_ path: String) {
        guard !FileNode.isDirectoryPath(path) else { return }
        activePath = path
        markdown = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "*Could not read file.*"
        lastModified = modificationDate(path)
    }

    /// Ensure a file's folder is watched, then rebuild so it appears in the tree.
    func ensureFolder(for path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        if !roots.contains(where: { path.hasPrefix($0 + "/") || $0 == folder }) {
            roots.append(folder)
            saveRoots()
        }
        rebuildTree()
    }

    // MARK: - Tree building

    private func rebuildTree() {
        tree = roots.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return FileNode(url: URL(fileURLWithPath: path), isDirectory: true, children: scan(URL(fileURLWithPath: path), depth: 0))
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

    // MARK: - Live reload

    private func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let path = self.activePath else { return }
                let current = self.modificationDate(path)
                if current != self.lastModified {
                    self.lastModified = current
                    self.markdown = (try? String(contentsOfFile: path, encoding: .utf8)) ?? self.markdown
                }
            }
        }
    }
}
