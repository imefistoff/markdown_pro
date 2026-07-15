# Launch Claude Code from the Review Center — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn an approved spec/plan document into a running Claude Code session in one deliberate click from the Review Center, closing the `ready_to_execute → executing` loop.

**Architecture:** A pure `LaunchScriptBuilder` in `MarkdownProCore` composes a shell script (task/document/settings → `LaunchScript`); the app shows a confirm sheet with the exact command and hands the script to a `TerminalLauncher` (`WarpLauncher` in the app; `FakeTerminalLauncher` in tests). Per-project launch configuration and editable prompt templates live in schema v3. `Repository.recordLaunch` flips attention to `executing` and logs activity, keeping the shared-SQLite single-write-path invariant.

**Tech Stack:** Swift, SwiftUI + AppKit (app target, macOS 14+), Foundation + SQLite3 (`MarkdownProCore`, no GRDB, no external deps), hand-rolled MCP stdio JSON-RPC (`markdownpro-mcp`). Tests: XCTest under `Core/Tests/MarkdownProCoreTests`.

## Design refinements to the spec (read before starting)

The approved spec (`docs/superpowers/specs/2026-07-12-warp-launch-design.md`) is authoritative on intent. Two points are made concrete here; both preserve the spec's guarantees:

1. **Editable templates are the *prompt* text, not the full command line.** The spec's decision 2 ("a plugin rename becomes a text edit") is about *skill names*, which live in the natural-language prompt (`superpowers:writing-plans`), never in the flags. So each project stores two editable **prompts** (`spec` → planning, `plan` → execution). The `claude` **flags** are assembled by the builder from the document kind + project settings: planning is always `--permission-mode plan` with no worktree; execution uses `-w <slug>` (when `use_worktree`) and `--permission-mode <preset>`. This matches the spec's emitted-script example exactly (`exec claude -w "slug" --permission-mode acceptEdits "$PROMPT"`) and keeps all spec placeholders (`{doc} {doc_abs} {task_id} {task_title} {project} {slug} {preset} {repo}`) substitutable inside the prompt.

2. **Shell values are single-quoted, not double-quoted.** The spec shows `cd "repo"`; this plan single-quotes `repo_path` and the slug (`'…'` with `'\''` escaping) — strictly safer, identical behavior for real directory paths.

Everything else (schema v3, injection containment via a quoted heredoc, the `TerminalLauncher` protocol, unsafe-preset warning, Copy fallback, "Clear attention" escape hatch) follows the spec verbatim.

## Global Constraints

Every task's requirements implicitly include these:

- **Platform:** macOS 14+. `MarkdownProCore` imports only `Foundation` and `SQLite3` — **no** AppKit/SwiftUI and no external packages. AppKit/SwiftUI live only in the `MarkdownPro/` app target.
- **`Label` is ambiguous** — always write `SwiftUI.Label` for the view and `MarkdownProCore.Label` for the model. The task model is `TaskItem` (never `Task`).
- **Dates** are TEXT columns via `DateCoding` (ISO-8601 with fractional seconds for timestamps).
- **Every mutation goes through `Repository`** so activity attribution stays correct: `actor` is `"user"` from the app, `"claude"` from the MCP server. Never add a second write path that bypasses the shared SQLite file.
- **Schema changes** bump `PRAGMA user_version` and add an *idempotent, column-existence-guarded* migration step in `Core/Sources/MarkdownProCore/Database.swift`. Both processes migrate on open.
- **Xcode 16 synchronized folder:** dropping a `.swift` file under `MarkdownPro/` auto-adds it to the app target. Bundled resource names must stay unique (not relevant to the pure-Swift files added here).
- **Build/test commands:**
  - App: `xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build`
  - Core: `cd Core && swift test`
  - MCP: `cd mcp-server && swift build -c release`
- **DB override for tests/manual runs:** `MARKDOWNPRO_DB=/tmp/scratch.sqlite`.
- **Launch configuration is machine-local and intentionally NOT exported** (repo paths are absolute/host-specific) — leave `ProjectExporter`/`ProjectImporter` untouched, exactly as review state is not carried by the bundle.

---

### Task 1: Schema v3 + `DocumentKind` gains `spec`/`plan`

**Files:**
- Modify: `Core/Sources/MarkdownProCore/Models.swift` (the `DocumentKind` enum, ~line 56)
- Modify: `Core/Sources/MarkdownProCore/Database.swift` (`migrate`, after the `if version < 2` block, ~line 151)
- Test: `Core/Tests/MarkdownProCoreTests/MigrationTests.swift`

**Interfaces:**
- Produces: `DocumentKind.spec`, `DocumentKind.plan`, and `DocumentKind.isReviewable: Bool` (true for `.proposal`, `.spec`, `.plan`). A migrated DB at `PRAGMA user_version = 3` with `projects.repo_path TEXT`, `projects.permission_preset TEXT NOT NULL DEFAULT 'acceptEdits'`, `projects.use_worktree INTEGER NOT NULL DEFAULT 1`, and a `launch_templates(project_id, doc_kind, command, PRIMARY KEY(project_id, doc_kind))` table.

- [ ] **Step 1: Write the failing migration test**

Add to `MigrationTests.swift` (it already builds a v1 legacy DB and opens through migrations):

```swift
func testMigrationV3AddsLaunchSchema() throws {
    try makeLegacyDB()                 // v1 → open runs all migrations
    let db = try Database.open(path: path)

    let projectCols = try db.query("PRAGMA table_info(projects)").map { $0.string("name") }
    for col in ["repo_path", "permission_preset", "use_worktree"] {
        XCTAssertTrue(projectCols.contains(col), "projects.\(col) missing after v3 migration")
    }
    // launch_templates table exists and is queryable.
    XCTAssertNoThrow(try db.query("SELECT COUNT(*) AS c FROM launch_templates"))
    XCTAssertEqual(try db.query("PRAGMA user_version").first?.int("user_version"), 3)
}

func testMigrationV3IsIdempotent() throws {
    try makeLegacyDB()
    _ = try Database.open(path: path)
    XCTAssertNoThrow(try Database.open(path: path))   // second open must not throw
    let db = try Database.open(path: path)
    XCTAssertEqual(try db.query("PRAGMA user_version").first?.int("user_version"), 3)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter MigrationTests`
Expected: FAIL — `no such column: repo_path` / `no such table: launch_templates`.

- [ ] **Step 3: Add `spec`/`plan` and `isReviewable` to `DocumentKind`**

In `Models.swift`, replace the `DocumentKind` enum:

```swift
public enum DocumentKind: String, CaseIterable, Codable, Sendable {
    case note
    case wiki
    case proposal
    case spec
    case plan

    /// Kinds that go through the review queue and therefore may NOT be added
    /// via attach_document (only via submit_for_review).
    public var isReviewable: Bool {
        switch self {
        case .proposal, .spec, .plan: return true
        case .note, .wiki: return false
        }
    }
}
```

- [ ] **Step 4: Add the v3 migration step**

In `Database.swift`, immediately after the closing brace of the `if version < 2 { … }` block and before the final closing braces of `migrate`, add:

```swift
if version < 3 {
    try db.transaction {
        // Column-existence guards keep a partially-upgraded DB (crash between
        // processes) migrating cleanly, exactly like the v2 step. No CHECK
        // constraints on enum-like columns: validated in Swift.
        let projectCols = try db.query("PRAGMA table_info(projects)").map { $0.string("name") }
        if !projectCols.contains("repo_path") {
            try db.execute("ALTER TABLE projects ADD COLUMN repo_path TEXT")
        }
        if !projectCols.contains("permission_preset") {
            try db.execute("ALTER TABLE projects ADD COLUMN permission_preset TEXT NOT NULL DEFAULT 'acceptEdits'")
        }
        if !projectCols.contains("use_worktree") {
            try db.execute("ALTER TABLE projects ADD COLUMN use_worktree INTEGER NOT NULL DEFAULT 1")
        }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS launch_templates (
                project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                doc_kind   TEXT    NOT NULL,
                command    TEXT    NOT NULL,
                PRIMARY KEY (project_id, doc_kind)
            )
            """)
        try db.execute("PRAGMA user_version = 3")
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Core && swift test --filter MigrationTests`
Expected: PASS (all migration tests, including the existing v2 ones).

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/MarkdownProCore/Models.swift Core/Sources/MarkdownProCore/Database.swift Core/Tests/MarkdownProCoreTests/MigrationTests.swift
git commit -m "feat(core): schema v3 launch columns + spec/plan document kinds"
```

---

### Task 2: Launch value types — `PermissionPreset`, templates, `ProjectLaunchSettings`

**Files:**
- Create: `Core/Sources/MarkdownProCore/Launch.swift`
- Test: `Core/Tests/MarkdownProCoreTests/LaunchTests.swift` (new file)

**Interfaces:**
- Consumes: `DocumentKind` (Task 1).
- Produces:
  - `PermissionPreset: String, CaseIterable, Codable, Sendable, Identifiable` with cases `manual, plan, acceptEdits, auto, dontAsk, bypassPermissions`; `displayName: String`; `isUnsafe: Bool` (true for `auto/dontAsk/bypassPermissions`). `rawValue` is the literal `--permission-mode` value.
  - `enum LaunchTemplates` with `static let defaultSpecPrompt: String`, `static let defaultPlanPrompt: String`, `static func defaultPrompt(for: DocumentKind) -> String?`.
  - `struct ProjectLaunchSettings: Sendable, Equatable` — `projectId: Int64`, `projectName: String`, `repoPath: String?`, `permissionPreset: PermissionPreset`, `useWorktree: Bool`, `specPrompt: String`, `planPrompt: String`; `func prompt(for: DocumentKind) -> String?`.

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/MarkdownProCoreTests/LaunchTests.swift`:

