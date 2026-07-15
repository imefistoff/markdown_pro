import SwiftUI
import MarkdownProCore

/// The review queue + annotation surface: pick a proposal on the left,
/// comment inline on the right, issue a verdict at the bottom.
struct ReviewCenterView: View {
    @EnvironmentObject private var store: Store
    @State private var selectedId: Int64?

    private var current: Repository.ReviewQueueItem? {
        store.reviewQueue.first { $0.id == selectedId } ?? store.reviewQueue.first
    }

    var body: some View {
        HSplitView {
            queue
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            if let item = current {
                ReviewDocumentView(item: item) {
                    // Verdict issued — auto-advance to the next proposal.
                    selectedId = store.reviewQueue.first { $0.id != item.id }?.id
                }
                .id(item.id) // reset per-document state when switching
            } else {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal",
                                       description: Text("Proposals Claude submits will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Review")
    }

    private var queue: some View {
        List(store.reviewQueue, selection: $selectedId) { item in
            VStack(alignment: .leading, spacing: 3) {
                Text(item.document.title)
                    .font(.callout)
                    .lineLimit(2)
                    // Without fixedSize, a List row can propose a 1-line height
                    // and clip a 2-line title mid-word; this pins the full height.
                    .fixedSize(horizontal: false, vertical: true)
                    .help(item.document.title)
                Text(item.taskTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(item.taskTitle)
                HStack(spacing: 6) {
                    Text(item.projectName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if item.document.round > 1 {
                        Text("round \(item.document.round)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    Spacer()
                    Text((item.document.updatedAt ?? item.document.createdAt).timeAgo)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
            .tag(item.id)
            .accessibilityIdentifier("reviewQueueRow-\(item.document.title)")
        }
        .listStyle(.inset)
    }
}
// Queue traversal: native List selection gives ↑/↓ arrow-key navigation,
// which covers the spec's "⌘↓/⌘↑ or click" intent with the platform-standard
// keys. Deliberate simplification — do not add custom ⌘-arrow handling.

/// One proposal: rendered document + comments panel + verdict bar.
private struct ReviewDocumentView: View {
    @EnvironmentObject private var store: Store
    let item: Repository.ReviewQueueItem
    let onVerdict: () -> Void

    @State private var markdown = ""
    @State private var annotations: [MarkdownProCore.Annotation] = []
    @State private var anchored: [Int64: Bool] = [:]
    @State private var pendingSelection: ReviewSelection?
    @State private var editingAnnotation: MarkdownProCore.Annotation?
    @State private var draftComment = ""
    @State private var scrollTarget: Int64?
    @State private var confirmReject = false
    @State private var confirmApproveWithComments = false

    private var currentRound: Int { item.document.round }
    /// Open comments made this round — painted in the doc, sent with the verdict.
    private var currentComments: [MarkdownProCore.Annotation] {
        annotations.filter { $0.round == currentRound && $0.state == .open }
    }
    /// Everything already handled: earlier rounds and addressed comments.
    private var pastComments: [MarkdownProCore.Annotation] {
        annotations.filter { $0.round < currentRound || $0.state == .addressed }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ReviewWebView(markdown: markdown,
                              baseURL: URL(fileURLWithPath: item.document.path).deletingLastPathComponent(),
                              annotations: currentComments,
                              onSelection: { if editingAnnotation == nil { pendingSelection = $0 } },
                              onAnnotationClicked: { scrollTarget = $0 },
                              onAnchors: { anchored = $0 })
                Divider()
                verdictBar
            }
            Divider()
            commentsPanel
                .frame(width: 300)
        }
        .onAppear(perform: load)
        // A resubmission bumps the round on the same document row; reload so
        // the rendered text can't go stale while this doc stays selected.
        .onChange(of: item.document.round) { _, _ in load() }
        .confirmationDialog("Reject this proposal?", isPresented: $confirmReject) {
            Button("Reject — task returns to Todo", role: .destructive) { verdict(.reject) }
        } message: {
            Text("The proposal is marked rejected and its task drops back to Todo.")
        }
        .confirmationDialog("Approve with unsent comments?", isPresented: $confirmApproveWithComments) {
            Button("Approve — send \(currentComments.count) comments as FYI notes") { verdict(.approve) }
        } message: {
            Text("Claude sees them via get_review_feedback but no changes are requested.")
        }
    }

    private func load() {
        markdown = (try? String(contentsOfFile: item.document.path, encoding: .utf8))
            ?? "⚠️ Could not read `\(item.document.path)`"
        annotations = store.annotations(documentId: item.document.id)
    }

    private func reloadAnnotations() {
        annotations = store.annotations(documentId: item.document.id)
    }

    private func saveDraft() {
        guard let sel = pendingSelection else { return }
        let text = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addAnnotation(documentId: item.document.id, quote: sel.quote,
                            prefix: sel.prefix, suffix: sel.suffix, comment: text)
        pendingSelection = nil
        draftComment = ""
        reloadAnnotations()
    }

    private func saveEdit() {
        guard let editing = editingAnnotation else { return }
        let text = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.updateAnnotation(id: editing.id, comment: text)
        editingAnnotation = nil
        draftComment = ""
        reloadAnnotations()
    }

    private func verdict(_ v: Repository.ReviewVerdict) {
        store.applyVerdict(v, documentId: item.document.id)
        onVerdict()
    }

    private var verdictBar: some View {
        HStack(spacing: 10) {
            Text("\(currentComments.count) comment\(currentComments.count == 1 ? "" : "s") this round")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reject") { confirmReject = true }
                .accessibilityIdentifier("rejectButton")
            Button("Request Changes") { verdict(.requestChanges) }
                .disabled(currentComments.isEmpty)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("⌘⇧⏎ — needs at least one comment")
                .accessibilityIdentifier("requestChangesButton")
            Button("Approve") {
                if currentComments.isEmpty { verdict(.approve) } else { confirmApproveWithComments = true }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help("⌘⏎")
            .accessibilityIdentifier("approveButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var commentsPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    composer
                    if !currentComments.isEmpty {
                        panelSection("Round \(currentRound)") {
                            ForEach(currentComments) { a in
                                commentRow(a).id(a.id)
                            }
                        }
                    }
                    if !pastComments.isEmpty {
                        panelSection("Earlier") {
                            ForEach(pastComments) { a in resolvedRow(a) }
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: scrollTarget) { _, target in
                if let target {
                    withAnimation { proxy.scrollTo(target) }
                    scrollTarget = nil
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var composer: some View {
        if let editing = editingAnnotation {
            VStack(alignment: .leading, spacing: 6) {
                Text("“\(editing.quote)”")
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                TextField("Comment…", text: $draftComment, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveEdit)
                    .accessibilityIdentifier("commentField")
                HStack {
                    Button("Cancel") { editingAnnotation = nil; draftComment = "" }
                        .controlSize(.small)
                    Spacer()
                    Button("Save", action: saveEdit)
                        .controlSize(.small)
                        .disabled(draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        } else if let sel = pendingSelection {
            VStack(alignment: .leading, spacing: 6) {
                Text("“\(sel.quote)”")
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                TextField("Comment…", text: $draftComment, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveDraft)
                    .accessibilityIdentifier("commentField")
                HStack {
                    Button("Cancel") { pendingSelection = nil; draftComment = "" }
                        .controlSize(.small)
                    Spacer()
                    Button("Save", action: saveDraft)
                        .controlSize(.small)
                        .disabled(draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        } else {
            Text("Select text in the document to comment")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func commentRow(_ a: MarkdownProCore.Annotation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("“\(a.quote)”")
                .font(.caption.italic())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(a.comment)
                .font(.callout)
            if anchored[a.id] == false {
                SwiftUI.Label("Unanchored — quoted text changed", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .contextMenu {
            Button("Edit comment") {
                editingAnnotation = a
                draftComment = a.comment
            }
            Button("Delete comment", role: .destructive) {
                store.deleteAnnotation(id: a.id)
                reloadAnnotations()
            }
        }
    }

    private func resolvedRow(_ a: MarkdownProCore.Annotation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: a.state == .addressed ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(a.state == .addressed ? Color.green : Color.secondary)
                Text("Round \(a.round)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("“\(a.quote)”")
                .font(.caption.italic())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(a.comment)
                .font(.caption)
            if let reply = a.reply {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(reply)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
    }

    @ViewBuilder
    private func panelSection(_ title: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            body()
        }
    }
}
