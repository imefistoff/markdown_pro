import Foundation

public enum ImportError: Error, CustomStringConvertible {
    case missingManifest
    case unsupportedFormatVersion(Int)

    public var description: String {
        switch self {
        case .missingManifest:
            return "This file is not a MarkdownPro export — it has no manifest."
        case .unsupportedFormatVersion(let version):
            return "This export was made by a newer version of MarkdownPro (format \(version))."
        }
    }
}

public struct ImportPreviewProject: Identifiable, Sendable {
    /// Index into `ImportPreview.bundle.projects` — what `import(_:selecting:…)` takes.
    public let id: Int
    public let name: String
    public let taskCount: Int
    public let documentCount: Int
    /// Documents whose `originalPath` still exists here, so they link to the live file.
    public let relinkCount: Int
    /// Documents that will be restored from the copy embedded in the bundle.
    public let restoreCount: Int
}

public struct ImportPreview: Sendable {
    public let bundle: ExportBundle
    public let projects: [ImportPreviewProject]
}

/// Reads a `.mdproz` bundle and adds its projects to the board.
///
/// Import is purely additive: a project whose name is already taken is created
/// under a new name, never merged into the existing one.
public enum ProjectImporter {

    public static func defaultDocumentsDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("MarkdownPro", isDirectory: true)
            .appendingPathComponent("Imported", isDirectory: true)
    }

    // MARK: - Preview

    /// Parses and validates a bundle without writing anything.
    public static func preview(_ data: Data) throws -> ImportPreview {
        let bundle = try decode(data).bundle

        let projects = bundle.projects.enumerated().map { index, project -> ImportPreviewProject in
            let documents = project.documents + project.tasks.flatMap(\.documents)
            let relink = documents.filter { FileManager.default.fileExists(atPath: $0.originalPath) }.count
            let restore = documents.filter {
                !FileManager.default.fileExists(atPath: $0.originalPath) && $0.file != nil
            }.count
            return ImportPreviewProject(id: index,
                                        name: project.name,
                                        taskCount: project.tasks.count,
                                        documentCount: documents.count,
                                        relinkCount: relink,
                                        restoreCount: restore)
        }

        return ImportPreview(bundle: bundle, projects: projects)
    }

    // MARK: - Import

    @discardableResult
    public static func `import`(_ data: Data,
                                selecting indices: [Int],
                                repo: Repository,
                                documentsDirectory: URL = ProjectImporter.defaultDocumentsDirectory()) throws -> [Int64] {
        let (bundle, entries) = try decode(data)
        var newIds: [Int64] = []

        for index in indices {
            guard bundle.projects.indices.contains(index) else { continue }
            let project = bundle.projects[index]
            let name = try repo.availableProjectName(project.name)
            let directory = documentsDirectory.appendingPathComponent(safeDirectoryName(name), isDirectory: true)

            let id = try repo.insertImportedProject(project, name: name) { document in
                resolvePath(for: document, entries: entries, directory: directory)
            }
            newIds.append(id)
        }

        return newIds
    }

    /// Where an imported document should point:
    /// 1. the original path, if that file still exists here — so importing a project
    ///    back onto the machine that produced it reconnects to the live file;
    /// 2. otherwise a copy restored from the bundle;
    /// 3. otherwise nowhere (nil) — no embedded copy and no original file.
    private static func resolvePath(for document: ExportedDocument,
                                    entries: [String: Data],
                                    directory: URL) -> String? {
        if FileManager.default.fileExists(atPath: document.originalPath) {
            return document.originalPath
        }
        guard let entryName = document.file, let contents = entries[entryName] else {
            return nil
        }

        let fileName = (entryName as NSString).lastPathComponent
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName)
            try contents.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    // MARK: - Decoding

    private static func decode(_ data: Data) throws -> (bundle: ExportBundle, entries: [String: Data]) {
        let entries = try Zip.read(data)
        guard let manifest = entries.first(where: { $0.name == ExportBundle.manifestEntryName }) else {
            throw ImportError.missingManifest
        }

        let bundle: ExportBundle
        do {
            bundle = try JSONDecoder().decode(ExportBundle.self, from: manifest.data)
        } catch {
            throw ImportError.missingManifest
        }

        guard bundle.formatVersion <= ExportBundle.currentFormatVersion else {
            throw ImportError.unsupportedFormatVersion(bundle.formatVersion)
        }

        var byName: [String: Data] = [:]
        for entry in entries { byName[entry.name] = entry.data }
        return (bundle, byName)
    }

    private static func safeDirectoryName(_ name: String) -> String {
        let safe = String(name.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == " "
                ? character : "-"
        })
        let trimmed = safe.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Imported" : trimmed
    }
}