```swift
import XCTest
@testable import MarkdownProCore

final class LaunchTests: XCTestCase {

    func testUnsafePresets() {
        XCTAssertTrue(PermissionPreset.auto.isUnsafe)
        XCTAssertTrue(PermissionPreset.dontAsk.isUnsafe)
        XCTAssertTrue(PermissionPreset.bypassPermissions.isUnsafe)
        XCTAssertFalse(PermissionPreset.manual.isUnsafe)
        XCTAssertFalse(PermissionPreset.plan.isUnsafe)
        XCTAssertFalse(PermissionPreset.acceptEdits.isUnsafe)
    }

    func testDefaultPromptsResolveByKind() {
        XCTAssertEqual(LaunchTemplates.defaultPrompt(for: .spec), LaunchTemplates.defaultSpecPrompt)
        XCTAssertEqual(LaunchTemplates.defaultPrompt(for: .plan), LaunchTemplates.defaultPlanPrompt)
        XCTAssertNil(LaunchTemplates.defaultPrompt(for: .proposal))
        // Prompts mention the superpowers skills so a plugin rename is a text edit.
        XCTAssertTrue(LaunchTemplates.defaultSpecPrompt.contains("superpowers:writing-plans"))
        XCTAssertTrue(LaunchTemplates.defaultPlanPrompt.contains("superpowers:subagent-driven-development"))
        // Single-line prompts (heredoc friendliness is nice-to-have, not required).
        XCTAssertFalse(LaunchTemplates.defaultSpecPrompt.contains("\n"))
    }

    func testSettingsDefaults() {
        let s = ProjectLaunchSettings(projectId: 1, projectName: "P")
        XCTAssertNil(s.repoPath)
        XCTAssertEqual(s.permissionPreset, .acceptEdits)
        XCTAssertTrue(s.useWorktree)
        XCTAssertEqual(s.prompt(for: .spec), LaunchTemplates.defaultSpecPrompt)
        XCTAssertEqual(s.prompt(for: .plan), LaunchTemplates.defaultPlanPrompt)
        XCTAssertNil(s.prompt(for: .note))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Core && swift test --filter LaunchTests`
Expected: FAIL — `cannot find 'PermissionPreset' in scope`.

- [ ] **Step 3: Create `Launch.swift` with the value types**

```swift
import Foundation

/// How the spawned `claude` session treats permissions. `rawValue` is the exact
/// `--permission-mode` flag value.
public enum PermissionPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case manual
    case plan
    case acceptEdits
    case auto
    case dontAsk
    case bypassPermissions

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .manual: return "Manual — ask every time"
        case .plan: return "Plan mode"
        case .acceptEdits: return "Accept edits"
        case .auto: return "Auto"
        case .dontAsk: return "Don't ask"
        case .bypassPermissions: return "Bypass permissions"
        }
    }

    /// Modes that let the agent act without per-action confirmation. The confirm
    /// sheet adds a warning band and does not focus Run for these.
    public var isUnsafe: Bool {
        switch self {
        case .auto, .dontAsk, .bypassPermissions: return true
        case .manual, .plan, .acceptEdits: return false
        }
    }
}

/// Built-in prompt templates — the superpowers chain shipped as the seeded
/// default. Per-project overrides live in the `launch_templates` table; a row
/// exists only when a template has been changed from these defaults.
public enum LaunchTemplates {
    public static let defaultSpecPrompt =
        "Use the superpowers:writing-plans skill on @{doc} to produce an " +
        "implementation plan for MarkdownPro task {task_id} — {task_title}. " +
        "Submit the plan with submit_for_review."

    public static let defaultPlanPrompt =
        "Use the superpowers:subagent-driven-development skill to execute @{doc}. " +
        "This is MarkdownPro task {task_id} — {task_title}. Call add_progress_note " +
        "as each task lands; call submit_for_review with the final report when done."

    public static func defaultPrompt(for kind: DocumentKind) -> String? {
        switch kind {
        case .spec: return defaultSpecPrompt
        case .plan: return defaultPlanPrompt
        default: return nil
        }
    }
}

/// A project's launch configuration, resolved from the `projects` row plus any
/// `launch_templates` overrides.
public struct ProjectLaunchSettings: Sendable, Equatable {
    public var projectId: Int64
    public var projectName: String
    /// Working directory. Nil ⇒ launch is disabled for this project.
    public var repoPath: String?
    public var permissionPreset: PermissionPreset
    public var useWorktree: Bool
    public var specPrompt: String
    public var planPrompt: String

    public init(projectId: Int64,
                projectName: String,
                repoPath: String? = nil,
                permissionPreset: PermissionPreset = .acceptEdits,
                useWorktree: Bool = true,
                specPrompt: String = LaunchTemplates.defaultSpecPrompt,
                planPrompt: String = LaunchTemplates.defaultPlanPrompt) {
        self.projectId = projectId
        self.projectName = projectName
        self.repoPath = repoPath
        self.permissionPreset = permissionPreset
        self.useWorktree = useWorktree
        self.specPrompt = specPrompt
        self.planPrompt = planPrompt
    }

    public func prompt(for kind: DocumentKind) -> String? {
        switch kind {
        case .spec: return specPrompt
        case .plan: return planPrompt
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Core && swift test --filter LaunchTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/MarkdownProCore/Launch.swift Core/Tests/MarkdownProCoreTests/LaunchTests.swift
git commit -m "feat(core): launch value types (PermissionPreset, templates, settings)"
```

---

### Task 3: `LaunchScriptBuilder` — the injection-hardened engine + `TerminalLauncher`

**Files:**
- Create: `Core/Sources/MarkdownProCore/LaunchScriptBuilder.swift`
- Modify: `Core/Tests/MarkdownProCoreTests/LaunchTests.swift` (add builder tests)

**Interfaces:**
- Consumes: `TaskItem`, `LinkedDocument` (Models.swift), `ProjectLaunchSettings`, `PermissionPreset` (Task 2).
- Produces:
  - `struct LaunchScript: Sendable, Equatable` — `taskId: Int64`, `kind: DocumentKind`, `documentPath: String` (absolute), `configName: String` (`"markdownpro-task-<id>"`), `repoPath: String`, `worktreeSlug: String?`, `command: String` (the `exec claude …` line), `script: String` (full shell script), `isUnsafe: Bool`.
  - `enum LaunchError: Error, CustomStringConvertible, Equatable` — `noRepoPath`, `unlaunchableKind(DocumentKind)`, `promptContainsDelimiter`.
  - `struct LaunchScriptBuilder` with `static func script(task: TaskItem, document: LinkedDocument, settings: ProjectLaunchSettings) throws -> LaunchScript`.
  - `protocol TerminalLauncher { func launch(_ script: LaunchScript) throws }` and `final class FakeTerminalLauncher: TerminalLauncher` (records `launched: [LaunchScript]`, optional `errorToThrow`).

- [ ] **Step 1: Write the failing tests**

Append to `LaunchTests.swift`. These are the spec's required cases: placeholder substitution, injection, slug sanitization, kind→flags, isUnsafe.

