import SwiftUI
import AppKit

/// File-based image attachments for a task description. Images live on disk under
/// Application Support (NOT in the DB, so they don't sync), keyed by task id:
/// `…/MarkdownPro/attachments/task-<id>/<n>.png`. The description text carries a
/// plain `[image N]` token; the thumbnail strip below the editor lists the files.
enum TaskAttachments {
    static func directory(taskId: Int64) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("MarkdownPro/attachments/task-\(taskId)", isDirectory: true)
    }

    /// The task's image files, ordered by their numeric filename (1.png, 2.png…).
    static func imageURLs(taskId: Int64) -> [URL] {
        let dir = directory(taskId: taskId)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { ["png", "jpg", "jpeg", "tiff"].contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.deletingPathExtension().lastPathComponent
                    .localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending
            }
    }

    enum AttachmentError: Error { case encodingFailed }

    /// Save a pasted image as the next-numbered PNG; returns its 1-based index.
    @discardableResult
    static func save(_ image: NSImage, taskId: Int64) throws -> Int {
        let dir = directory(taskId: taskId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let next = imageURLs(taskId: taskId).count + 1
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw AttachmentError.encodingFailed
        }
        try png.write(to: dir.appendingPathComponent("\(next).png"))
        return next
    }
}

/// Sheet-identifiable wrapper for a previewed attachment.
struct AttachmentPreview: Identifiable {
    let id = UUID()
    let url: URL
}

/// Full-size preview of one attachment.
struct ImagePreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 720, maxHeight: 520)
            } else {
                Text("Could not load \(url.lastPathComponent)")
                    .foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }
}
