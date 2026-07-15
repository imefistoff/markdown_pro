import Foundation

/// A `SyncTransport` over a directory:
///
///     <root>/ops/<device-id>.jsonl   append-only, one writer per file
///     <root>/blobs/<sha256>          content-addressed document bytes
///     <root>/devices.json            device id → display name
///
/// One writer per file is what keeps it safe under naive file sync and git:
/// two machines never touch the same file.
public final class FolderTransport: SyncTransport {
    private let root: URL
    private let deviceId: String
    private let fm = FileManager.default

    public init(root: URL, deviceId: String) {
        self.root = root
        self.deviceId = deviceId
    }

    private var opsDir: URL { root.appendingPathComponent("ops", isDirectory: true) }
    private var blobsDir: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    private var devicesFile: URL { root.appendingPathComponent("devices.json") }

    private func ensureDirs() throws {
        try fm.createDirectory(at: opsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)
    }

    public func publish(ops: [Op], blobs: [Blob], selfDevice: SyncDevice) throws {
        try ensureDirs()
        // Append ops to our own log.
        if !ops.isEmpty {
            let log = opsDir.appendingPathComponent("\(deviceId).jsonl")
            let data = OpCodec.encode(ops)
            if fm.fileExists(atPath: log.path) {
                let handle = try FileHandle(forWritingTo: log)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: log)
            }
        }
        // Store blobs (idempotent: skip ones already present).
        for blob in blobs {
            let dest = blobsDir.appendingPathComponent(blob.hash)
            if !fm.fileExists(atPath: dest.path) {
                try blob.data.write(to: dest)
            }
        }
        // Maintain devices.json.
        var roster = (try? readDevices()) ?? [:]
        roster[selfDevice.deviceId] = selfDevice.name
        let payload = try JSONSerialization.data(withJSONObject: roster, options: [.sortedKeys])
        try payload.write(to: devicesFile)
    }

    public func fetch(since cursors: [String: Int]) throws -> RemoteChanges {
        try ensureDirs()
        var allOps: [Op] = []
        var newCursors = cursors
        let logs = (try? fm.contentsOfDirectory(at: opsDir, includingPropertiesForKeys: nil)) ?? []
        for log in logs where log.pathExtension == "jsonl" {
            let device = log.deletingPathExtension().lastPathComponent
            if device == deviceId { continue } // never read our own log back
            let ops = OpCodec.decode((try? Data(contentsOf: log)) ?? Data())
            let start = cursors[device] ?? 0
            if ops.count > start {
                allOps.append(contentsOf: ops[start...])
            }
            newCursors[device] = ops.count
        }
        let roster = (try? readDevices()) ?? [:]
        let devices = roster.map { SyncDevice(deviceId: $0.key, name: $0.value) }
        return RemoteChanges(ops: allOps, devices: devices, cursors: newCursors)
    }

    public func fetchBlob(hash: String) throws -> Data? {
        let file = blobsDir.appendingPathComponent(hash)
        guard fm.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    private func readDevices() throws -> [String: String] {
        guard fm.fileExists(atPath: devicesFile.path) else { return [:] }
        let data = try Data(contentsOf: devicesFile)
        return (try JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }
}
