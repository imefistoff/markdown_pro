import SwiftUI
import MarkdownProCore

struct SyncSettingsView: View {
    @EnvironmentObject var store: Store
    @State private var owner = ""
    @State private var repo = "markdownpro-sync"
    @State private var token = ""
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync").font(.title2.bold())
            if let target = store.syncTargetLabel {
                HStack {
                    Text("Connected — \(target)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Disconnect") { store.disconnectSync() }
                }
            } else {
                TextField("owner", text: $owner)
                TextField("repo", text: $repo)
                SecureField("fine-grained token (Contents: read/write)", text: $token)
                HStack {
                    Button("Verify & Connect") { connect() }
                        .disabled(owner.isEmpty || repo.isEmpty || token.isEmpty)
                    if let status { Text(status).font(.caption).foregroundStyle(.red) }
                }
                Text("Create an empty private repo on GitHub first, then a fine-grained token scoped to just that repo (Contents: read/write).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Available to adopt").font(.headline)
            if store.adoptable.isEmpty {
                Text(store.syncTargetLabel == nil ? "Connect a GitHub repo first." : "No unadopted projects found.")
                    .foregroundStyle(.secondary)
            } else {
                List(store.adoptable) { project in
                    HStack { Text(project.name); Spacer(); Button("Adopt") { store.adopt(project) } }
                }
            }
            Spacer()
        }
        .padding(20).frame(width: 460, height: 400).textFieldStyle(.roundedBorder)
        .onAppear { store.refreshAdoptable() }
    }

    private func connect() {
        status = store.connectGitHub(owner: owner.trimmingCharacters(in: .whitespaces),
                                     repo: repo.trimmingCharacters(in: .whitespaces),
                                     token: token.trimmingCharacters(in: .whitespaces))
        if status == nil { token = "" }
    }
}
