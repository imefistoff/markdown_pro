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
