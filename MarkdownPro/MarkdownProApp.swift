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

/// Delays app termination until a final sync (if a folder is configured) has
/// actually written its ops, instead of firing a detached `Task` from
/// `NSApplication.willTerminateNotification` and hoping it lands before the
/// process exits. `Store.init()` sets `SyncQuitHook.shared`; if no sync
/// folder is configured the hook still exists but `Store.syncNow()` is a
/// no-op, so termination proceeds immediately either way.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let hook = SyncQuitHook.shared else { return .terminateNow }

        var didReply = false
        func replyOnce() {
            guard !didReply else { return }
            didReply = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        // Don't let a stuck sync (e.g. an unreachable folder) hang quitting the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { replyOnce() }
        hook { DispatchQueue.main.async { replyOnce() } }
        return .terminateLater
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
