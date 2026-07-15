import SwiftUI
import AppKit
import MarkdownProCore

/// Surfaced as the app's Settings scene (⌘,): pick the folder both Macs point
/// at (Dropbox/Syncthing/etc.) and adopt projects another machine has synced
/// there. Per-project opt-in lives on `ProjectView`.
struct SyncSettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync").font(.title2.bold())

            HStack {
                Text(store.syncFolderPath ?? "No sync folder chosen")
                    .foregroundStyle(store.syncFolderPath == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose Folder…") { chooseFolder() }
            }

            Divider()

            Text("Available to adopt").font(.headline)
            if store.adoptable.isEmpty {
                Text(store.syncFolderPath == nil
                     ? "Choose a sync folder to see projects shared by other Macs."
                     : "No unadopted projects found in the sync folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List(store.adoptable) { project in
                    HStack {
                        Text(project.name)
                        Spacer()
                        Button("Adopt") { store.adopt(project) }
                    }
                }
                .listStyle(.inset)
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 360)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            store.setSyncFolder(url)
        }
    }
}