```swift
extension LaunchTests {
    private func task(_ id: Int64 = 10, _ title: String = "Define rejected-proposal semantics",
                      projectId: Int64 = 3) -> TaskItem {
        TaskItem(id: id, projectId: projectId, title: title, details: "",
                 status: .inProgress, priority: .none, dueDate: nil, sortOrder: 0,
                 createdAt: Date(), updatedAt: Date())
    }
    private func doc(_ kind: DocumentKind, path: String = "/repo/docs/plan.md") -> LinkedDocument {
        LinkedDocument(id: 1, taskId: 10, projectId: nil, path: path, title: "T",
                       createdAt: Date(), kind: kind, state: .approved)
    }
    private func settings(repo: String? = "/repo", preset: PermissionPreset = .acceptEdits,
                          worktree: Bool = true) -> ProjectLaunchSettings {
        ProjectLaunchSettings(projectId: 3, projectName: "Markdown Pro", repoPath: repo,
                              permissionPreset: preset, useWorktree: worktree)
    }

    func testNoRepoPathThrows() {
        XCTAssertThrowsError(try LaunchScriptBuilder.script(
            task: task(), document: doc(.plan), settings: settings(repo: nil))) { error in
            XCTAssertEqual(error as? LaunchError, .noRepoPath)
        }
    }

    func testProposalIsUnlaunchable() {
        XCTAssertThrowsError(try LaunchScriptBuilder.script(
            task: task(), document: doc(.proposal), settings: settings())) { error in
            XCTAssertEqual(error as? LaunchError, .unlaunchableKind(.proposal))
        }
    }

    func testPlaceholderSubstitutionAndDocRelativePath() throws {
        let s = try LaunchScriptBuilder.script(
            task: task(), document: doc(.plan, path: "/repo/docs/plan.md"), settings: settings())
        // {doc} becomes repo-relative; heredoc carries the prompt verbatim.
        XCTAssertTrue(s.script.contains("@docs/plan.md"), s.script)
        XCTAssertTrue(s.script.contains("MarkdownPro task 10 — Define rejected-proposal semantics"))
        XCTAssertTrue(s.script.contains("cd '/repo' || exit 1"))
    }

    func testUnknownPlaceholderPassesThrough() throws {
        var st = settings()
        st.planPrompt = "keep {task_id} drop {not_a_real_placeholder}"
        let s = try LaunchScriptBuilder.script(task: task(), document: doc(.plan), settings: st)
        XCTAssertTrue(s.script.contains("keep 10 drop {not_a_real_placeholder}"))
    }

    func testSpecNeverGetsWorktreeAndForcesPlanMode() throws {
        let s = try LaunchScriptBuilder.script(
            task: task(), document: doc(.spec), settings: settings(preset: .bypassPermissions, worktree: true))
        XCTAssertFalse(s.command.contains("-w "), "planning must not open a worktree")
        XCTAssertTrue(s.command.contains("--permission-mode plan"))
        XCTAssertNil(s.worktreeSlug)
        XCTAssertFalse(s.isUnsafe, "planning is always plan-mode, never unsafe")
    }

    func testPlanHonorsWorktreeAndPreset() throws {
        let on = try LaunchScriptBuilder.script(
            task: task(), document: doc(.plan), settings: settings(preset: .acceptEdits, worktree: true))
        XCTAssertTrue(on.command.contains("-w 'task-10-define-rejected-proposal-semantics'") ||
                      on.command.contains("-w 'task-10-"), on.command)
        XCTAssertTrue(on.command.contains("--permission-mode acceptEdits"))
        XCTAssertNotNil(on.worktreeSlug)

        let off = try LaunchScriptBuilder.script(
            task: task(), document: doc(.plan), settings: settings(preset: .acceptEdits, worktree: false))
        XCTAssertFalse(off.command.contains("-w "))
        XCTAssertNil(off.worktreeSlug)
    }

    func testUnsafeFlagOnlyForExecuteWithUnsafePreset() throws {
        XCTAssertTrue(try LaunchScriptBuilder.script(
            task: task(), document: doc(.plan), settings: settings(preset: .bypassPermissions)).isUnsafe)
        XCTAssertFalse(try LaunchScriptBuilder.script(
            task: task(), document: doc(.plan), settings: settings(preset: .acceptEdits)).isUnsafe)
    }

    func testInjectionContainment() throws {
        let hostile = "Fix the `rm -rf /` bug; \"drop tables\" $(whoami) '; newline\nhere"
        let s = try LaunchScriptBuilder.script(
            task: task(10, hostile), document: doc(.plan), settings: settings())
        // Prompt is inside a single-quoted heredoc; nothing is shell-interpreted.
        XCTAssertTrue(s.script.contains("<<'MDPRO_PROMPT_EOF'"))
        // The hostile title reaches only the heredoc body, never a shell word.
        XCTAssertTrue(s.script.contains("`rm -rf /`"))
        // repo/slug are single-quoted shell words.
        XCTAssertTrue(s.script.contains("cd '/repo'"))
    }

    func testSlugSanitization() throws {
        let unicode = try LaunchScriptBuilder.script(
            task: task(7, "Café ☕ déjà — vu / ../etc"), document: doc(.plan), settings: settings())
        let slug = unicode.worktreeSlug!
        XCTAssertTrue(slug.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }, slug)
        XCTAssertTrue(slug.hasPrefix("task-7-"))
        XCTAssertFalse(slug.contains(".."))

        let long = try LaunchScriptBuilder.script(
            task: task(7, String(repeating: "ab ", count: 200)), document: doc(.plan), settings: settings())
        XCTAssertLessThanOrEqual(long.worktreeSlug!.count, 48)
    }

    func testPromptContainingDelimiterIsRejected() {
        var st = settings()
        st.planPrompt = "line one\nMDPRO_PROMPT_EOF\nline three"
        XCTAssertThrowsError(try LaunchScriptBuilder.script(
            task: task(), document: doc(.plan), settings: st)) { error in
            XCTAssertEqual(error as? LaunchError, .promptContainsDelimiter)
        }
    }

    func testFakeLauncherRecords() throws {
        let fake = FakeTerminalLauncher()
        let s = try LaunchScriptBuilder.script(task: task(), document: doc(.plan), settings: settings())
        try fake.launch(s)
        XCTAssertEqual(fake.launched.map(\.taskId), [10])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Core && swift test --filter LaunchTests`
Expected: FAIL — `cannot find 'LaunchScriptBuilder' in scope`.

- [ ] **Step 3: Create `LaunchScriptBuilder.swift`**

```swift
import Foundation

/// The composed launch, ready to hand to a TerminalLauncher or show in the
/// confirm sheet. Pure data: no filesystem, no process.
public struct LaunchScript: Sendable, Equatable {
    public let taskId: Int64
    public let kind: DocumentKind
    /// Absolute path to the approved document (checked for existence at present time).
    public let documentPath: String
    /// Warp launch-config + script basename, e.g. "markdownpro-task-10".
    public let configName: String
    public let repoPath: String
    /// nil ⇒ no `-w` (planning, or worktree disabled).
    public let worktreeSlug: String?
    /// The `exec claude …` line, for display.
    public let command: String
    /// The full shell script written to disk / shown in the sheet / copied.
    public let script: String
    public let isUnsafe: Bool
}

public enum LaunchError: Error, CustomStringConvertible, Equatable {
    case noRepoPath
    case unlaunchableKind(DocumentKind)
    case promptContainsDelimiter

    public var description: String {
        switch self {
        case .noRepoPath:
            return "This project has no repo path set."
        case .unlaunchableKind(let kind):
            return "A \(kind.rawValue) document is not launchable (only specs and plans are)."
        case .promptContainsDelimiter:
            return "The prompt contains the heredoc delimiter and cannot be launched safely."
        }
    }
}

/// Composes a launch shell script from a task, its approved document, and the
/// project's launch settings. Pure and deterministic — the whole surface is
/// unit-tested without opening a window.
public struct LaunchScriptBuilder {
    static let heredocDelimiter = "MDPRO_PROMPT_EOF"
    static let slugMaxLength = 48

    public static func script(task: TaskItem,
                              document: LinkedDocument,
                              settings: ProjectLaunchSettings) throws -> LaunchScript {
        guard let repo = settings.repoPath, !repo.isEmpty else { throw LaunchError.noRepoPath }
        guard document.kind == .spec || document.kind == .plan,
              let template = settings.prompt(for: document.kind) else {
            throw LaunchError.unlaunchableKind(document.kind)
        }

        let docAbs = (document.path as NSString).expandingTildeInPath
        let docRel = relativePath(docAbs, under: repo)
        let slug = worktreeSlug(taskId: task.id, title: task.title)

        // Substitute placeholders into the PROMPT only. Every value is untrusted;
        // it only ever reaches the quoted heredoc body — never a shell word.
        let prompt = substitute(template, replacements: [
            "{doc}": docRel,
            "{doc_abs}": docAbs,
            "{task_id}": String(task.id),
            "{task_title}": task.title,
            "{project}": settings.projectName,
            "{slug}": slug,
            "{preset}": settings.permissionPreset.rawValue,
            "{repo}": repo,
        ])

        // The one string a hostile prompt could use to break heredoc containment.
        let promptLines = prompt.components(separatedBy: .newlines)
        guard !promptLines.contains(heredocDelimiter) else { throw LaunchError.promptContainsDelimiter }

        // Flags are structural (not part of the editable prompt). Planning is
        // always plan-mode with no worktree; execution honours settings.
        let usesWorktree = (document.kind == .plan) && settings.useWorktree
        let effectivePreset: PermissionPreset = (document.kind == .spec) ? .plan : settings.permissionPreset
        let commandSlug = usesWorktree ? slug : nil

        var command = "exec claude"
        if let s = commandSlug { command += " -w \(shellQuoted(s))" }
        command += " --permission-mode \(effectivePreset.rawValue) \"$PROMPT\""

        let script = """
            cd \(shellQuoted(repo)) || exit 1
            PROMPT=$(cat <<'\(heredocDelimiter)'
            \(prompt)
            \(heredocDelimiter)
            )
            \(command)
            """

        let isUnsafe = (document.kind == .plan) && settings.permissionPreset.isUnsafe
        return LaunchScript(taskId: task.id, kind: document.kind, documentPath: docAbs,
                            configName: "markdownpro-task-\(task.id)", repoPath: repo,
                            worktreeSlug: commandSlug, command: command,
                            script: script, isUnsafe: isUnsafe)
    }

    // MARK: - Pure helpers

    /// Single-pass `{token}` replacement. Substituted values are never re-scanned,
    /// so a value that looks like a placeholder can't trigger a second replacement;
    /// unknown tokens pass through untouched.
    static func substitute(_ template: String, replacements: [String: String]) -> String {
        var result = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{", let close = template[i...].firstIndex(of: "}") {
                let token = String(template[i...close])          // e.g. "{doc}"
                if let value = replacements[token] {
                    result += value
                    i = template.index(after: close)
                    continue
                }
            }
            result.append(template[i])
            i = template.index(after: i)
        }
        return result
    }

    /// POSIX single-quote: wrap in '…', escaping embedded single quotes as '\''.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// "task-<id>-<slugified title>", sanitized to [a-z0-9-] and length-capped.
    static func worktreeSlug(taskId: Int64, title: String) -> String {
        var chars: [Character] = []
        var lastDash = false
        for ch in title.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                chars.append(ch); lastDash = false
            } else if !lastDash {
                chars.append("-"); lastDash = true
            }
        }
        let prefix = "task-\(taskId)-"
        let budget = max(0, slugMaxLength - prefix.count)
        var body = String(chars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if body.count > budget { body = String(body.prefix(budget)) }
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return body.isEmpty ? "task-\(taskId)" : prefix + body
    }

    /// Path relative to `repo` when contained; otherwise the absolute path.
    static func relativePath(_ path: String, under repo: String) -> String {
        let p = (path as NSString).standardizingPath
        let r = (repo as NSString).standardizingPath
        if p == r { return "." }
        let rSlash = r.hasSuffix("/") ? r : r + "/"
        return p.hasPrefix(rSlash) ? String(p.dropFirst(rSlash.count)) : p
    }
}

/// Runs a composed LaunchScript in a terminal. One conformance ships
/// (WarpLauncher, in the app target); FakeTerminalLauncher backs tests.
public protocol TerminalLauncher {
    func launch(_ script: LaunchScript) throws
}

public final class FakeTerminalLauncher: TerminalLauncher {
    public private(set) var launched: [LaunchScript] = []
    public var errorToThrow: Error?
    public init() {}
    public func launch(_ script: LaunchScript) throws {
        if let e = errorToThrow { throw e }
        launched.append(script)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Core && swift test --filter LaunchTests`
