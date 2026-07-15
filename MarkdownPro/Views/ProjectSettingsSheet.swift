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
