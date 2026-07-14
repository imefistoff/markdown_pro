# Project Export / Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user export selected projects — with tasks, subtasks, labels, activity history and attached markdown documents — to a single `.mdproz` file, and import such a file back as new projects.

**Architecture:** All the real work lives in `MarkdownProCore`: a dependency-free store-only zip reader/writer, a `Codable` manifest, an exporter and an importer. The app layer is two SwiftUI sheets plus a `.commands` block. Import is purely additive — it never merges into an existing project.

**Tech Stack:** Swift 5.9, SwiftUI (macOS 14+), raw SQLite via `import SQLite3`, XCTest. **No external Swift dependencies anywhere** — the zip format is implemented by hand.

Spec: `docs/superpowers/specs/2026-07-14-project-export-import-design.md`

## Global Constraints

- **No external Swift package dependencies.** Not in `Core/Package.swift`, not in `mcp-server/Package.swift`, not in the Xcode project. Zip is hand-rolled; no shelling out to `/usr/bin/zip`.
- **`Label` is ambiguous** between SwiftUI and MarkdownProCore — always qualify: `MarkdownProCore.Label` for the model, `SwiftUI.Label` for the view.
- The task model is **`TaskItem`**, never `Task` (clashes with Swift Concurrency).
- Dates are TEXT columns: `DateCoding.encode` (ISO-8601 with fractional seconds) for timestamps, `DateCoding.encodeDay` (`yyyy-MM-dd`) for due dates.
- **`SQLiteConnection.transaction` is NOT reentrant** — it issues `BEGIN IMMEDIATE`, which fails inside an open transaction. Code called from inside a `db.transaction { }` block must not itself call `db.transaction`. Specifically: `Repository.createTask` and `Repository.createProject` must NOT be called from the importer. `Repository.addLabel` and `Repository.logActivity` are transaction-free and safe to reuse.
- Every meaningful mutation goes through `Repository`. Do not add a second write path to SQLite.
- No schema change is required by this feature. `PRAGMA user_version` stays at 1.
- Tests point `MARKDOWNPRO_DB` at a temp file, or pass an explicit path to `Database.open(path:)`, so the real board is never touched.

---

### Task 1: Store-only zip reader/writer in Core

The one piece of genuinely new machinery. A zip archive with *stored* (uncompressed) entries: local file headers, a central directory, an end-of-central-directory record, and a CRC32 per entry. It must produce an archive that `/usr/bin/unzip` accepts.

**Files:**
- Create: `Core/Sources/MarkdownProCore/Zip.swift`
- Modify: `Core/Package.swift`
- Create: `Core/Tests/MarkdownProCoreTests/ZipTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct ZipEntry { public let name: String; public let data: Data; public init(name: String, data: Data) }`
  - `public enum Zip { public static func archive(_ entries: [ZipEntry]) -> Data; public static func read(_ data: Data) throws -> [ZipEntry] }`
  - `public enum ZipError: Error, CustomStringConvertible { case malformed(String); case unsupported(String) }`

- [ ] **Step 1: Add the test target to the package**

`Core/Package.swift` has no test target today. Replace the `targets:` array:

```swift
    targets: [
        .target(name: "MarkdownProCore"),
        .testTarget(name: "MarkdownProCoreTests", dependencies: ["MarkdownProCore"])
    ]
```

- [ ] **Step 2: Write the failing tests**

Create `Core/Tests/MarkdownProCoreTests/ZipTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd Core && swift test --filter ZipTests`
Expected: FAIL — `cannot find 'ZipEntry' in scope` / `cannot find 'Zip' in scope`.

- [ ] **Step 4: Implement Zip.swift**

Create `Core/Sources/MarkdownProCore/Zip.swift`:

```swift
import Foundation

public struct ZipEntry: Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public enum ZipError: Error, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .malformed(let m): return "Malformed zip archive: \(m)"
        case .unsupported(let m): return "Unsupported zip archive: \(m)"
        }
    }
}

/// A minimal zip reader/writer supporting only *stored* (uncompressed) entries.
/// That is all MarkdownPro export bundles use, and it keeps Core dependency-free.
/// Not supported, and rejected on read: compression, encryption, zip64,
/// data descriptors, multi-disk archives.
public enum Zip {

    // MARK: - Writing

    public static func archive(_ entries: [ZipEntry]) -> Data {
        var output = Data()
        var directory = Data()
        var count: UInt16 = 0

        for entry in entries {
            let name = Array(entry.name.utf8)
            let bytes = [UInt8](entry.data)
            let crc = crc32(bytes)
            let size = UInt32(bytes.count)
            let offset = UInt32(output.count)

            // Local file header.
            output.append(uint32: 0x0403_4b50)
            output.append(uint16: 20)            // version needed
            output.append(uint16: 0)             // flags
            output.append(uint16: 0)             // method: stored
            output.append(uint16: dosTime)
            output.append(uint16: dosDate)
            output.append(uint32: crc)
            output.append(uint32: size)          // compressed size == uncompressed
            output.append(uint32: size)
            output.append(uint16: UInt16(name.count))
            output.append(uint16: 0)             // extra field length
            output.append(contentsOf: name)
            output.append(contentsOf: bytes)

            // Central directory header.
            directory.append(uint32: 0x0201_4b50)
            directory.append(uint16: 20)         // version made by
            directory.append(uint16: 20)         // version needed
            directory.append(uint16: 0)          // flags
            directory.append(uint16: 0)          // method: stored
            directory.append(uint16: dosTime)
            directory.append(uint16: dosDate)
            directory.append(uint32: crc)
            directory.append(uint32: size)
            directory.append(uint32: size)
            directory.append(uint16: UInt16(name.count))
            directory.append(uint16: 0)          // extra field length
            directory.append(uint16: 0)          // comment length
            directory.append(uint16: 0)          // disk number start
            directory.append(uint16: 0)          // internal attributes
            directory.append(uint32: 0)          // external attributes
            directory.append(uint32: offset)     // local header offset
            directory.append(contentsOf: name)

            count += 1
        }

        let directoryOffset = UInt32(output.count)
        let directorySize = UInt32(directory.count)
        output.append(directory)

        // End of central directory record.
        output.append(uint32: 0x0605_4b50)
        output.append(uint16: 0)                 // this disk
        output.append(uint16: 0)                 // disk with central directory
        output.append(uint16: count)             // entries on this disk
        output.append(uint16: count)             // entries total
        output.append(uint32: directorySize)
        output.append(uint32: directoryOffset)
        output.append(uint16: 0)                 // comment length

        return output
    }

    // MARK: - Reading

    public static func read(_ data: Data) throws -> [ZipEntry] {
        let bytes = [UInt8](data)
        let eocd = try findEndOfCentralDirectory(bytes)

        let entryCount = Int(bytes.uint16(at: eocd + 10))
        var cursor = Int(bytes.uint32(at: eocd + 16))   // central directory offset
        var entries: [ZipEntry] = []

        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count, bytes.uint32(at: cursor) == 0x0201_4b50 else {
                throw ZipError.malformed("bad central directory header")
            }
            let method = bytes.uint16(at: cursor + 10)
            guard method == 0 else {
                throw ZipError.unsupported("compression method \(method); only stored entries are supported")
            }
            let size = Int(bytes.uint32(at: cursor + 24))
            let nameLength = Int(bytes.uint16(at: cursor + 28))
            let extraLength = Int(bytes.uint16(at: cursor + 30))
            let commentLength = Int(bytes.uint16(at: cursor + 32))
            let localOffset = Int(bytes.uint32(at: cursor + 42))

            guard cursor + 46 + nameLength <= bytes.count else {
                throw ZipError.malformed("truncated central directory entry name")
            }
            let nameBytes = Array(bytes[(cursor + 46)..<(cursor + 46 + nameLength)])
            guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw ZipError.malformed("entry name is not valid UTF-8")
            }

            // The local header repeats the name/extra lengths, and its extra field
            // may differ from the central one, so read the data offset from there.
            guard localOffset + 30 <= bytes.count, bytes.uint32(at: localOffset) == 0x0403_4b50 else {
                throw ZipError.malformed("bad local header for \(name)")
            }
            let localNameLength = Int(bytes.uint16(at: localOffset + 26))
            let localExtraLength = Int(bytes.uint16(at: localOffset + 28))
            let start = localOffset + 30 + localNameLength + localExtraLength
            guard start + size <= bytes.count else {
                throw ZipError.malformed("truncated data for \(name)")
            }

            entries.append(ZipEntry(name: name, data: Data(bytes[start..<(start + size)])))
            cursor += 46 + nameLength + extraLength + commentLength
        }

        return entries
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 22 else { throw ZipError.malformed("file is too short to be a zip") }
        // Scan backwards; the record is 22 bytes plus a trailing comment (we write none).
        var index = bytes.count - 22
        while index >= 0 {
            if bytes.uint32(at: index) == 0x0605_4b50 { return index }
            index -= 1
        }
        throw ZipError.malformed("no end-of-central-directory record found")
    }

    // MARK: - Bits and pieces

    /// A fixed DOS timestamp (1980-01-01 00:00). Export bundles are content-addressed
    /// by the manifest, so per-entry mtimes carry no information and a constant keeps
    /// archives byte-reproducible.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x0021

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 == 1) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}

private extension Array where Element == UInt8 {
    func uint16(at index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= count else { return 0 }
        return UInt16(self[index]) | (UInt16(self[index + 1]) << 8)
    }

    func uint32(at index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= count else { return 0 }
        return UInt32(self[index])
            | (UInt32(self[index + 1]) << 8)
            | (UInt32(self[index + 2]) << 16)
            | (UInt32(self[index + 3]) << 24)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Core && swift test --filter ZipTests`