Expected: PASS (all builder + value-type tests).

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/MarkdownProCore/LaunchScriptBuilder.swift Core/Tests/MarkdownProCoreTests/LaunchTests.swift
git commit -m "feat(core): pure LaunchScriptBuilder with injection containment + TerminalLauncher"
```

---

### Task 4: `Repository` — reviewable kinds (submit spec/plan, review queue)

**Files:**
- Modify: `Core/Sources/MarkdownProCore/Repository.swift` (`RepositoryError`, `submitForReview`, `reviewQueue`)
- Test: `Core/Tests/MarkdownProCoreTests/ReviewTests.swift`

**Interfaces:**
- Consumes: `DocumentKind.isReviewable` (Task 1).
- Produces: `submitForReview(taskId:path:title:kind:actor:)` now takes `kind: DocumentKind = .proposal` (throws `RepositoryError.invalidArgument` for a non-reviewable kind); `reviewQueue()` returns docs of any reviewable kind. `RepositoryError` gains `case invalidArgument(String)`.

- [ ] **Step 1: Write the failing tests**

Append to `ReviewTests.swift`:

```swift
extension ReviewTests {
    func testSubmitSpecKindEntersQueue() throws {
        let id = try repo.submitForReview(taskId: taskId, path: "/tmp/spec.md", title: "Spec", kind: .spec)
        XCTAssertEqual(try repo.document(id: id)?.kind, .spec)
        XCTAssertEqual(try repo.document(id: id)?.state, .needsReview)
        XCTAssertTrue(try repo.reviewQueue().contains { $0.document.id == id })
    }

    func testSubmitPlanDoesNotSupersedeApprovedSpec() throws {
        // A task can carry an approved spec AND a plan in review at once; submitting
        // the plan must not supersede the spec (supersede is scoped to same kind).
        let specId = try repo.submitForReview(taskId: taskId, path: "/tmp/spec.md", kind: .spec)
        try repo.applyVerdict(.approve, documentId: specId)
        let planId = try repo.submitForReview(taskId: taskId, path: "/tmp/plan.md", kind: .plan)
        XCTAssertEqual(try repo.document(id: specId)?.state, .approved)
        XCTAssertEqual(try repo.document(id: planId)?.state, .needsReview)
    }

