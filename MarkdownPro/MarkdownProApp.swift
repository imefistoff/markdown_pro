import SwiftUI
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
    }
}