Expected: PASS — 4 tests, including `/usr/bin/unzip -t` accepting the archive.

- [ ] **Step 6: Commit**

```bash
git add Core/Package.swift Core/Sources/MarkdownProCore/Zip.swift Core/Tests/MarkdownProCoreTests/ZipTests.swift
git commit -m "Add dependency-free store-only zip reader/writer to Core"
```

---

### Task 2: The export bundle manifest

Pure `Codable` data types describing `manifest.json`. No behavior, no I/O.

**Files:**
- Create: `Core/Sources/MarkdownProCore/ExportBundle.swift`
- Create: `Core/Tests/MarkdownProCoreTests/ExportBundleTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (all `public struct`, all `Codable`, `Sendable`):
  - `ExportBundle` — `formatVersion: Int`, `exportedAt: String`, `projects: [ExportedProject]`; plus `public static let currentFormatVersion = 1`, `public static let manifestEntryName = "manifest.json"`.
  - `ExportedProject` — `name: String`, `color: String`, `archived: Bool`, `createdAt: String`, `updatedAt: String`, `documents: [ExportedDocument]`, `tasks: [ExportedTask]`.
  - `ExportedTask` — `title: String`, `details: String`, `status: String`, `priority: String`, `dueDate: String?`, `sortOrder: Double`, `createdAt: String`, `updatedAt: String`, `labels: [ExportedLabel]`, `subtasks: [ExportedSubtask]`, `activity: [ExportedActivity]`, `documents: [ExportedDocument]`.
  - `ExportedLabel` — `name: String`, `color: String`.
  - `ExportedSubtask` — `title: String`, `done: Bool`, `sortOrder: Double`.
  - `ExportedActivity` — `actor: String`, `kind: String`, `message: String`, `createdAt: String`.
  - `ExportedDocument` — `title: String`, `originalPath: String`, `file: String?`.

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/MarkdownProCoreTests/ExportBundleTests.swift`:

```swift
import XCTest
@testable import MarkdownProCore

final class ExportBundleTests: XCTestCase {

    func testBundleRoundTripsThroughJSON() throws {
        let bundle = ExportBundle(
            formatVersion: ExportBundle.currentFormatVersion,
            exportedAt: "2026-07-14T10:00:00.000Z",
            projects: [
                ExportedProject(
                    name: "MarkdownPro",
                    color: "#5E6AD2",
                    archived: false,
                    createdAt: "2026-06-01T09:00:00.000Z",
                    updatedAt: "2026-07-14T08:00:00.000Z",
                    documents: [
                        ExportedDocument(title: "Roadmap", originalPath: "/tmp/roadmap.md", file: "documents/0001-roadmap.md")
                    ],
                    tasks: [
                        ExportedTask(
                            title: "Add export",
                            details: "…",
                            status: "in_progress",
                            priority: "high",
                            dueDate: "2026-07-20",
                            sortOrder: 3,
                            createdAt: "2026-07-01T11:00:00.000Z",
                            updatedAt: "2026-07-13T16:00:00.000Z",
                            labels: [ExportedLabel(name: "feature", color: "#8B5CF6")],
                            subtasks: [ExportedSubtask(title: "Zip writer", done: true, sortOrder: 1)],
                            activity: [ExportedActivity(actor: "claude", kind: "status",
                                                        message: "moved from Todo to In Progress",
                                                        createdAt: "2026-07-02T12:00:00.000Z")],
                            documents: [ExportedDocument(title: "Spec", originalPath: "/tmp/spec.md", file: nil)]
                        )
                    ]
                )
            ]
        )

        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(ExportBundle.self, from: data)

        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(decoded.projects.count, 1)
        let project = try XCTUnwrap(decoded.projects.first)
        XCTAssertEqual(project.name, "MarkdownPro")
        XCTAssertEqual(project.documents.first?.file, "documents/0001-roadmap.md")

        let task = try XCTUnwrap(project.tasks.first)
        XCTAssertEqual(task.status, "in_progress")
        XCTAssertEqual(task.dueDate, "2026-07-20")
        XCTAssertEqual(task.labels.first?.name, "feature")
        XCTAssertEqual(task.subtasks.first?.done, true)
        XCTAssertEqual(task.activity.first?.actor, "claude")
        XCTAssertNil(task.documents.first?.file, "a missing file must survive as null")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Core && swift test --filter ExportBundleTests`
Expected: FAIL — `cannot find 'ExportBundle' in scope`.

- [ ] **Step 3: Implement ExportBundle.swift**

Create `Core/Sources/MarkdownProCore/ExportBundle.swift`:

```swift
import Foundation

/// The `manifest.json` inside a `.mdproz` export bundle.
///
/// Deliberately carries **no database IDs** — row ids are meaningless on another
/// machine. Relationships are expressed by nesting: subtasks inside their task,
/// tasks inside their project.
///
/// All timestamps are strings in `DateCoding` form (ISO-8601 with fractional
/// seconds); `dueDate` is a plain `yyyy-MM-dd`, matching how they are stored.
public struct ExportBundle: Codable, Sendable {
    public static let currentFormatVersion = 1
    public static let manifestEntryName = "manifest.json"

    public var formatVersion: Int
    public var exportedAt: String
    public var projects: [ExportedProject]

    public init(formatVersion: Int, exportedAt: String, projects: [ExportedProject]) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.projects = projects
    }
}

public struct ExportedProject: Codable, Sendable {
    public var name: String
    public var color: String
    public var archived: Bool
    public var createdAt: String
    public var updatedAt: String
    /// Documents attached to the project itself (not to one of its tasks).
    public var documents: [ExportedDocument]
    public var tasks: [ExportedTask]

    public init(name: String, color: String, archived: Bool, createdAt: String, updatedAt: String,
                documents: [ExportedDocument], tasks: [ExportedTask]) {
        self.name = name
        self.color = color
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.documents = documents
        self.tasks = tasks
    }
}

public struct ExportedTask: Codable, Sendable {
    public var title: String
    public var details: String
    /// Raw `TaskStatus` value, e.g. "in_progress".
    public var status: String
    /// Raw `TaskPriority` value, e.g. "high".
    public var priority: String
    public var dueDate: String?
    public var sortOrder: Double
    public var createdAt: String
    public var updatedAt: String
    public var labels: [ExportedLabel]
    public var subtasks: [ExportedSubtask]
    public var activity: [ExportedActivity]
    public var documents: [ExportedDocument]

    public init(title: String, details: String, status: String, priority: String, dueDate: String?,
                sortOrder: Double, createdAt: String, updatedAt: String, labels: [ExportedLabel],
                subtasks: [ExportedSubtask], activity: [ExportedActivity], documents: [ExportedDocument]) {
        self.title = title
        self.details = details
        self.status = status
        self.priority = priority
        self.dueDate = dueDate
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.labels = labels
        self.subtasks = subtasks
        self.activity = activity
        self.documents = documents
    }
}

public struct ExportedLabel: Codable, Sendable {
    public var name: String
    public var color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

public struct ExportedSubtask: Codable, Sendable {
    public var title: String
    public var done: Bool
    public var sortOrder: Double

    public init(title: String, done: Bool, sortOrder: Double) {
        self.title = title
        self.done = done
        self.sortOrder = sortOrder
    }
}

public struct ExportedActivity: Codable, Sendable {
    /// "user" or "claude" — preserved verbatim so imported history keeps its attribution.
    public var actor: String
    /// "note", "status", "created", "field".
    public var kind: String
    public var message: String
    public var createdAt: String

    public init(actor: String, kind: String, message: String, createdAt: String) {
        self.actor = actor
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
    }
}

public struct ExportedDocument: Codable, Sendable {
    public var title: String
    /// The absolute path this document had on the exporting machine. On import,
    /// if this path still exists we link straight to the live file.
    public var originalPath: String
    /// Path of the embedded copy inside the zip, or nil if the file could not be
    /// read at export time (already deleted or moved).
    public var file: String?

    public init(title: String, originalPath: String, file: String?) {
        self.title = title
        self.originalPath = originalPath
        self.file = file
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Core && swift test --filter ExportBundleTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/MarkdownProCore/ExportBundle.swift Core/Tests/MarkdownProCoreTests/ExportBundleTests.swift
git commit -m "Add Codable export bundle manifest types"
```

---

### Task 3: Repository import primitives

`Repository.createTask` stamps its own `created_at` and auto-logs a "created" activity entry — both wrong for an import, which must restore exported timestamps and real history verbatim. Add an import-specific insert path, plus the name-uniquifying helper the importer needs.

Note `db.transaction` is **not reentrant**: `insertImportedProject` opens the transaction, so everything inside it uses raw SQL or transaction-free `Repository` helpers (`addLabel`, `logActivity` are safe; `createTask`/`createProject` are not).

**Files:**
- Modify: `Core/Sources/MarkdownProCore/Repository.swift` (append a new `// MARK: - Import` section before `// MARK: - Stats`)
- Create: `Core/Tests/MarkdownProCoreTests/RepositoryImportTests.swift`
- Create: `Core/Tests/MarkdownProCoreTests/TestDatabase.swift`

**Interfaces:**
- Consumes: `ExportedProject`, `ExportedTask` (Task 2).
- Produces:
  - `public func availableProjectName(_ desired: String) throws -> String` — returns `desired`, or `"\(desired) (imported)"`, or `"\(desired) (imported 2)"`, … whichever is free.
  - `@discardableResult public func insertImportedProject(_ project: ExportedProject, name: String, documentPathResolver: (ExportedDocument) -> String?) throws -> Int64` — inserts the whole project in a single transaction, preserving timestamps and sort order, restoring activity verbatim, merging labels by name. `documentPathResolver` returns the on-disk path a document should link to, or nil to skip it.

- [ ] **Step 1: Write the shared test-database helper**

Create `Core/Tests/MarkdownProCoreTests/TestDatabase.swift`:

```swift
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
```

- [ ] **Step 2: Write the failing tests**

Create `Core/Tests/MarkdownProCoreTests/RepositoryImportTests.swift`:

```swift
import XCTest
@testable import MarkdownProCore

final class RepositoryImportTests: XCTestCase {

    private func sampleProject(name: String = "Imported") -> ExportedProject {
        ExportedProject(
            name: name,
            color: "#FF0000",
            archived: false,
            createdAt: "2026-06-01T09:00:00.000Z",
            updatedAt: "2026-06-02T09:00:00.000Z",
            documents: [],
            tasks: [
                ExportedTask(
                    title: "Restored task",
                    details: "body",
                    status: "in_progress",
                    priority: "high",
                    dueDate: "2026-07-20",
                    sortOrder: 7,
                    createdAt: "2026-06-03T10:00:00.000Z",
                    updatedAt: "2026-06-04T10:00:00.000Z",
                    labels: [ExportedLabel(name: "feature", color: "#111111")],
                    subtasks: [ExportedSubtask(title: "step one", done: true, sortOrder: 2)],
                    activity: [
                        ExportedActivity(actor: "claude", kind: "created",
                                         message: "created this task",
                                         createdAt: "2026-06-03T10:00:00.000Z"),
                        ExportedActivity(actor: "user", kind: "status",
                                         message: "moved from Todo to In Progress",
                                         createdAt: "2026-06-04T10:00:00.000Z")
                    ],
                    documents: []
                )
            ]
        )
    }

    func testInsertPreservesFieldsTimestampsAndHistory() throws {
        let test = try TestDatabase()
        let projectId = try test.repo.insertImportedProject(sampleProject(), name: "Imported") { _ in nil }

        let tasks = try test.repo.listTasks(projectId: projectId)
        XCTAssertEqual(tasks.count, 1)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.title, "Restored task")
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.sortOrder, 7)
        XCTAssertEqual(DateCoding.encode(task.createdAt), "2026-06-03T10:00:00.000Z")
        XCTAssertEqual(task.labels.map(\.name), ["feature"])

        let detail = try XCTUnwrap(test.repo.getTask(id: task.id))
        XCTAssertEqual(detail.subtasks.map(\.title), ["step one"])
        XCTAssertEqual(detail.subtasks.first?.done, true)

        // Exactly the two exported entries — no fabricated "created" entry on top.
        XCTAssertEqual(detail.activity.count, 2)
        XCTAssertEqual(Set(detail.activity.map(\.actor)), ["claude", "user"])
        let statusEntry = try XCTUnwrap(detail.activity.first { $0.kind == "status" })
        XCTAssertEqual(statusEntry.message, "moved from Todo to In Progress")
        XCTAssertEqual(DateCoding.encode(statusEntry.createdAt), "2026-06-04T10:00:00.000Z")
    }

    func testAvailableProjectNameUniquifiesOnCollision() throws {
        let test = try TestDatabase()
        XCTAssertEqual(try test.repo.availableProjectName("Fresh"), "Fresh")

        try test.repo.createProject(name: "Taken")
        XCTAssertEqual(try test.repo.availableProjectName("Taken"), "Taken (imported)")

        try test.repo.createProject(name: "Taken (imported)")
        XCTAssertEqual(try test.repo.availableProjectName("Taken"), "Taken (imported 2)")
    }

    func testExistingLabelIsReusedAndKeepsItsColor() throws {
        let test = try TestDatabase()
        let existingProject = try test.repo.createProject(name: "Existing")
        let existingTask = try test.repo.createTask(projectId: existingProject, title: "T")
        try test.repo.addLabel(taskId: existingTask, name: "feature", color: "#ABCDEF")

        // The bundle carries "feature" with a different colour.
        try test.repo.insertImportedProject(sampleProject(), name: "Imported") { _ in nil }

        let labels = try test.repo.listLabels().filter { $0.name == "feature" }
        XCTAssertEqual(labels.count, 1, "the label must be merged, not duplicated")
        XCTAssertEqual(labels.first?.color, "#ABCDEF", "the existing colour wins")
    }

    func testDocumentsAreLinkedAtTheResolvedPath() throws {
        let test = try TestDatabase()
        var project = sampleProject()
        project.documents = [ExportedDocument(title: "Roadmap", originalPath: "/nope/roadmap.md", file: "documents/0001-roadmap.md")]
        project.tasks[0].documents = [ExportedDocument(title: "Spec", originalPath: "/nope/spec.md", file: "documents/0002-spec.md")]

        let projectId = try test.repo.insertImportedProject(project, name: "Imported") { doc in
            "/resolved/\(doc.title).md"
        }

        let docs = try test.repo.documents(projectId: projectId)
        XCTAssertEqual(Set(docs.map(\.path)), ["/resolved/Roadmap.md", "/resolved/Spec.md"])

        let projectLevel = docs.filter { $0.taskId == nil }
        XCTAssertEqual(projectLevel.map(\.title), ["Roadmap"])
    }

    func testSkippedDocumentIsNotInserted() throws {
        let test = try TestDatabase()
        var project = sampleProject()
        project.documents = [ExportedDocument(title: "Gone", originalPath: "/nope/gone.md", file: nil)]

        let projectId = try test.repo.insertImportedProject(project, name: "Imported") { _ in nil }
        XCTAssertTrue(try test.repo.documents(projectId: projectId).isEmpty)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd Core && swift test --filter RepositoryImportTests`