    func testSubmitRejectsNonReviewableKind() {
        XCTAssertThrowsError(try repo.submitForReview(taskId: taskId, path: "/tmp/n.md", kind: .note))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Core && swift test --filter ReviewTests`
Expected: FAIL — `submitForReview` has no `kind:` parameter.

- [ ] **Step 3: Add `invalidArgument` and generalize `submitForReview`**

In `Repository.swift`, extend `RepositoryError`:

```swift
public enum RepositoryError: Error, CustomStringConvertible {
    case notFound(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .notFound(let m): return "not found: \(m)"
        case .invalidArgument(let m): return "invalid argument: \(m)"
        }
    }
}
```

Replace `submitForReview` with a kind-parameterized version (the doc-comment stays accurate):

```swift
@discardableResult
public func submitForReview(taskId: Int64, path: String, title: String? = nil,
                            kind: DocumentKind = .proposal, actor: String = "claude") throws -> Int64 {
    guard kind.isReviewable else {
        throw RepositoryError.invalidArgument("kind \(kind.rawValue) is not reviewable")
    }
    let expanded = (path as NSString).expandingTildeInPath
    let resolvedTitle = title ?? (expanded as NSString).lastPathComponent
    return try db.transaction {
        let existing = try db.query(
            "SELECT id, round, title FROM documents WHERE task_id = ? AND path = ? AND kind = ?",
            [.integer(taskId), .text(expanded), .text(kind.rawValue)]).first
        let docId: Int64
        if let existing {
            docId = existing.int("id")
            let newRound = existing.int("round") + 1
            try db.execute(
                "UPDATE documents SET state = 'needs_review', round = ?, title = ?, updated_at = ? WHERE id = ?",
                [.integer(newRound), title.map { .text($0) } ?? .text(existing.string("title")),
                 .text(now()), .integer(docId)])
            try logActivity(taskId: taskId, actor: actor, kind: "review",
                            message: "resubmitted “\(resolvedTitle)” for review (round \(newRound))")
        } else {
            try db.execute("""
                INSERT INTO documents (task_id, project_id, path, title, created_at, kind, state, round, updated_at)
                VALUES (?, NULL, ?, ?, ?, ?, 'needs_review', 1, ?)
                """,
                [.integer(taskId), .text(expanded), .text(resolvedTitle), .text(now()),
                 .text(kind.rawValue), .text(now())])
            docId = db.lastInsertRowId
            try logActivity(taskId: taskId, actor: actor, kind: "review",
                            message: "submitted “\(resolvedTitle)” for review")
        }
        // Supersede only settled proposals of the SAME kind at other paths, so an
        // approved spec is untouched when a plan is submitted for the same task.
        try db.execute("""
            UPDATE documents SET state = 'superseded', updated_at = ?
            WHERE task_id = ? AND kind = ? AND path != ?
              AND state IN ('approved', 'rejected')
            """,
            [.text(now()), .integer(taskId), .text(kind.rawValue), .text(expanded)])
        try setAttentionColumn(taskId: taskId, TaskAttention.needsReview.rawValue)
        return docId
    }
}
```

- [ ] **Step 4: Widen the review queue to all reviewable kinds**

In `reviewQueue()`, change the `WHERE` clause from `d.kind = 'proposal'` to:

```swift
WHERE d.kind IN ('proposal', 'spec', 'plan') AND d.state = 'needs_review'
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd Core && swift test --filter ReviewTests`
Expected: PASS (existing proposal tests still pass — `kind` defaults to `.proposal`).

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/MarkdownProCore/Repository.swift Core/Tests/MarkdownProCoreTests/ReviewTests.swift
git commit -m "feat(core): submit_for_review accepts spec/plan kinds; review queue widened"
```

---

### Task 5: `Repository` — launch persistence + `TaskItem.launchKind`

**Files:**
- Modify: `Core/Sources/MarkdownProCore/Models.swift` (`TaskItem` gains `launchKind`)
- Modify: `Core/Sources/MarkdownProCore/Repository.swift` (`taskSelect`, `taskItem(from:)`, new launch methods)
- Test: `Core/Tests/MarkdownProCoreTests/LaunchTests.swift`

**Interfaces:**
- Consumes: `ProjectLaunchSettings`, `LaunchTemplates` (Task 2); `DocumentKind` (Task 1).
- Produces on `Repository`:
  - `projectLaunchSettings(_ projectId: Int64) throws -> ProjectLaunchSettings`
  - `setProjectLaunchSettings(_ settings: ProjectLaunchSettings) throws`
  - `recordLaunch(taskId: Int64, kind: DocumentKind, actor: String = "user") throws` — flips attention to `.executing`, logs activity kind `"launch"`.
  - `latestApprovedDocument(taskId: Int64) throws -> LinkedDocument?`
  - `projectIdsWithRepoPath() throws -> Set<Int64>`
  - `TaskItem.launchKind: DocumentKind?` — the kind of the newest approved `spec`/`plan` doc, or nil.

- [ ] **Step 1: Write the failing tests**

Append to `LaunchTests.swift` (uses a real scratch DB like `ReviewTests`):

```swift
final class LaunchRepositoryTests: XCTestCase {
    private var tempPath = ""
    private var repo: Repository!
    private var projectId: Int64 = 0
    private var taskId: Int64 = 0

    override func setUpWithError() throws {
        tempPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mdpro-launch-\(UUID().uuidString).sqlite")
        repo = Repository(db: try Database.open(path: tempPath))
        projectId = try repo.createProject(name: "Markdown Pro")
        taskId = try repo.createTask(projectId: projectId, title: "Do the thing", status: .todo)
    }
    override func tearDownWithError() throws {
        repo = nil
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tempPath + s) }
    }

    func testSettingsDefaultsWhenUnset() throws {
        let s = try repo.projectLaunchSettings(projectId)
        XCTAssertNil(s.repoPath)
        XCTAssertEqual(s.permissionPreset, .acceptEdits)
        XCTAssertTrue(s.useWorktree)
        XCTAssertEqual(s.specPrompt, LaunchTemplates.defaultSpecPrompt)
        XCTAssertEqual(s.projectName, "Markdown Pro")
    }

    func testSettingsRoundTripAndTemplateOverride() throws {
        var s = try repo.projectLaunchSettings(projectId)
        s.repoPath = "/Users/me/repo"
        s.permissionPreset = .bypassPermissions
        s.useWorktree = false
        s.planPrompt = "custom {task_id}"
        try repo.setProjectLaunchSettings(s)

        let reloaded = try repo.projectLaunchSettings(projectId)
        XCTAssertEqual(reloaded.repoPath, "/Users/me/repo")
        XCTAssertEqual(reloaded.permissionPreset, .bypassPermissions)
        XCTAssertFalse(reloaded.useWorktree)
        XCTAssertEqual(reloaded.planPrompt, "custom {task_id}")
        // Spec prompt was left at default → no override row stored.
        XCTAssertEqual(reloaded.specPrompt, LaunchTemplates.defaultSpecPrompt)
        let rows = try repo.db.query(
            "SELECT doc_kind FROM launch_templates WHERE project_id = ?", [.integer(projectId)])
        XCTAssertEqual(rows.map { $0.string("doc_kind") }, ["plan"])
    }

    func testResettingTemplateDeletesOverrideRow() throws {
        var s = try repo.projectLaunchSettings(projectId)
        s.planPrompt = "custom"
        try repo.setProjectLaunchSettings(s)
        s.planPrompt = LaunchTemplates.defaultPlanPrompt          // reset to default
        try repo.setProjectLaunchSettings(s)
        XCTAssertTrue(try repo.db.query(
            "SELECT 1 FROM launch_templates WHERE project_id = ?", [.integer(projectId)]).isEmpty)
    }

    func testProjectIdsWithRepoPath() throws {
        XCTAssertTrue(try repo.projectIdsWithRepoPath().isEmpty)
        var s = try repo.projectLaunchSettings(projectId)
        s.repoPath = "/Users/me/repo"
        try repo.setProjectLaunchSettings(s)
        XCTAssertEqual(try repo.projectIdsWithRepoPath(), [projectId])
    }

    func testRecordLaunchSetsExecutingAndLogs() throws {
        try repo.recordLaunch(taskId: taskId, kind: .plan)
        XCTAssertEqual(try repo.getTask(id: taskId)?.task.attention, .executing)
        XCTAssertTrue(try repo.getTask(id: taskId)!.activity
            .contains { $0.actor == "user" && $0.kind == "launch" })
    }

    func testLatestApprovedDocumentAndLaunchKind() throws {
        let specId = try repo.submitForReview(taskId: taskId, path: "/tmp/spec.md", kind: .spec)
        try repo.applyVerdict(.approve, documentId: specId)
        let latest = try repo.latestApprovedDocument(taskId: taskId)
        XCTAssertEqual(latest?.kind, .spec)
        // TaskItem now exposes launchKind for the button gate.
        XCTAssertEqual(try repo.getTask(id: taskId)?.task.launchKind, .spec)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Core && swift test --filter LaunchRepositoryTests`
Expected: FAIL — `projectLaunchSettings` / `launchKind` do not exist.

- [ ] **Step 3: Add `launchKind` to `TaskItem`**

In `Models.swift`, in `struct TaskItem`, add the stored property after `attention`:

```swift
    public var attention: TaskAttention?
    /// Kind of the newest approved spec/plan document, if any — gates the Launch button.
    public var launchKind: DocumentKind?
```

And extend the initializer: add the parameter (with a default so existing call sites keep compiling) and the assignment:

```swift
    public init(id: Int64, projectId: Int64, title: String, details: String,
                status: TaskStatus, priority: TaskPriority, dueDate: Date?,
                sortOrder: Double, createdAt: Date, updatedAt: Date,
                labels: [Label] = [], subtaskCount: Int = 0, subtaskDoneCount: Int = 0,
                documentCount: Int = 0, attention: TaskAttention? = nil,
                launchKind: DocumentKind? = nil) {
        // …existing assignments…
        self.attention = attention
        self.launchKind = launchKind
    }
```

- [ ] **Step 4: Populate `launchKind` in the shared task select**

In `Repository.swift`, extend `taskSelect` with a correlated subquery (add it inside the `SELECT t.*,` list):

```swift
    private static let taskSelect = """
        SELECT t.*,
               (SELECT COUNT(*) FROM subtasks s WHERE s.task_id = t.id) AS subtask_count,
               (SELECT COUNT(*) FROM subtasks s WHERE s.task_id = t.id AND s.done = 1) AS subtask_done_count,
               (SELECT COUNT(*) FROM documents d WHERE d.task_id = t.id) AS document_count,
               (SELECT d.kind FROM documents d
                  WHERE d.task_id = t.id AND d.state = 'approved' AND d.kind IN ('spec','plan')
                  ORDER BY COALESCE(d.updated_at, d.created_at) DESC, d.id DESC LIMIT 1) AS launch_kind
        FROM tasks t
        """
```

And in `taskItem(from:)`, set the field:

```swift
                 attention: r.stringOrNil("attention").flatMap(TaskAttention.init(rawValue:)),
                 launchKind: r.stringOrNil("launch_kind").flatMap(DocumentKind.init(rawValue:)))
```

- [ ] **Step 5: Add the launch persistence methods**

In `Repository.swift`, add a new `// MARK: - Launch` section (e.g. after the `// MARK: Queue` block, before `// MARK: - Import`):

```swift
    // MARK: - Launch

    public func projectLaunchSettings(_ projectId: Int64) throws -> ProjectLaunchSettings {
        guard let row = try db.query("""
            SELECT id, name, repo_path, permission_preset, use_worktree
            FROM projects WHERE id = ?
            """, [.integer(projectId)]).first else {
            throw RepositoryError.notFound("project \(projectId)")
        }
        var specPrompt = LaunchTemplates.defaultSpecPrompt
        var planPrompt = LaunchTemplates.defaultPlanPrompt
        for t in try db.query("SELECT doc_kind, command FROM launch_templates WHERE project_id = ?",
                              [.integer(projectId)]) {
            switch t.string("doc_kind") {
            case "spec": specPrompt = t.string("command")
            case "plan": planPrompt = t.string("command")
            default: break
            }
        }
        return ProjectLaunchSettings(
            projectId: projectId,
            projectName: row.string("name"),
            repoPath: row.stringOrNil("repo_path").flatMap { $0.isEmpty ? nil : $0 },
            permissionPreset: PermissionPreset(rawValue: row.string("permission_preset")) ?? .acceptEdits,
            useWorktree: row.bool("use_worktree"),
            specPrompt: specPrompt,
            planPrompt: planPrompt)
    }

    public func setProjectLaunchSettings(_ s: ProjectLaunchSettings) throws {
        try db.transaction {
            try db.execute("""
                UPDATE projects SET repo_path = ?, permission_preset = ?, use_worktree = ?, updated_at = ?
                WHERE id = ?
                """,
                [s.repoPath.map { .text($0) } ?? .null, .text(s.permissionPreset.rawValue),
                 .integer(s.useWorktree ? 1 : 0), .text(now()), .integer(s.projectId)])
            try upsertLaunchTemplate(projectId: s.projectId, kind: .spec,
                                     prompt: s.specPrompt, default: LaunchTemplates.defaultSpecPrompt)
            try upsertLaunchTemplate(projectId: s.projectId, kind: .plan,
                                     prompt: s.planPrompt, default: LaunchTemplates.defaultPlanPrompt)
        }
    }

    /// A row exists only when a template differs from its built-in default;
    /// resetting to the default removes the row.
    private func upsertLaunchTemplate(projectId: Int64, kind: DocumentKind,
                                      prompt: String, default def: String) throws {
        if prompt == def {
            try db.execute("DELETE FROM launch_templates WHERE project_id = ? AND doc_kind = ?",
                           [.integer(projectId), .text(kind.rawValue)])
        } else {
            try db.execute("""
                INSERT INTO launch_templates (project_id, doc_kind, command) VALUES (?, ?, ?)
                ON CONFLICT(project_id, doc_kind) DO UPDATE SET command = excluded.command
                """, [.integer(projectId), .text(kind.rawValue), .text(prompt)])
        }
    }

    public func projectIdsWithRepoPath() throws -> Set<Int64> {
        Set(try db.query("SELECT id FROM projects WHERE repo_path IS NOT NULL AND repo_path != ''")
            .map { $0.int("id") })
    }

    /// The newest approved reviewable document for a task — what the Launch
    /// button acts on.
    public func latestApprovedDocument(taskId: Int64) throws -> LinkedDocument? {
        try db.query("""
            SELECT * FROM documents
            WHERE task_id = ? AND state = 'approved' AND kind IN ('proposal','spec','plan')
            ORDER BY COALESCE(updated_at, created_at) DESC, id DESC LIMIT 1
            """, [.integer(taskId)]).first.map(linkedDocument(from:))
    }

    /// Records that a Claude Code session was launched: attention → executing,
    /// plus an activity row. `TaskAttention.executing` finally gains a writer.
    public func recordLaunch(taskId: Int64, kind: DocumentKind, actor: String = "user") throws {
        try db.transaction {
            try setAttentionColumn(taskId: taskId, TaskAttention.executing.rawValue)
            let what = (kind == .spec) ? "planning" : "execution"
            try logActivity(taskId: taskId, actor: actor, kind: "launch",
                            message: "launched a Claude Code \(what) session")
        }
    }
```

- [ ] **Step 6: Run to verify it passes**

Run: `cd Core && swift test`
Expected: PASS — the whole Core suite (the `launch_kind` column change is exercised by every task read).

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/MarkdownProCore/Models.swift Core/Sources/MarkdownProCore/Repository.swift Core/Tests/MarkdownProCoreTests/LaunchTests.swift
git commit -m "feat(core): project launch settings, recordLaunch, TaskItem.launchKind"
```

---

### Task 6: MCP — `submit_for_review` gains `kind`; guards use `isReviewable`

**Files:**
- Modify: `mcp-server/Sources/markdownpro-mcp/MCPServer.swift` (`submit_for_review`, `attach_document`, `get_task`)
- Modify: `mcp-server/Sources/markdownpro-mcp/ToolCatalog.swift` (`submit_for_review` schema)

**Interfaces:**
- Consumes: `Repository.submitForReview(…, kind:)` (Task 4), `DocumentKind.isReviewable` (Task 1).
- Produces: the `submit_for_review` MCP tool accepts an optional `kind` (`proposal` | `spec` | `plan`, default `proposal`); `attach_document` rejects all reviewable kinds; `get_task` counts open annotations for any reviewable kind.

- [ ] **Step 1: Update `submit_for_review` in `MCPServer.swift`**

Replace the `case "submit_for_review":` body so it parses and validates `kind`:

```swift
        case "submit_for_review":
            let taskId = try requireInt(args, "task_id")
            let path = try requireString(args, "path")
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ToolError.badArgument("file does not exist: \(expanded)")
            }
            guard try repo.getTask(id: taskId) != nil else { throw ToolError.notFound("task \(taskId)") }
            var kind = DocumentKind.proposal
            if let raw = string(args, "kind") {
                guard let parsed = DocumentKind(rawValue: raw), parsed.isReviewable else {
                    throw ToolError.badArgument("kind must be one of proposal|spec|plan")
                }
                kind = parsed
            }
            let docId = try repo.submitForReview(taskId: taskId, path: expanded,
                                                 title: string(args, "title"), kind: kind)
            guard let doc = try repo.document(id: docId) else { throw ToolError.notFound("document \(docId)") }
            return jsonText(["document_id": docId, "state": "needs_review", "round": doc.round,
                             "kind": doc.kind.rawValue,
                             "message": "Submitted “\(doc.title)” for review (round \(doc.round))"])
