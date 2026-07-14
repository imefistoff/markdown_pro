import XCTest
import Foundation
@testable import MarkdownProCore

final class ZipTests: XCTestCase {

    func testRoundTripPreservesEntries() throws {
        let entries = [
            ZipEntry(name: "manifest.json", data: Data(#"{"formatVersion":1}"#.utf8)),
            ZipEntry(name: "documents/0001-spec.md", data: Data("# Spec\n\nHello — ünïcode.\n".utf8))
        ]
        let archive = Zip.archive(entries)
        let read = try Zip.read(archive)

        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read.map(\.name).sorted(), ["documents/0001-spec.md", "manifest.json"])
        for original in entries {
            let match = read.first { $0.name == original.name }
            XCTAssertEqual(match?.data, original.data, "entry \(original.name) round-tripped unequal")
        }
    }

    func testEmptyEntryRoundTrips() throws {
        let archive = Zip.archive([ZipEntry(name: "empty.md", data: Data())])
        let read = try Zip.read(archive)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].data, Data())
    }

    /// The archive must be a real zip, not just something we can read back.
    func testArchiveIsAcceptedBySystemUnzip() throws {
        let archive = Zip.archive([
            ZipEntry(name: "manifest.json", data: Data(#"{"formatVersion":1}"#.utf8)),
            ZipEntry(name: "documents/0001-spec.md", data: Data("# Spec\n".utf8))
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-test-\(UUID().uuidString).zip")
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "/usr/bin/unzip -t rejected our archive")
    }

    func testReadRejectsNonZipData() {
        XCTAssertThrowsError(try Zip.read(Data("not a zip file at all".utf8)))
    }
}
