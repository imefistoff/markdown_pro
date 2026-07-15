import Foundation

/// Publish → fetch → replay, plus document blobs (Task 13). Drives one
/// `Repository` against one `SyncTransport`. Runs off the main thread in the
/// app; failures propagate to the caller's error handling.
public final class SyncEngine {
    private let repo: Repository
    private let transport: SyncTransport

    public init(repo: Repository, transport: SyncTransport) {
        self.repo = repo
        self.transport = transport
    }

    public func sync() throws {
        try publishLocal()
        try pullAndReplay()
    }

    public struct AdoptableProject: Identifiable, Sendable, Equatable {
        public let uuid: String
        public let name: String
        public var id: String { uuid }
        public init(uuid: String, name: String) { self.uuid = uuid; self.name = name }
    }

    /// Projects present in the transport that this machine has not adopted.
    /// Reads the whole transport (cursor 0) — a catalog, not a sync step.
    public func availableToAdopt() throws -> [AdoptableProject] {
        let changes = try transport.fetch(since: [:])
        let localUUIDs = Set(try repo.db.query("SELECT uuid FROM projects").compactMap { $0.stringOrNil("uuid") })

        // Latest name per project uuid, by HLC.
        var latestName: [String: (name: String, hlc: String)] = [:]
        for op in changes.ops where op.entity == .project && op.field == "name" {
            guard let name = op.value else { continue }
            if let current = latestName[op.entityUUID], current.hlc >= op.hlc { continue }
            latestName[op.entityUUID] = (name, op.hlc)
        }
        return latestName
            .filter { !localUUIDs.contains($0.key) }
            .map { AdoptableProject(uuid: $0.key, name: $0.value.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func publishLocal() throws {
        try hashSyncedDocuments()
        let cursor = try repo.selfPublishCursor()
        let (ops, maxId) = try repo.localOps(sinceSelfCursor: cursor)
        let blobs = try collectBlobs(for: ops)
        guard !ops.isEmpty || !blobs.isEmpty else { return }
        let state = try repo.syncState()
        try transport.publish(ops: ops, blobs: blobs,
                              selfDevice: SyncDevice(deviceId: state.deviceId, name: SyncState.defaultDeviceName()))
        if maxId > cursor { try repo.setSelfPublishCursor(maxId) }
    }

    /// Re-hash every synced document; a changed hash emits a content_hash op.
    private func hashSyncedDocuments() throws {
        for doc in try repo.syncedDocumentsNeedingHash() {
            guard let data = FileManager.default.contents(atPath: doc.path) else { continue }
            let hash = SyncHash.sha256(data)
            if hash != doc.currentHash {
                try repo.setDocumentContentHash(id: doc.id, hash: hash)
            }
        }
    }

    private func pullAndReplay() throws {
        let cursors = try repo.remoteCursors()
        let changes = try transport.fetch(since: cursors)

        // Advance our clock past every remote stamp we just saw.
        let clock = try repo.syncState().clock
        for op in changes.ops { if let stamp = op.stamp { clock.observe(stamp) } }

        let adopted = try repo.adoptedProjectUUIDs()
        try repo.db.transaction {
            try SyncReplayer(db: repo.db).apply(changes.ops, adoptedProjectUUIDs: adopted)
        }
        try repo.upsertRemoteDevices(changes.devices)
        try repo.setRemoteCursors(changes.cursors)

        try resolveDocuments(for: changes.ops) // Task 13
    }

    // MARK: Document blobs (finished in Task 13)

    /// Where restored document copies live. Overridable via
    /// `MARKDOWNPRO_SYNC_ROOT` (mirrors `Database.defaultPath()`'s
    /// `MARKDOWNPRO_DB` override) so tests never touch the real user directory.
    static var managedDocumentsRoot: URL {
        if let override = ProcessInfo.processInfo.environment["MARKDOWNPRO_SYNC_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("MarkdownPro/Synced", isDirectory: true)
    }

    /// The blobs whose hashes appear in this publish batch and are present locally.
    func collectBlobs(for ops: [Op]) throws -> [Blob] {
        var seen = Set<String>()
        var blobs: [Blob] = []
        for op in ops where op.field == "content_hash" {
            guard let hash = op.value, !seen.contains(hash) else { continue }
            // Find a local file with this hash among synced documents.
            for doc in try repo.syncedDocumentsNeedingHash() where doc.currentHash == hash || (try? SyncHash.sha256(Data(contentsOf: URL(fileURLWithPath: doc.path)))) == hash {
                if let data = FileManager.default.contents(atPath: doc.path) {
                    blobs.append(Blob(hash: hash, data: data))
                    seen.insert(hash)
                    break
                }
            }
        }
        return blobs
    }

    /// For each incoming document with a content_hash but no usable local file,
    /// fetch the blob and write a managed copy.
    func resolveDocuments(for ops: [Op]) throws {
        let docUUIDs = Set(ops.filter { $0.entity == .document }.map { $0.entityUUID })
        for uuid in docUUIDs {
            // Skip documents whose project we haven't adopted.
            guard let projectUUID = try repo.projectUUIDForDocument(uuid: uuid),
                  try repo.adoptedProjectUUIDs().contains(projectUUID) else { continue }
            // If we already have a real file, keep it.
            if let existing = try repo.documentLocalPath(uuid: uuid), FileManager.default.fileExists(atPath: existing) {
                // But if the content hash changed and we own a managed copy, refresh it.
                if existing.hasPrefix(Self.managedDocumentsRoot.path),
                   let hash = try repo.documentContentHash(uuid: uuid),
                   let data = try transport.fetchBlob(hash: hash) {
                    try data.write(to: URL(fileURLWithPath: existing))
                }
                continue
            }
            guard let hash = try repo.documentContentHash(uuid: uuid),
                  let data = try transport.fetchBlob(hash: hash) else { continue }
            let dir = Self.managedDocumentsRoot.appendingPathComponent(projectUUID, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(uuid).md")
            try data.write(to: dest)
            try repo.setDocumentPath(uuid: uuid, path: dest.path)
        }
    }
}