Expected: FAIL — `value of type 'Repository' has no member 'insertImportedProject'`.

- [ ] **Step 4: Implement the import primitives**

In `Core/Sources/MarkdownProCore/Repository.swift`, insert this new section immediately before the `// MARK: - Stats` line:

```swift
    // MARK: - Import

    /// A free project name: `desired`, else "desired (imported)", "desired (imported 2)", …
    /// Import never merges into an existing project, so a collision becomes a new,
    /// visibly-named project rather than a silent overwrite.
    public func availableProjectName(_ desired: String) throws -> String {
        func isTaken(_ name: String) throws -> Bool {
            try db.query("SELECT 1 FROM projects WHERE name = ? COLLATE NOCASE LIMIT 1",
                         [.text(name)]).isEmpty == false
        }
        guard try isTaken(desired) else { return desired }
        let first = "\(desired) (imported)"
        guard try isTaken(first) else { return first }
        var suffix = 2
        while true {
            let candidate = "\(desired) (imported \(suffix))"
            if try !isTaken(candidate) { return candidate }
            suffix += 1
        }
    }

    /// Inserts a whole exported project, preserving timestamps, sort order and
    /// activity history verbatim — unlike `createTask`, which stamps its own
    /// `created_at` and logs a synthetic "created" entry.
    ///
    /// `documentPathResolver` decides where each document should point (a live file
    /// or a restored copy); returning nil skips that document.
    ///
    /// Runs in one transaction: a failure part-way leaves the board untouched.
    @discardableResult
    public func insertImportedProject(_ project: ExportedProject,
                                      name: String,
                                      documentPathResolver: (ExportedDocument) -> String?) throws -> Int64 {
        try db.transaction {
            try db.execute("""
                INSERT INTO projects (name, color, archived, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                [.text(name), .text(project.color), .integer(project.archived ? 1 : 0),
                 .text(project.createdAt), .text(project.updatedAt)])
            let projectId = db.lastInsertRowId

            for document in project.documents {
                try insertImportedDocument(document, taskId: nil, projectId: projectId,
                                           resolver: documentPathResolver)
            }

            for task in project.tasks {
                try db.execute("""
                    INSERT INTO tasks (project_id, title, details, status, priority, due_date,
                                       sort_order, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.integer(projectId), .text(task.title), .text(task.details),
                     .text(task.status), .text(task.priority),
                     task.dueDate.map { .text($0) } ?? .null,
                     .real(task.sortOrder), .text(task.createdAt), .text(task.updatedAt)])
                let taskId = db.lastInsertRowId

                // addLabel opens no transaction of its own, and already merges by
                // name while keeping an existing label's colour — exactly what we want.
                for label in task.labels {
                    try addLabel(taskId: taskId, name: label.name, color: label.color)
                }

                for subtask in task.subtasks {
                    try db.execute("INSERT INTO subtasks (task_id, title, done, sort_order) VALUES (?, ?, ?, ?)",
                                   [.integer(taskId), .text(subtask.title),
                                    .integer(subtask.done ? 1 : 0), .real(subtask.sortOrder)])
                }

                for entry in task.activity {
                    try db.execute("""
                        INSERT INTO activity (task_id, actor, kind, message, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        [.integer(taskId), .text(entry.actor), .text(entry.kind),
                         .text(entry.message), .text(entry.createdAt)])
                }

                for document in task.documents {
                    try insertImportedDocument(document, taskId: taskId, projectId: nil,
                                               resolver: documentPathResolver)
                }
            }

            return projectId
        }
    }

    /// Raw document insert. Unlike `attachDocument` it logs no activity — imported
    /// history comes from the bundle, not from the act of importing.
    private func insertImportedDocument(_ document: ExportedDocument,
                                        taskId: Int64?,
                                        projectId: Int64?,
                                        resolver: (ExportedDocument) -> String?) throws {
        guard let path = resolver(document) else { return }
        try db.execute("INSERT INTO documents (task_id, project_id, path, title, created_at) VALUES (?, ?, ?, ?, ?)",
                       [taskId.map { .integer($0) } ?? .null,
                        projectId.map { .integer($0) } ?? .null,
                        .text(path), .text(document.title), .text(now())])
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Core && swift test --filter RepositoryImportTests`
Expected: PASS — 5 tests.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/MarkdownProCore/Repository.swift Core/Tests/MarkdownProCoreTests/RepositoryImportTests.swift Core/Tests/MarkdownProCoreTests/TestDatabase.swift
git commit -m "Add Repository import primitives preserving timestamps and history"
```

---

### Task 4: ProjectExporter

Reads projects out of the `Repository`, slurps each document's contents off disk, and builds the zip.

Two details that are easy to get wrong:
- `Repository.documents(projectId:)` returns **both** project-level and task-level documents (it LEFT JOINs tasks). Project-level ones are those with `taskId == nil`.
- `Repository.getTask` returns activity **newest-first** (`ORDER BY id DESC`). The bundle stores it chronologically, so reverse it.

**Files:**
- Create: `Core/Sources/MarkdownProCore/ProjectExporter.swift`
- Create: `Core/Tests/MarkdownProCoreTests/ProjectExporterTests.swift`

**Interfaces:**
- Consumes: `Repository` (Task 3), `ExportBundle` and friends (Task 2), `Zip`/`ZipEntry` (Task 1).
- Produces: `public enum ProjectExporter { public static func export(projectIds: [Int64], repo: Repository) throws -> Data }` — returns `.mdproz` bytes.
- Also produces `public enum ExportError: Error, CustomStringConvertible { case projectNotFound(Int64) }`.

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/MarkdownProCoreTests/ProjectExporterTests.swift`:

