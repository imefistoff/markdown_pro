import SwiftUI
import AppKit
import MarkdownProCore

@main
struct MarkdownProApp: App {
    @StateObject private var store = Store()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1080, minHeight: 660)
        }
        .commands {
            ExportImportCommands(store: store)
        }
        Settings {
            SyncSettingsView()
                .environmentObject(store)
        }
    }
}

/// Runs a final sync (if a folder is configured) before quitting. `Store.syncNow()`
/// is now synchronous on the main actor, so this hook returns only once the sync
/// has actually finished — no `.terminateLater`/watchdog dance needed.
/// `Store.init()` sets `SyncQuitHook.shared`; if no sync folder is configured the
/// hook still exists but `Store.syncNow()` is a no-op.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SyncQuitHook.shared?()
        return .terminateNow
    }
}

/// File ▸ Import / Export Projects.
struct ExportImportCommands: Commands {
    @ObservedObject var store: Store

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Import Projects…", action: chooseImportFile)
            Button("Export Projects…") {
                store.activeSheet = .export(preselected: [])
            }
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.beginImport(from: url)
    }
}
