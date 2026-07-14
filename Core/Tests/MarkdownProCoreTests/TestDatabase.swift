import Foundation
@testable import MarkdownProCore

/// A scratch database in a temp directory, so tests never touch the real board.
final class TestDatabase {
    let directory: URL
    let repo: Repository

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdownpro-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try Database.open(path: directory.appendingPathComponent("test.sqlite").path)
        repo = Repository(db: db)
    }

    /// Writes a file into the scratch directory and returns its absolute path.
    @discardableResult
    func writeFile(named name: String, contents: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
