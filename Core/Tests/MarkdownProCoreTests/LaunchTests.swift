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
