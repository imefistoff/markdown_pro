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
            Text("Permission mode “\(presetName)” lets the agent act without asking. Review the command before running.")
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
