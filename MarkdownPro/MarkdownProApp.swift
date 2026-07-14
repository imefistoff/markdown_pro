import SwiftUI
import AppKit
import MarkdownProCore

@main
struct MarkdownProApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1080, minHeight: 660)
        }
        .commands {
            ExportImportCommands(store: store)
        }
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