```

- [ ] **Step 2: Widen the `attach_document` guard and `get_task` annotation count**

In `case "attach_document":`, replace the kind guard:

```swift
            var kind = DocumentKind.note
            if let raw = string(args, "kind") {
                guard let parsed = DocumentKind(rawValue: raw), !parsed.isReviewable else {
                    throw ToolError.badArgument("kind must be note or wiki (proposals/specs/plans go through submit_for_review)")
                }
                kind = parsed
            }
```

In `case "get_task":`, replace `if doc.kind == .proposal {` with:

```swift
                if doc.kind.isReviewable {
```

- [ ] **Step 3: Add `kind` to the `submit_for_review` schema**

In `ToolCatalog.swift`, update the `submit_for_review` tool definition's description and properties:

```swift
        tool("submit_for_review",
             "Submit a markdown document for the user's review. Registers the file on the task, " +
             "flags the task needs_review, and puts it in the app's Review queue. Use kind=spec for a " +
             "design/spec, kind=plan for an implementation plan, or the default proposal otherwise. " +
             "Resubmitting the same file after addressing feedback starts a new round.",
             properties: [
                "task_id": ["type": "integer", "description": "Task the document belongs to"],
                "path": ["type": "string", "description": "Absolute path to the .md file (must exist)"],
                "title": ["type": "string", "description": "Display title (defaults to file name)"],
                "kind": ["type": "string", "enum": ["proposal", "spec", "plan"],
                         "description": "Review stage (default proposal). Only spec and plan arm a Launch button."]
             ],
             required: ["task_id", "path"]),
```

- [ ] **Step 4: Build the MCP server and drive it end-to-end**

Run: `cd mcp-server && swift build -c release`
Expected: builds cleanly.

Then exercise the new `kind` against a scratch DB (a task must exist first — create one via the app or a `create_task` call):

```bash
export MARKDOWNPRO_DB=/tmp/mcp-launch.sqlite
printf '# spec\n' > /tmp/spec.md
# List tools shows the kind enum:
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./.build/release/markdownpro-mcp | grep -o '"proposal","spec","plan"'
```

Expected: the grep prints `"proposal","spec","plan"`, confirming the schema advertises the new enum.

- [ ] **Step 5: Commit**

```bash
git add mcp-server/Sources/markdownpro-mcp/MCPServer.swift mcp-server/Sources/markdownpro-mcp/ToolCatalog.swift
git commit -m "feat(mcp): submit_for_review kind param; reviewable-kind guards"
```

---

### Task 7: App — Store launch orchestration + `WarpLauncher`

**Files:**
- Create: `MarkdownPro/Launch/WarpLauncher.swift`
- Modify: `MarkdownPro/Store.swift` (`ActiveSheet`, launch state + methods, `refresh`)

**Interfaces:**
- Consumes: `LaunchScriptBuilder`, `LaunchScript`, `TerminalLauncher` (Task 3); `Repository` launch methods (Task 5).
- Produces:
  - `WarpLauncher: TerminalLauncher` with `static var isAvailable: Bool` and `static func launchConfigYAML(name:cwd:scriptPath:) -> String`.
  - `Store.LaunchRequest` (`script: LaunchScript`, `taskTitle: String`, `warpAvailable: Bool`).
  - `Store.ActiveSheet` gains `.projectSettings(Int64)` and `.launch(LaunchRequest)`.
  - `Store.launchableProjects: Set<Int64>` (published), `beginLaunch(task:)`, `confirmLaunch(_:)`, `clearAttention(taskId:)`, `projectLaunchSettings(_:)`, `saveProjectLaunchSettings(_:)`.

- [ ] **Step 1: Create `WarpLauncher.swift`**

```swift
import AppKit
import MarkdownProCore

/// Writes a launch script + a Warp launch configuration, then opens
/// warp://launch/<name> so a new Warp window runs the script in a login shell
/// (so PATH is the user's and `claude` resolves). See spec "Why a script and
/// not Process".
struct WarpLauncher: TerminalLauncher {
    /// True when some app handles the warp:// URL scheme.
    static var isAvailable: Bool {
        guard let url = URL(string: "warp://") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    func launch(_ script: LaunchScript) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let launchDir = support.appendingPathComponent("MarkdownPro/launch", isDirectory: true)
        try FileManager.default.createDirectory(at: launchDir, withIntermediateDirectories: true)

        let scriptURL = launchDir.appendingPathComponent("\(script.configName).sh")
        try script.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let warpDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".warp/launch_configurations", isDirectory: true)
        try FileManager.default.createDirectory(at: warpDir, withIntermediateDirectories: true)
        let yaml = Self.launchConfigYAML(name: script.configName, cwd: script.repoPath, scriptPath: scriptURL.path)
        try yaml.write(to: warpDir.appendingPathComponent("\(script.configName).yaml"),
                       atomically: true, encoding: .utf8)

        // configName is ascii (markdownpro-task-N) so the URL needs no escaping.
        guard let uri = URL(string: "warp://launch/\(script.configName)") else { return }
        NSWorkspace.shared.open(uri)
    }

    /// Warp launch-configuration YAML. The schema is external/versioned — confirm
    /// against the running Warp in QA §10 and adjust if Warp changes it.
    static func launchConfigYAML(name: String, cwd: String, scriptPath: String) -> String {
        """
        ---
        name: \(name)
        windows:
          - tabs:
              - layout:
                  cwd: "\(cwd)"
                  commands:
                    - exec: sh "\(scriptPath)"
        """
    }
}
```

- [ ] **Step 2: Extend `Store.ActiveSheet` and add the `LaunchRequest` type**

In `Store.swift`, replace the `ActiveSheet` enum:

```swift
    enum ActiveSheet: Identifiable {
        case export(preselected: Set<Int64>)
        case importBundle(ImportPreview, URL)
        case projectSettings(Int64)
        case launch(LaunchRequest)

        var id: String {
            switch self {
            case .export: return "export"
            case .importBundle(_, let url): return "import:\(url.path)"
            case .projectSettings(let id): return "settings:\(id)"
            case .launch(let req): return "launch:\(req.script.taskId)"
            }
        }
    }

    struct LaunchRequest {
        let script: LaunchScript
        let taskTitle: String
        let warpAvailable: Bool
    }
```

- [ ] **Step 3: Add launch state and methods to `Store`**

Add a published set near the other `@Published` properties:

```swift
    /// Project ids that have a repo path set — gates the Launch button's enabled state.
    @Published private(set) var launchableProjects: Set<Int64> = []
```

Add a launcher stored property beside `repo`:

```swift
    private let launcher: TerminalLauncher = WarpLauncher()
```

In `refresh()`, after `reviewQueue = queue`, populate the set:

```swift
            launchableProjects = (try? repo.projectIdsWithRepoPath()) ?? []
```

Add the launch methods in the `// MARK: - Review` section (or a new `// MARK: - Launch`):

```swift
    // MARK: - Launch

    func projectLaunchSettings(_ projectId: Int64) -> ProjectLaunchSettings? {
        guard let repo else { return nil }
        return try? repo.projectLaunchSettings(projectId)
    }

    func saveProjectLaunchSettings(_ settings: ProjectLaunchSettings) {
        perform { try $0.setProjectLaunchSettings(settings) }
    }

    /// Compose the script for a ready-to-execute task and present the confirm sheet.
    func beginLaunch(task: TaskItem) {
        guard let repo else { return }
        do {
            let settings = try repo.projectLaunchSettings(task.projectId)
            guard let document = try repo.latestApprovedDocument(taskId: task.id) else {
                errorMessage = "No approved document to launch for this task."
                return
            }
            let script = try LaunchScriptBuilder.script(task: task, document: document, settings: settings)
            activeSheet = .launch(LaunchRequest(script: script, taskTitle: task.title,
                                                warpAvailable: WarpLauncher.isAvailable))
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Run the composed script and record the launch (attention → executing).
    func confirmLaunch(_ request: LaunchRequest) {
        guard let repo else { return }
        do {
            try launcher.launch(request.script)
            try repo.recordLaunch(taskId: request.script.taskId, kind: request.script.kind)
            activeSheet = nil
            refresh()
        } catch {
            errorMessage = "Launch failed: \(error)"
        }
    }

    func clearAttention(taskId: Int64) {
        perform { try $0.setAttention(taskId: taskId, attention: nil, actor: "user") }
    }
```

- [ ] **Step 4: Build the app**

Run: `xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build`
Expected: BUILD SUCCEEDED (no UI wired yet — Tasks 8–9 add the surfaces).

- [ ] **Step 5: Commit**

```bash
git add MarkdownPro/Launch/WarpLauncher.swift MarkdownPro/Store.swift
git commit -m "feat(app): Store launch orchestration + WarpLauncher"
```

---

### Task 8: App — Launch button (card + detail) and confirm sheet

**Files:**
- Create: `MarkdownPro/Views/LaunchViews.swift` (the `LaunchButton` and `LaunchConfirmSheet`)
- Modify: `MarkdownPro/Views/ProjectView.swift` (`TaskCardView` shows the button)
- Modify: `MarkdownPro/Views/TaskDetailView.swift` (header shows the button + "Clear attention")
- Modify: `MarkdownPro/Views/ContentView.swift` (present `.launch` in the `activeSheet` switch)

**Interfaces:**
- Consumes: `Store.beginLaunch`, `Store.confirmLaunch`, `Store.launchableProjects`, `Store.activeSheet` (Task 7); `TaskItem.launchKind`, `.attention` (Task 5).
- Produces: `LaunchButton` (visible only when `attention == .readyToExecute && launchKind != nil`) and `LaunchConfirmSheet(request:)`.

- [ ] **Step 1: Create `LaunchViews.swift`**

```swift
import SwiftUI
import AppKit
import MarkdownProCore

/// Shown when a task is ready to execute and its approved document is launchable.
/// With a repo path it launches; without one it links to project settings — a
/// button that explains itself beats a hidden one.
struct LaunchButton: View {
    @EnvironmentObject private var store: Store
    let task: TaskItem
    var compact = false

    var body: some View {
        if task.attention == .readyToExecute, task.launchKind != nil {
            let hasRepo = store.launchableProjects.contains(task.projectId)
            Button {
                if hasRepo { store.beginLaunch(task: task) }
                else { store.activeSheet = .projectSettings(task.projectId) }
            } label: {
                if compact {
                    SwiftUI.Label("Launch", systemImage: "play.fill").labelStyle(.iconOnly)
                } else {
                    SwiftUI.Label(hasRepo ? "Launch" : "Set repo path…", systemImage: "play.fill")
                }
            }
            .controlSize(.small)
            .buttonStyle(hasRepo ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
            .tint(hasRepo ? .green : .secondary)
            .help(hasRepo ? "Launch a Claude Code session for this task"
                          : "Set the project repo path to enable launch")
            .accessibilityIdentifier("launchButton-\(task.id)")
        }
    }
}

/// Type-erases the two button styles so the ternary above type-checks.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Confirm sheet: always shows the exact composed script; warns on unsafe presets;
/// degrades to Copy-only when Warp is missing or the document has vanished.
struct LaunchConfirmSheet: View {
    @EnvironmentObject private var store: Store
    let request: Store.LaunchRequest

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: request.script.documentPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Launch Claude Code")
                .font(.headline)
            Text(request.taskTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if request.script.isUnsafe { unsafeBand }

            ScrollView {
                Text(request.script.script)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            if !fileExists {
                SwiftUI.Label("The document no longer exists on disk — nothing to launch.",
                              systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Copy") { copyScript() }
                    .help("Copy the script to run manually")
                Spacer()
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                if request.warpAvailable {
                    runButton
                } else {
                    Text("Warp not found — copy and run manually")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    // Run is focused (Return) only for safe presets; unsafe presets must cost a deliberate click.
    @ViewBuilder private var runButton: some View {
        if request.script.isUnsafe {
            Button("Run") { store.confirmLaunch(request) }
                .buttonStyle(.borderedProminent)
                .disabled(!fileExists)
                .accessibilityIdentifier("launchRunButton")
        } else {
            Button("Run") { store.confirmLaunch(request) }
                .buttonStyle(.borderedProminent)
                .disabled(!fileExists)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("launchRunButton")
        }
    }

    private var unsafeBand: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.red)
            Text("Permission mode “\(request.script.command.contains("--permission-mode ") ? presetName : "")” lets the agent act without asking. Review the command before running.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
    }

    private var presetName: String {
        // Pull the mode out of the exec line for the warning copy.
        guard let range = request.script.command.range(of: "--permission-mode ") else { return "" }
        return request.script.command[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
    }

    private func copyScript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.script.script, forType: .string)
    }
}
```

- [ ] **Step 2: Show the button on the board card**

In `ProjectView.swift`, `struct TaskCardView` currently has only `let task`. Add the store and the button. Add at the top of the struct:

```swift
struct TaskCardView: View {
    @EnvironmentObject private var store: Store
    let task: TaskItem
```

Then, inside `body`, right after the `if let attention = task.attention { AttentionChip(…) }` block, add:

```swift
            LaunchButton(task: task)
```

- [ ] **Step 3: Show the button + Clear attention in task detail**

In `TaskDetailView.swift`, inside `content(_:)`, in the status/priority/due `HStack`, after the existing attention chip block, add the launch button; and add a "Clear attention" affordance when executing. Replace the `if let attention = detail.task.attention { … }` block with:

```swift
                        if let attention = detail.task.attention {
                            AttentionChip(text: attention.displayName,
                                          icon: attention.iconName,
                                          color: attention.color)
                            if attention == .executing {
                                Button("Clear") {
                                    store.clearAttention(taskId: taskId)
                                    reload()
                                }
                                .controlSize(.small)
                                .help("Clear the Executing flag if the session was stopped")
                            }
                        }
                        LaunchButton(task: detail.task)
```

- [ ] **Step 4: Present the launch sheet**

In `ContentView.swift`, extend the `.sheet(item: $store.activeSheet)` switch with the launch case (project settings arrives in Task 9):

```swift
            case .launch(let request):
                LaunchConfirmSheet(request: request)
                    .environmentObject(store)
```

- [ ] **Step 5: Build the app**

Run: `xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build`
Expected: BUILD SUCCEEDED. (A missing `.projectSettings` case in the switch will error — add a temporary `case .projectSettings: EmptyView()` if needed; Task 9 replaces it.)

- [ ] **Step 6: Commit**

```bash
git add MarkdownPro/Views/LaunchViews.swift MarkdownPro/Views/ProjectView.swift MarkdownPro/Views/TaskDetailView.swift MarkdownPro/Views/ContentView.swift
git commit -m "feat(app): Launch button on card/detail + confirm sheet"
```

---

### Task 9: App — Project settings sheet + wiring

**Files:**
- Create: `MarkdownPro/Views/ProjectSettingsSheet.swift`
- Modify: `MarkdownPro/Views/ContentView.swift` (`.projectSettings` case + sidebar context-menu entry)

**Interfaces:**
- Consumes: `Store.projectLaunchSettings`, `Store.saveProjectLaunchSettings` (Task 7); `ProjectLaunchSettings`, `PermissionPreset`, `LaunchTemplates` (Task 2).
- Produces: `ProjectSettingsSheet(projectId:)` presented via `ActiveSheet.projectSettings`.

- [ ] **Step 1: Create `ProjectSettingsSheet.swift`**

```swift
import SwiftUI
import AppKit
import MarkdownProCore

/// Per-project launch configuration: repo path, permission preset, worktree
/// toggle, and the two editable prompt templates with reset-to-default.
struct ProjectSettingsSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let projectId: Int64

    @State private var settings: ProjectLaunchSettings?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Project Launch Settings").font(.headline)
                Spacer()
                Button("Done") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if let binding = Binding($settings) {
                form(binding)
            } else {
                ContentUnavailableView("Project not found", systemImage: "folder.badge.questionmark")
                    .frame(height: 200)
            }
        }
        .frame(width: 620, height: 620)
        .onAppear { settings = store.projectLaunchSettings(projectId) }
    }

    private func form(_ s: Binding<ProjectLaunchSettings>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Repository") {
                    HStack {
                        Text(s.wrappedValue.repoPath ?? "No repo path set")
                            .foregroundStyle(s.wrappedValue.repoPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if s.wrappedValue.repoPath != nil {
                            Button("Clear") { s.wrappedValue.repoPath = nil }
                                .controlSize(.small)
                        }
                        Button("Choose…") { chooseRepo(s) }
                            .controlSize(.small)
                    }
                    Text("The working directory a launched session cd's into. Without it, Launch is disabled.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("Permissions") {
                    Picker("Permission mode", selection: s.permissionPreset) {
                        ForEach(PermissionPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .fixedSize()
                    if s.wrappedValue.permissionPreset.isUnsafe {
                        SwiftUI.Label("This mode lets the agent act without asking on execute launches.",
                                      systemImage: "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Use a git worktree for execute launches (-w)", isOn: s.useWorktree)
                }

                templateSection("Spec prompt (planning)", text: s.specPrompt,
                                 isDefault: s.wrappedValue.specPrompt == LaunchTemplates.defaultSpecPrompt) {
                    s.wrappedValue.specPrompt = LaunchTemplates.defaultSpecPrompt
                }
                templateSection("Plan prompt (execution)", text: s.planPrompt,
                                 isDefault: s.wrappedValue.planPrompt == LaunchTemplates.defaultPlanPrompt) {
                    s.wrappedValue.planPrompt = LaunchTemplates.defaultPlanPrompt
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            body()
        }
    }

    @ViewBuilder
    private func templateSection(_ title: String, text: Binding<String>,
                                 isDefault: Bool, reset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset to default", action: reset)
                    .controlSize(.small)
                    .disabled(isDefault)
            }
            TextEditor(text: text)
                .font(.body.monospaced())
                .frame(height: 96)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            Text("Placeholders: {doc} {doc_abs} {task_id} {task_title} {project} {slug} {preset} {repo}")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func chooseRepo(_ s: Binding<ProjectLaunchSettings>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            s.wrappedValue.repoPath = url.path
        }
    }

    private func save() {
        if let settings { store.saveProjectLaunchSettings(settings) }
    }
}
```

- [ ] **Step 2: Present the sheet and add the sidebar entry**

In `ContentView.swift`, replace any temporary `.projectSettings` case in the `activeSheet` switch with:

```swift
            case .projectSettings(let id):
                ProjectSettingsSheet(projectId: id)
                    .environmentObject(store)
```

And in `SidebarView`, add a "Project Settings…" button to the project `contextMenu`, before the `Divider()`:

```swift
                    .contextMenu {
                        Button("Project Settings…") {
                            store.activeSheet = .projectSettings(project.id)
                        }
                        Button("Export…") {
                            store.activeSheet = .export(preselected: [project.id])
                        }
                        Divider()
                        Button("Delete Project", role: .destructive) {
                            if case .project(project.id) = selection { selection = .stats }
                            store.deleteProject(id: project.id)
                        }
                    }
```

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project MarkdownPro.xcodeproj -scheme MarkdownPro -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual smoke test end-to-end**

Launch against a scratch DB so the real board is untouched:

```bash
MARKDOWNPRO_DB=/tmp/mdpro-launch.sqlite \
  open ~/Library/Developer/Xcode/DerivedData/MarkdownPro-*/Build/Products/Debug/MarkdownPro.app
```

Verify: right-click a project → **Project Settings…** → set repo path to this repo, pick a preset, edit and reset a template. Then submit a `spec` via the MCP server (`submit_for_review … kind=spec`), approve it in Review, and confirm a green **Launch** appears on the card and in detail; clicking it opens the confirm sheet with the exact script.

- [ ] **Step 5: Commit**

```bash
git add MarkdownPro/Views/ProjectSettingsSheet.swift MarkdownPro/Views/ContentView.swift
git commit -m "feat(app): project launch settings sheet + sidebar entry"
```

---

### Task 10: QA checklist — the interactive launch pass

**Files:**
- Modify: `docs/QA_CHECKLIST.md` (append a new section)

**Interfaces:**
- Consumes: everything above.
- Produces: a repeatable manual pass. The spec calls this "§9"; §9 is already Export/import, so this appends as **§10 Launch** (note the numbering divergence).

- [ ] **Step 1: Append the §10 section**

Add to the end of `docs/QA_CHECKLIST.md`:

```markdown
## §10 Launch (Claude Code from Review)

Setup: scratch DB (`MARKDOWNPRO_DB=/tmp/qa-launch.sqlite`), one project. Right-click
the project → **Project Settings…** → set the repo path to a real git repo.

- [ ] With no repo path, an approved spec/plan shows a **Set repo path…** button
      that opens Project Settings; setting a path turns it into a green **Launch**.
- [ ] Submitting `kind=spec` via `submit_for_review` puts the doc in Review; the
      queue row and document render as before.
- [ ] Approving the spec arms **Launch** on the card and in task detail; approving
      a plain `proposal` arms **no** Launch button.
- [ ] Launch opens a sheet showing the exact script: `cd '<repo>'`, a quoted
      `<<'MDPRO_PROMPT_EOF'` heredoc carrying the prompt, and the `exec claude` line.
- [ ] A spec launch has **no** `-w` and `--permission-mode plan`; a plan launch with
      the worktree toggle on has `-w 'task-N-…'` and the project's preset.
- [ ] With an unsafe preset (auto/dontAsk/bypassPermissions) on a plan launch, the
      sheet shows a red warning band and Return does **not** trigger Run.
- [ ] **Copy** puts the script on the clipboard; pasting into a terminal and running
      it starts the session.
- [ ] **Run** opens a new Warp window in the repo dir running `claude`; the task chip
      flips to **Executing** and the activity log shows a `launch` entry (You).
- [ ] With Warp not installed, Run is replaced by "Warp not found — copy and run
      manually" and Copy still works.
- [ ] If the approved document is deleted from disk, the sheet still opens but Run is
      disabled with a "no longer exists" note.
- [ ] A task stuck **Executing** (session killed) can be cleared via the **Clear**
      button next to the chip in task detail.
- [ ] Editing a project template then **Reset to default** restores the built-in
      prompt and removes the override (relaunch shows the default in the sheet).
```

- [ ] **Step 2: Commit**

```bash
git add docs/QA_CHECKLIST.md
git commit -m "docs: QA §10 for launching Claude Code from Review"
```

---

## Self-Review

**Spec coverage:**
- Armed Launch button, not an approve side-effect → Tasks 5 (`launchKind` gate), 8 (button), attention only flips on Run (Task 5 `recordLaunch`, Task 7 `confirmLaunch`). ✓
- Couple to superpowers via editable templates → Tasks 2 (defaults), 5 (persistence), 9 (editor). ✓ (Refined: templates are prompts; flags structural — documented above.)
- Dangerous presets cost a deliberate click → Task 3 (`isUnsafe`), 8 (warning band, Run not focused). ✓
- Generated shell script invoked by Warp launch config → Tasks 3 (script), 7 (WarpLauncher). ✓
- Schema v3 (three ALTERs + `launch_templates`, user_version 3) → Task 1. ✓
- `DocumentKind` gains spec/plan (Swift-only) → Task 1. ✓
- Default superpowers profile → Task 2. ✓
- MCP `submit_for_review` optional `kind`; still rejects note/wiki → Task 6. ✓
- Existing proposals keep working, strictly additive → default `kind = .proposal` (Tasks 4, 6); proposal arms no Launch (Task 5 `launch_kind` filters `spec`/`plan`). ✓
- Pure `LaunchScriptBuilder` + injection containment + heredoc-delimiter rejection → Task 3. ✓
- `Repository.projectLaunchSettings/setProjectLaunchSettings/recordLaunch` → Task 5. ✓
- `TerminalLauncher` + `WarpLauncher` + `FakeTerminalLauncher` → Tasks 3, 7. ✓
- UI: Launch button (detail + card), confirm sheet, project settings → Tasks 8, 9. ✓
- Closing the loop + "Clear attention" escape hatch → Tasks 5, 8. ✓
- Error handling table (no repo, missing doc, Warp missing, write fails, silent open) → Tasks 3/7/8 (missing-doc disables Run; Warp-missing degrades to Copy; write/launch failures surface via `errorMessage`). ✓
- Testing list (placeholders, injection, slug, kind→flags, override beats default, recordLaunch) → Tasks 3, 5. ✓ Plus QA §10 (Task 10). ✓

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N" — every code step is complete. The one externally-uncertain artifact (Warp launch-config YAML) is written concretely in Task 7 and flagged for confirmation in QA §10; that's an honest external-schema caveat, not a plan placeholder.

**Type consistency:** `LaunchScript`, `ProjectLaunchSettings`, `PermissionPreset`, `DocumentKind.isReviewable`, `TaskItem.launchKind`, `Store.LaunchRequest`, `Repository.submitForReview(…, kind:)`, `recordLaunch(taskId:kind:)`, `latestApprovedDocument(taskId:)`, `projectIdsWithRepoPath()`, `ActiveSheet.launch/.projectSettings` are named identically across producing and consuming tasks.
