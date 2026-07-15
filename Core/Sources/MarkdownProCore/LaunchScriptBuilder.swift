import Foundation

/// The composed launch, ready to hand to a TerminalLauncher or show in the
/// confirm sheet. Pure data: no filesystem, no process.
public struct LaunchScript: Sendable, Equatable {
    public let taskId: Int64
    public let kind: DocumentKind
    /// Absolute path to the approved document. Existence is checked later, by
    /// the confirm sheet — this builder is pure and checks nothing.
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
