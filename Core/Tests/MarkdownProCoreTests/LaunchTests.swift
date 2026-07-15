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