```swift
import XCTest
@testable import MarkdownProCore

final class ProjectExporterTests: XCTestCase {

    func testExportProducesManifestWithTasksLabelsSubtasksAndHistory() throws {
        let test = try TestDatabase()
        let projectId = try test.repo.createProject(name: "Alpha", color: "#123456")
        let taskId = try test.repo.createTask(projectId: projectId, title: "Ship it", details: "body",
                                              status: .todo, priority: .high, dueDate: "2026-08-01",
                                              labels: ["feature"], subtasks: ["one", "two"])
        try test.repo.moveTask(id: taskId, to: .done, actor: "claude")

        let data = try ProjectExporter.export(projectIds: [projectId], repo: test.repo)
        let bundle = try decodeManifest(from: data)

        XCTAssertEqual(bundle.formatVersion, ExportBundle.currentFormatVersion)
        XCTAssertEqual(bundle.projects.count, 1)
        let project = try XCTUnwrap(bundle.projects.first)
        XCTAssertEqual(project.name, "Alpha")
        XCTAssertEqual(project.color, "#123456")

        let task = try XCTUnwrap(project.tasks.first)
        XCTAssertEqual(task.title, "Ship it")
        XCTAssertEqual(task.status, "done")
        XCTAssertEqual(task.priority, "high")
        XCTAssertEqual(task.dueDate, "2026-08-01")
        XCTAssertEqual(task.labels.map(\.name), ["feature"])
        XCTAssertEqual(task.subtasks.map(\.title), ["one", "two"])

        // "created" from createTask plus "status" from moveTask, oldest first.
        XCTAssertEqual(task.activity.map(\.kind), ["created", "status"])
        XCTAssertEqual(task.activity.last?.actor, "claude")
    }

    func testDocumentContentsAreEmbeddedAndProjectDocumentsStayProjectLevel() throws {
        let test = try TestDatabase()
        let projectId = try test.repo.createProject(name: "Alpha")
        let taskId = try test.repo.createTask(projectId: projectId, title: "T")

        let roadmap = try test.writeFile(named: "roadmap.md", contents: "# Roadmap\n")
        let spec = try test.writeFile(named: "spec.md", contents: "# Spec\n")
        try test.repo.attachDocument(taskId: nil, projectId: projectId, path: roadmap, title: "Roadmap")
        try test.repo.attachDocument(taskId: taskId, projectId: nil, path: spec, title: "Spec")

        let data = try ProjectExporter.export(projectIds: [projectId], repo: test.repo)
        let entries = try Zip.read(data)
        let bundle = try decodeManifest(from: data)
        let project = try XCTUnwrap(bundle.projects.first)

        let projectDoc = try XCTUnwrap(project.documents.first)
        XCTAssertEqual(project.documents.count, 1, "the task's document must not also appear at project level")
        XCTAssertEqual(projectDoc.title, "Roadmap")
        XCTAssertEqual(projectDoc.originalPath, roadmap)

        let taskDoc = try XCTUnwrap(project.tasks.first?.documents.first)
        XCTAssertEqual(taskDoc.title, "Spec")

        let roadmapEntry = try XCTUnwrap(entries.first { $0.name == projectDoc.file })
        XCTAssertEqual(String(data: roadmapEntry.data, encoding: .utf8), "# Roadmap\n")
        let specEntry = try XCTUnwrap(entries.first { $0.name == taskDoc.file })
        XCTAssertEqual(String(data: specEntry.data, encoding: .utf8), "# Spec\n")
    }

    func testMissingDocumentFileExportsWithNullFile() throws {
        let test = try TestDatabase()
        let projectId = try test.repo.createProject(name: "Alpha")
        try test.repo.attachDocument(taskId: nil, projectId: projectId,
                                     path: "/definitely/not/here.md", title: "Ghost")

        let data = try ProjectExporter.export(projectIds: [projectId], repo: test.repo)
        let bundle = try decodeManifest(from: data)
        let doc = try XCTUnwrap(bundle.projects.first?.documents.first)

        XCTAssertEqual(doc.originalPath, "/definitely/not/here.md")
        XCTAssertNil(doc.file, "an unreadable file must not fail the export")
    }

    func testUnknownProjectIdThrows() throws {
        let test = try TestDatabase()
        XCTAssertThrowsError(try ProjectExporter.export(projectIds: [9999], repo: test.repo))
    }

    private func decodeManifest(from bundle: Data) throws -> ExportBundle {
        let entries = try Zip.read(bundle)
        let manifest = try XCTUnwrap(entries.first { $0.name == ExportBundle.manifestEntryName })
        return try JSONDecoder().decode(ExportBundle.self, from: manifest.data)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter ProjectExporterTests`
Expected: FAIL — `cannot find 'ProjectExporter' in scope`.

- [ ] **Step 3: Implement ProjectExporter.swift**

Create `Core/Sources/MarkdownProCore/ProjectExporter.swift`:

```swift
import Foundation

public enum ExportError: Error, CustomStringConvertible {
    case projectNotFound(Int64)

    public var description: String {
        switch self {
        case .projectNotFound(let id): return "Project \(id) no longer exists."
        }
    }
}

/// Builds a `.mdproz` bundle (a store-only zip) from selected projects.
public enum ProjectExporter {

    public static func export(projectIds: [Int64], repo: Repository) throws -> Data {
        let all = try repo.listProjects(includeArchived: true)
        var entries: [ZipEntry] = []
        var documentIndex = 0

        /// Embeds a document's contents, returning the manifest entry.
        /// A file we cannot read is exported with `file: nil` — a broken link
        /// exports as a broken link rather than failing the whole export.
        func embed(_ document: LinkedDocument) -> ExportedDocument {
            let contents = FileManager.default.contents(atPath: document.path)
            var entryName: String?
            if let contents {
                documentIndex += 1
                let name = String(format: "documents/%04d-%@", documentIndex,
                                  sanitize(document.path as NSString).lastPathComponent)
                entries.append(ZipEntry(name: name, data: contents))
                entryName = name
            }
            return ExportedDocument(title: document.title,
                                    originalPath: document.path,
                                    file: entryName)
        }

        var projects: [ExportedProject] = []
        for id in projectIds {
            guard let project = all.first(where: { $0.id == id }) else {
                throw ExportError.projectNotFound(id)
            }

            // documents(projectId:) returns project-level AND task-level rows;
            // the project-level ones are those with no task_id.
            let projectDocuments = try repo.documents(projectId: id)
                .filter { $0.taskId == nil }
                .map(embed)

            var tasks: [ExportedTask] = []
            for item in try repo.listTasks(projectId: id) {
                guard let detail = try repo.getTask(id: item.id) else { continue }
                tasks.append(ExportedTask(
                    title: detail.task.title,
                    details: detail.task.details,
                    status: detail.task.status.rawValue,
                    priority: detail.task.priority.rawValue,
                    dueDate: detail.task.dueDate.map(DateCoding.encodeDay),
                    sortOrder: detail.task.sortOrder,
                    createdAt: DateCoding.encode(detail.task.createdAt),
                    updatedAt: DateCoding.encode(detail.task.updatedAt),
                    labels: detail.task.labels.map { ExportedLabel(name: $0.name, color: $0.color) },
                    subtasks: detail.subtasks.map {
                        ExportedSubtask(title: $0.title, done: $0.done, sortOrder: $0.sortOrder)
                    },
                    // getTask returns activity newest-first; the bundle stores it chronologically.
                    activity: detail.activity.reversed().map {
                        ExportedActivity(actor: $0.actor, kind: $0.kind, message: $0.message,
                                         createdAt: DateCoding.encode($0.createdAt))
                    },
                    documents: detail.documents.map(embed)
                ))
            }

            projects.append(ExportedProject(
                name: project.name,
                color: project.color,
                archived: project.archived,
                createdAt: DateCoding.encode(project.createdAt),
                updatedAt: DateCoding.encode(project.updatedAt),
                documents: projectDocuments,
                tasks: tasks
            ))
        }

        let bundle = ExportBundle(formatVersion: ExportBundle.currentFormatVersion,
                                  exportedAt: DateCoding.encode(Date()),
                                  projects: projects)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        entries.insert(ZipEntry(name: ExportBundle.manifestEntryName,
                                data: try encoder.encode(bundle)), at: 0)

        return Zip.archive(entries)
    }

    /// Keeps zip entry names tame. The `%04d-` prefix already guarantees uniqueness.
    private static func sanitize(_ path: NSString) -> NSString {
        let name = path.lastPathComponent
        let safe = name.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
                ? character : "-"
        }
        return (safe.isEmpty ? "document.md" : String(safe)) as NSString
    }
}
```

