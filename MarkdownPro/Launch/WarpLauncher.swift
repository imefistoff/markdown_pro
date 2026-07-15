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
