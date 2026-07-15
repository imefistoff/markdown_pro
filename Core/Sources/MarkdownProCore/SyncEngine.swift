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

    private func publishLocal() throws {
        let cursor = try repo.selfPublishCursor()
        let (ops, maxId) = try repo.localOps(sinceSelfCursor: cursor)
        let blobs = try collectBlobs(for: ops)
        guard !ops.isEmpty || !blobs.isEmpty else { return }
        let state = try repo.syncState()
        try transport.publish(ops: ops, blobs: blobs,
                              selfDevice: SyncDevice(deviceId: state.deviceId, name: SyncState.defaultDeviceName()))
        if maxId > cursor { try repo.setSelfPublishCursor(maxId) }
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

    /// Blobs to publish alongside `ops`. Task 13 fills this in.
    func collectBlobs(for ops: [Op]) throws -> [Blob] { [] }

    /// Resolve local files for documents referenced by incoming ops. Task 13 fills this in.
    func resolveDocuments(for ops: [Op]) throws { }
}