Note: `sanitize` returns an `NSString` whose `lastPathComponent` is already the sanitized name, so `sanitize(...).lastPathComponent` is the safe file name.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter ProjectExporterTests`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/MarkdownProCore/ProjectExporter.swift Core/Tests/MarkdownProCoreTests/ProjectExporterTests.swift
git commit -m "Add ProjectExporter building .mdproz bundles"
```

---

### Task 5: ProjectImporter

Reads a bundle, and inserts the selected projects. Two entry points, because the UI must be able to preview a bundle without writing anything.

**Files:**
- Create: `Core/Sources/MarkdownProCore/ProjectImporter.swift`
- Create: `Core/Tests/MarkdownProCoreTests/ProjectImporterTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces:
  - `public enum ImportError: Error, CustomStringConvertible { case missingManifest; case unsupportedFormatVersion(Int) }`
  - `public struct ImportPreview: Sendable` — `bundle: ExportBundle`, `projects: [ImportPreviewProject]`.
  - `public struct ImportPreviewProject: Identifiable, Sendable` — `id: Int` (index into `bundle.projects`), `name: String`, `taskCount: Int`, `documentCount: Int`, `relinkCount: Int` (documents whose `originalPath` still exists on disk), `restoreCount: Int` (documents that will be restored from the embedded copy).
  - `public enum ProjectImporter`:
    - `public static func preview(_ data: Data) throws -> ImportPreview`
    - `@discardableResult public static func `import`(_ data: Data, selecting indices: [Int], repo: Repository, documentsDirectory: URL = ProjectImporter.defaultDocumentsDirectory()) throws -> [Int64]` — returns the new project IDs.
    - `public static func defaultDocumentsDirectory() -> URL` — `~/Library/Application Support/MarkdownPro/Imported`.

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/MarkdownProCoreTests/ProjectImporterTests.swift`:

```swift
import XCTest
@testable import MarkdownProCore

final class ProjectImporterTests: XCTestCase {

    func testPreviewReportsProjectsWithoutWriting() throws {
        let source = try TestDatabase()
        let projectId = try source.repo.createProject(name: "Alpha")
        try source.repo.createTask(projectId: projectId, title: "One")
        try source.repo.createTask(projectId: projectId, title: "Two")
        let live = try source.writeFile(named: "live.md", contents: "# Live\n")
        try source.repo.attachDocument(taskId: nil, projectId: projectId, path: live, title: "Live")
        let bundle = try ProjectExporter.export(projectIds: [projectId], repo: source.repo)

        let target = try TestDatabase()
        let preview = try ProjectImporter.preview(bundle)

        XCTAssertEqual(preview.projects.count, 1)
        let project = try XCTUnwrap(preview.projects.first)
        XCTAssertEqual(project.name, "Alpha")
        XCTAssertEqual(project.taskCount, 2)
        XCTAssertEqual(project.documentCount, 1)
        XCTAssertEqual(project.relinkCount, 1, "the original file still exists, so it relinks")
        XCTAssertEqual(project.restoreCount, 0)

        XCTAssertTrue(try target.repo.listProjects().isEmpty, "preview must write nothing")
    }

    func testImportRoundTripsTasksSubtasksLabelsAndActivity() throws {
        let source = try TestDatabase()
        let projectId = try source.repo.createProject(name: "Alpha", color: "#123456")
        let taskId = try source.repo.createTask(projectId: projectId, title: "Ship it", details: "body",
                                                status: .todo, priority: .high, dueDate: "2026-08-01",
                                                labels: ["feature"], subtasks: ["one", "two"])
        try source.repo.moveTask(id: taskId, to: .done, actor: "claude")
        let original = try XCTUnwrap(source.repo.getTask(id: taskId))
        let bundle = try ProjectExporter.export(projectIds: [projectId], repo: source.repo)

        let target = try TestDatabase()
        let ids = try ProjectImporter.import(bundle, selecting: [0], repo: target.repo,
                                             documentsDirectory: target.directory.appendingPathComponent("Imported"))

        XCTAssertEqual(ids.count, 1)
        let imported = try XCTUnwrap(target.repo.listProjects().first)
        XCTAssertEqual(imported.name, "Alpha")
        XCTAssertEqual(imported.color, "#123456")

        let task = try XCTUnwrap(target.repo.listTasks(projectId: imported.id).first)
        XCTAssertEqual(task.title, "Ship it")
        XCTAssertEqual(task.status, .done)
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.labels.map(\.name), ["feature"])
        XCTAssertEqual(DateCoding.encode(task.createdAt), DateCoding.encode(original.task.createdAt),
                       "timestamps must survive the round trip")

        let detail = try XCTUnwrap(target.repo.getTask(id: task.id))
        XCTAssertEqual(detail.subtasks.map(\.title), ["one", "two"])
        XCTAssertEqual(detail.activity.count, original.activity.count)
        XCTAssertEqual(Set(detail.activity.map(\.actor)), Set(original.activity.map(\.actor)))
    }

    func testDocumentRelinksWhenOriginalPathStillExists() throws {
        let source = try TestDatabase()
        let projectId = try source.repo.createProject(name: "Alpha")
        let live = try source.writeFile(named: "live.md", contents: "# Live\n")
        try source.repo.attachDocument(taskId: nil, projectId: projectId, path: live, title: "Live")
        let bundle = try ProjectExporter.export(projectIds: [projectId], repo: source.repo)

        let target = try TestDatabase()
        let ids = try ProjectImporter.import(bundle, selecting: [0], repo: target.repo,
                                             documentsDirectory: target.directory.appendingPathComponent("Imported"))

        let doc = try XCTUnwrap(target.repo.documents(projectId: ids[0]).first)
        XCTAssertEqual(doc.path, live, "the live file still exists, so we link straight to it")
    }

    func testDocumentIsRestoredFromEmbeddedCopyWhenOriginalIsGone() throws {
        let source = try TestDatabase()
        let projectId = try source.repo.createProject(name: "Alpha")
        let doomed = try source.writeFile(named: "doomed.md", contents: "# Doomed\n")
        try source.repo.attachDocument(taskId: nil, projectId: projectId, path: doomed, title: "Doomed")
        let bundle = try ProjectExporter.export(projectIds: [projectId], repo: source.repo)

        // The original file disappears after the export.
        try FileManager.default.removeItem(atPath: doomed)

        let target = try TestDatabase()
        let importedDir = target.directory.appendingPathComponent("Imported")
        let ids = try ProjectImporter.import(bundle, selecting: [0], repo: target.repo,
                                             documentsDirectory: importedDir)

        let doc = try XCTUnwrap(target.repo.documents(projectId: ids[0]).first)
        XCTAssertNotEqual(doc.path, doomed)
        XCTAssertTrue(doc.path.hasPrefix(importedDir.path), "restored copies live under the imported directory")
        XCTAssertEqual(try String(contentsOfFile: doc.path, encoding: .utf8), "# Doomed\n")
    }

    func testImportingIntoABoardThatAlreadyHasTheNameCreatesANewProject() throws {
        let source = try TestDatabase()
        let projectId = try source.repo.createProject(name: "Alpha")
        try source.repo.createTask(projectId: projectId, title: "One")
        let bundle = try ProjectExporter.export(projectIds: [projectId], repo: source.repo)

        let target = try TestDatabase()
        try target.repo.createProject(name: "Alpha")
        try target.repo.createTask(projectId: target.repo.listProjects()[0].id, title: "Existing")

        try ProjectImporter.import(bundle, selecting: [0], repo: target.repo,
                                   documentsDirectory: target.directory.appendingPathComponent("Imported"))

        let names = try target.repo.listProjects().map(\.name).sorted()
        XCTAssertEqual(names, ["Alpha", "Alpha (imported)"])

        let originalProject = try XCTUnwrap(target.repo.listProjects().first { $0.name == "Alpha" })
        XCTAssertEqual(try target.repo.listTasks(projectId: originalProject.id).map(\.title), ["Existing"],
                       "the existing project must be untouched")
    }

    func testUnselectedProjectsAreNotImported() throws {
        let source = try TestDatabase()
        let a = try source.repo.createProject(name: "Alpha")
        let b = try source.repo.createProject(name: "Beta")
        let bundle = try ProjectExporter.export(projectIds: [a, b], repo: source.repo)

        let target = try TestDatabase()
        try ProjectImporter.import(bundle, selecting: [1], repo: target.repo,
                                   documentsDirectory: target.directory.appendingPathComponent("Imported"))

        XCTAssertEqual(try target.repo.listProjects().map(\.name), ["Beta"])
    }

    func testUnknownFormatVersionIsRejected() throws {
        let manifest = Data(#"{"formatVersion":99,"exportedAt":"2026-07-14T10:00:00.000Z","projects":[]}"#.utf8)
        let bundle = Zip.archive([ZipEntry(name: ExportBundle.manifestEntryName, data: manifest)])

        XCTAssertThrowsError(try ProjectImporter.preview(bundle)) { error in
            guard case ImportError.unsupportedFormatVersion(99) = error else {
                return XCTFail("expected unsupportedFormatVersion, got \(error)")
            }
        }
    }

    func testBundleWithoutManifestIsRejected() throws {
        let bundle = Zip.archive([ZipEntry(name: "documents/0001-spec.md", data: Data("# Spec\n".utf8))])
        XCTAssertThrowsError(try ProjectImporter.preview(bundle)) { error in
            guard case ImportError.missingManifest = error else {
                return XCTFail("expected missingManifest, got \(error)")
            }
        }
    }

    func testNonZipFileIsRejectedAndWritesNothing() throws {
        let target = try TestDatabase()
        XCTAssertThrowsError(try ProjectImporter.preview(Data("just some text".utf8)))
        XCTAssertTrue(try target.repo.listProjects().isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter ProjectImporterTests`
