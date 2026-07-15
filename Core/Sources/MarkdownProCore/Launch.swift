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
        case .note, .wiki, .proposal: return nil
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
        case .note, .wiki, .proposal: return nil
        }
    }
}
