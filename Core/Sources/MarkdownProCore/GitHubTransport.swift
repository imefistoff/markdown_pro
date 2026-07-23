import Foundation

/// A `SyncTransport` over a private GitHub repo via the REST Contents API.
/// Layout: ops/<device-id>/<seq>.jsonl (immutable batches, create-only),
/// blobs/<sha256> (content-addressed), devices.json (id → name). One writer
/// per path, so two machines never modify the same file. The per-device cursor
/// is the highest batch seq consumed.
public final class GitHubTransport: SyncTransport {
    private let api: GitHubAPI
    private let deviceId: String

    public init(owner: String, repo: String, token: String, deviceId: String, session: URLSession = .shared) {
        self.api = GitHubAPI(owner: owner, repo: repo, token: token, session: session)
        self.deviceId = deviceId
    }

    /// True if the token can reach the repo — used by the connect flow.
    public func verifyAccess() throws -> Bool { try api.getRepoExists() }

    public func publish(ops: [Op], blobs: [Blob], selfDevice: SyncDevice) throws {
        // Blobs are content-addressed: skip if present, tolerate a lost race.
        for blob in blobs where try api.getContent("blobs/\(blob.hash)") == nil {
            _ = try api.createFile("blobs/\(blob.hash)", data: blob.data, message: "blob \(blob.hash)")
        }
        // One immutable batch file under our own device directory. Under eventual
        // consistency a just-written seq can be invisible to listDir; GET-and-compare
        // resolves it without dropping ops.
        if !ops.isEmpty {
            let encoded = OpCodec.encode(ops)
            var seq = (try api.listDir("ops/\(deviceId)")
                .compactMap { Int($0.replacingOccurrences(of: ".jsonl", with: "")) }.max() ?? 0) + 1
            var published = false
            var attempts = 0
            while !published {
                attempts += 1
                guard attempts <= 8 else {
                    throw GitHubError.http(422, "ops publish: exhausted seq attempts near \(seq)")
                }
                let path = "ops/\(deviceId)/\(seq).jsonl"
                switch try api.createFile(path, data: encoded, message: "ops \(deviceId) \(seq)") {
                case .created:
                    published = true
                case .alreadyExists:
                    if let existing = try api.getRaw(path), existing == encoded {
                        published = true   // our own retried batch
                    } else {
                        seq += 1           // a different batch holds this seq
                    }
                }
            }
        }
        // Register self in devices.json (read-modify-write; retry if a concurrent
        // writer moves the sha out from under us).
        var attempt = 0
        while true {
            attempt += 1
            var roster: [String: String] = [:]
            var sha: String?
            if let existing = try api.getContent("devices.json") {
                guard let map = try? JSONSerialization.jsonObject(with: existing.data) as? [String: String] else {
                    throw GitHubError.malformed("devices.json")
                }
                roster = map
                sha = existing.sha
            }
            roster[selfDevice.deviceId] = selfDevice.name
            let payload = try JSONSerialization.data(withJSONObject: roster, options: [.sortedKeys])
            do {
                try api.putContent("devices.json", data: payload, message: "devices", sha: sha)
                return
            } catch let error as GitHubError {
                if case .http(let code, _) = error, code == 409 || code == 422, attempt < 3 { continue }
                throw error
            }
        }
    }

    public func fetch(since cursors: [String: Int]) throws -> RemoteChanges {
        var allOps: [Op] = []
        var newCursors = cursors
        for device in try api.listDir("ops") where device != deviceId {
            let start = cursors[device] ?? 0
            var maxSeq = start
            let seqs = try api.listDir("ops/\(device)")
                .compactMap { Int($0.replacingOccurrences(of: ".jsonl", with: "")) }.sorted()
            for seq in seqs where seq > start {
                if let content = try api.getContent("ops/\(device)/\(seq).jsonl") {
                    allOps.append(contentsOf: OpCodec.decode(content.data))
                }
                maxSeq = max(maxSeq, seq)
            }
            newCursors[device] = maxSeq
        }
        var roster: [SyncDevice] = []
        if let dj = try api.getContent("devices.json"),
           let map = try? JSONSerialization.jsonObject(with: dj.data) as? [String: String] {
            roster = map.map { SyncDevice(deviceId: $0.key, name: $0.value) }
        }
        return RemoteChanges(ops: allOps, devices: roster, cursors: newCursors)
    }

    public func fetchBlob(hash: String) throws -> Data? {
        try api.getRaw("blobs/\(hash)")
    }
}