Expected: FAIL — `cannot find 'ProjectImporter' in scope`.

- [ ] **Step 3: Implement ProjectImporter.swift**

Create `Core/Sources/MarkdownProCore/ProjectImporter.swift`:

```swift
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
        let safe = name.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == " "
                ? character : "-"
        }
        let trimmed = String(safe).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Imported" : trimmed
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter ProjectImporterTests`
Expected: PASS — 9 tests.

- [ ] **Step 5: Run the whole Core suite**

Run: `cd Core && swift test`
Expected: PASS — all tests from Tasks 1-5.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/MarkdownProCore/ProjectImporter.swift Core/Tests/MarkdownProCoreTests/ProjectImporterTests.swift
git commit -m "Add ProjectImporter with document relink/restore and name collision handling"
```

---

### Task 6: Store passthroughs and the sheet plumbing

`Store` is the app's single source of truth and its only route to `Repository`. Give it export/import methods and a channel for the menu commands to open a sheet.

**Files:**
- Modify: `MarkdownPro/Store.swift`

**Interfaces:**
- Consumes: `ProjectExporter`, `ProjectImporter`, `ImportPreview` (Tasks 4-5).
- Produces, on `Store`:
  - `enum ActiveSheet: Identifiable { case export(preselected: Set<Int64>); case importBundle(ImportPreview, URL) }` with `var id: String`
  - `@Published var activeSheet: ActiveSheet?`
  - `func allProjectsIncludingArchived() -> [Project]`
  - `func exportProjects(ids: [Int64], to url: URL)`
  - `func beginImport(from url: URL)` — reads and previews the file, sets `activeSheet`, or sets `errorMessage`
  - `func finishImport(preview: ImportPreview, url: URL, selecting indices: [Int])`

- [ ] **Step 1: Add the sheet channel and export/import methods**

In `MarkdownPro/Store.swift`, add to the `@Published` block near the top (after `pendingReaderURL`):

```swift
    /// Which modal the app is showing, if any. Set by the File menu and the
    /// sidebar context menu; consumed by ContentView.
    @Published var activeSheet: ActiveSheet?
```

Then add this nested type just below the `@Published` properties:

```swift
    enum ActiveSheet: Identifiable {
        case export(preselected: Set<Int64>)
        case importBundle(ImportPreview, URL)

        var id: String {
            switch self {
            case .export: return "export"
            case .importBundle(_, let url): return "import:\(url.path)"
            }
        }
    }
```

And append this section at the end of the class, just before the closing brace (after `openInReader`):

```swift
    // MARK: - Export / import

    /// The export picker lists archived projects too (unchecked by default),
    /// so `projects` — which hides them — is not enough.
    func allProjectsIncludingArchived() -> [Project] {
        guard let repo else { return [] }
        return (try? repo.listProjects(includeArchived: true)) ?? []
    }

    func exportProjects(ids: [Int64], to url: URL) {
        guard let repo else { return }
        do {
            let data = try ProjectExporter.export(projectIds: ids, repo: repo)
            try data.write(to: url)
        } catch {
            errorMessage = "Export failed: \(error)"
        }
    }

    /// Reads and validates a bundle, then opens the import sheet. Writes nothing.
    func beginImport(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let preview = try ProjectImporter.preview(data)
            guard !preview.projects.isEmpty else {
                errorMessage = "That export contains no projects."
                return
            }
            activeSheet = .importBundle(preview, url)
        } catch {
            errorMessage = "Could not read that export: \(error)"
        }
    }

    func finishImport(preview: ImportPreview, url: URL, selecting indices: [Int]) {
        guard let repo else { return }
        do {
            let data = try Data(contentsOf: url)
            try ProjectImporter.import(data, selecting: indices, repo: repo)
            refresh()
        } catch {
            errorMessage = "Import failed: \(error)"
        }
    }
```

Also add the import at the top of the file if not already present — `Store.swift` already has `import MarkdownProCore`, so nothing to do.

- [ ] **Step 2: Build the app to verify it compiles**

Run:
```bash
xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MarkdownPro/Store.swift
git commit -m "Add export/import passthroughs and sheet channel to Store"
```

---

### Task 7: The export sheet, menu commands, and context menu

**Files:**
- Create: `MarkdownPro/Views/ExportSheet.swift`
- Modify: `MarkdownPro/MarkdownProApp.swift`
- Modify: `MarkdownPro/Views/ContentView.swift` (sheet host at ~line 35; sidebar context menu at ~lines 76-81)

**Interfaces:**
- Consumes: `Store.ActiveSheet`, `Store.allProjectsIncludingArchived()`, `Store.exportProjects(ids:to:)` (Task 6).
- Produces: `struct ExportSheet: View` — `init(preselected: Set<Int64>)`, reads `Store` from the environment.

- [ ] **Step 1: Write the export sheet**

Create `MarkdownPro/Views/ExportSheet.swift`:

```swift
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
                                    .frame(width: 8, height: 8)
                                Text(project.name)
                                if project.archived {
                                    Text("Archived")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(project.taskCount) task\(project.taskCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                Button("Export…") { save() }
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
        panel.allowedContentTypes = []
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
```

Note: `Color(hex:)` already exists in `MarkdownPro/Helpers.swift` — check its exact name before using it, and match it.

- [ ] **Step 2: Add the File menu commands**

Replace `MarkdownPro/MarkdownProApp.swift` in full:

```swift
import SwiftUI
import AppKit

@main
struct MarkdownProApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1080, minHeight: 660)
        }
        .commands {
            CommandGroup(replacing: .importExport) {
                Button("Import Projects…") { chooseImportFile() }
                Button("Export Projects…") {
                    store.activeSheet = .export(preselected: [])
                }
            }
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.beginImport(from: url)
    }
}
```

Keep the existing `.frame(minWidth:minHeight:)` values — verify them against the current file before overwriting, and preserve whatever is there.

- [ ] **Step 3: Host the sheets and add the context-menu item**

In `MarkdownPro/Views/ContentView.swift`, add a `.sheet` modifier alongside the existing `.alert` on the `NavigationSplitView` (around line 35):

```swift
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
```

`ImportSheet` does not exist until Task 8 — to keep this task independently buildable, add the export case only for now and add the import case in Task 8. That means, for this task:

```swift
        .sheet(item: $store.activeSheet) { sheet in
            switch sheet {
            case .export(let preselected):
                ExportSheet(preselected: preselected)
                    .environmentObject(store)
            case .importBundle:
                EmptyView()
            }
        }
```

And in the sidebar's per-project `contextMenu` (currently just "Delete Project", around line 76), add an Export item **above** the delete button:

```swift
                        Button("Export…") {
                            store.activeSheet = .export(preselected: [project.id])
                        }
                        Divider()
```

- [ ] **Step 4: Build and run**

Run:
```bash
xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

Then launch and verify by hand:
```bash
open ~/Library/Developer/Xcode/DerivedData/MarkdownPro-*/Build/Products/Debug/MarkdownPro.app
```
- File ▸ Export Projects… opens the sheet listing every project with a task count.
- Right-clicking a project in the sidebar shows Export…, and it opens the sheet with that project already checked.
- Exporting writes a `.mdproz` file. Confirm it is a real zip:
  `unzip -l ~/Desktop/MarkdownPro\ Export\ *.mdproz` should list `manifest.json` and any `documents/…`.

- [ ] **Step 5: Commit**

```bash
git add MarkdownPro/Views/ExportSheet.swift MarkdownPro/MarkdownProApp.swift MarkdownPro/Views/ContentView.swift
git commit -m "Add export sheet, File menu commands and sidebar export action"
```

---

### Task 8: The import sheet

Shows what is in the bundle before anything is written: each project, its task count, and how many documents will relink to a live file versus be restored from the embedded copy.

**Files:**
- Create: `MarkdownPro/Views/ImportSheet.swift`
- Modify: `MarkdownPro/Views/ContentView.swift` (replace the `case .importBundle: EmptyView()` placeholder from Task 7)

**Interfaces:**
- Consumes: `ImportPreview`, `ImportPreviewProject` (Task 5), `Store.finishImport(preview:url:selecting:)` (Task 6).
- Produces: `struct ImportSheet: View` — `init(preview: ImportPreview, url: URL)`.

- [ ] **Step 1: Write the import sheet**

Create `MarkdownPro/Views/ImportSheet.swift`:

```swift
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

            HStack {
                Text("Imported projects are added to the board — nothing existing is changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    let indices = preview.projects.map(\.id).filter { selected.contains($0) }
                    store.finishImport(preview: preview, url: url, selecting: indices)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 420)
    }

    private func binding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
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
```

- [ ] **Step 2: Wire it into ContentView**

In `MarkdownPro/Views/ContentView.swift`, replace the placeholder from Task 7:

```swift
            case .importBundle:
                EmptyView()
```

with:

```swift
            case .importBundle(let preview, let url):
                ImportSheet(preview: preview, url: url)
                    .environmentObject(store)
```

- [ ] **Step 3: Build**

Run:
```bash
xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Verify the round trip by hand**

```bash
open ~/Library/Developer/Xcode/DerivedData/MarkdownPro-*/Build/Products/Debug/MarkdownPro.app
```

1. Export a project that has tasks, labels, subtasks and at least one attached markdown document.
2. Delete that project from the sidebar.
3. File ▸ Import Projects…, pick the `.mdproz` file. The sheet should list the project with its task count.
4. Import it. The project reappears with its tasks, their statuses, priorities, labels, subtasks and activity history — including entries attributed to Claude.
5. Open the task's document: it should open in the reader, still pointing at the original file on disk.
6. Import the *same* file again. A second project appears, named `<name> (imported)`; the first one is untouched.
7. Move the original markdown file somewhere else, then import again. The new project's document should now point into `~/Library/Application Support/MarkdownPro/Imported/…` and still open.

- [ ] **Step 5: Commit**

```bash
git add MarkdownPro/Views/ImportSheet.swift MarkdownPro/Views/ContentView.swift
git commit -m "Add import sheet with bundle preview"
```

---

### Task 9: Documentation

**Files:**
- Modify: `docs/QA_CHECKLIST.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add the export/import section to the QA checklist**

Append to `docs/QA_CHECKLIST.md`:

```markdown
## Export / import

- [ ] File ▸ Export Projects… lists every project with its task count; archived
      projects appear but start unchecked.
- [ ] Right-clicking a project in the sidebar offers Export…, with that project
      pre-checked.
- [ ] Exporting writes a `.mdproz` file. `unzip -l <file>` lists `manifest.json`
      and one entry per attached document.
- [ ] A project with no documents exports and imports cleanly.
- [ ] File ▸ Import Projects… previews the bundle — project names, task counts,
      and how many documents will relink versus be restored — before writing.
- [ ] Cancelling the import sheet writes nothing.
- [ ] Importing restores tasks with their status, priority, due date, labels,
      subtasks and activity history, with `claude` attribution intact.
- [ ] Importing a bundle whose project name already exists creates
      `<name> (imported)` and leaves the existing project untouched.
- [ ] A document whose original file still exists links to that live file; a
      document whose original is gone is restored under
      `~/Library/Application Support/MarkdownPro/Imported/` and still opens in
      the reader.
- [ ] Importing a non-export file (e.g. a random `.zip` or a `.txt`) shows a
      clear error and changes nothing.
```

- [ ] **Step 2: Note the feature in CLAUDE.md**

In `CLAUDE.md`, under "Conventions & sharp edges", add:

```markdown
- Export/import lives in `Core`: `Zip.swift` (hand-rolled store-only zip — no
  dependencies, no shelling out), `ExportBundle.swift` (the `manifest.json`
  types), `ProjectExporter` / `ProjectImporter`. Bundles are `.mdproz` files.
  Import is additive: a name collision becomes `<name> (imported)`, never a
  merge. `Repository.insertImportedProject` exists because `createTask` stamps
  its own timestamps and auto-logs a "created" entry — both wrong when
  restoring real history.
```

- [ ] **Step 3: Run the full test suite one more time**

Run: `cd Core && swift test`
Expected: PASS — every test.

- [ ] **Step 4: Commit**

```bash
git add docs/QA_CHECKLIST.md CLAUDE.md
git commit -m "Document export/import in QA checklist and CLAUDE.md"
```

---

## Self-review notes

- **Spec coverage:** bundle format → Tasks 1-2; Core split → Tasks 1, 2, 4, 5; import semantics (new project, label merge, document relink/restore, verbatim history) → Tasks 3, 5; UI (menu, context menu, both sheets) → Tasks 6-8; testing → tests in Tasks 1-5 plus the QA checklist in Task 9.
- **Not covered by automated tests, deliberately:** the SwiftUI sheets. They are verified by the manual pass in Tasks 7-8 and the QA checklist; the project has no UI test target and adding one is out of scope.
- **Known ordering constraint:** Task 7 introduces a `case .importBundle: EmptyView()` placeholder so it builds without Task 8. Task 8 replaces it. Do not skip that replacement.
