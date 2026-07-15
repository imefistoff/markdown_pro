import Foundation

/// The syncable entity kinds. Raw values match the `entity` column and the
/// spec's op-log vocabulary.
public enum SyncEntity: String, Codable, Sendable, CaseIterable {
    case project
    case task
    case subtask
    case label
    case document
    case annotation
    case activity
    case taskLabel = "task_label"
}

public enum OpKind: String, Codable, Sendable {
    case insert
    case update
    case delete
}

/// One operation: an insert, a single-field update, or a delete.
public struct Op: Codable, Sendable, Equatable {
    public var entity: SyncEntity
    public var entityUUID: String
    public var kind: OpKind
    /// nil for insert/delete.
    public var field: String?
    /// nil clears the field (or is unused for insert/delete).
    public var value: String?
    /// Owning entity's UUID, set on insert so replay can place the row.
    public var parentUUID: String?
    public var deviceId: String
    public var hlc: String
    public var createdAt: String

    public init(entity: SyncEntity, entityUUID: String, kind: OpKind,
                field: String?, value: String?, parentUUID: String?,
                deviceId: String, hlc: String, createdAt: String) {
        self.entity = entity
        self.entityUUID = entityUUID
        self.kind = kind
        self.field = field
        self.value = value
        self.parentUUID = parentUUID
        self.deviceId = deviceId
        self.hlc = hlc
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case entity, entityUUID = "entity_uuid", kind, field, value
        case parentUUID = "parent_uuid", deviceId = "device_id", hlc, createdAt = "created_at"
    }

    public var stamp: HLC? { HLC.parse(hlc) }
}

/// A device known to the transport.
public struct SyncDevice: Codable, Sendable, Equatable {
    public var deviceId: String
    public var name: String

    public init(deviceId: String, name: String) {
        self.deviceId = deviceId
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id", name
    }
}

/// A content-addressed document blob in flight.
public struct Blob: Sendable, Equatable {
    public var hash: String
    public var data: Data

    public init(hash: String, data: Data) {
        self.hash = hash
        self.data = data
    }
}

/// What a transport hands back on fetch: remote ops, the device roster, and
/// the highest op index read per remote device (the new cursor positions).
public struct RemoteChanges: Sendable {
    public var ops: [Op]
    public var devices: [SyncDevice]
    public var cursors: [String: Int]

    public init(ops: [Op], devices: [SyncDevice], cursors: [String: Int]) {
        self.ops = ops
        self.devices = devices
        self.cursors = cursors
    }
}

/// Newline-delimited JSON: one `Op` per line.
public enum OpCodec {
    public static func encode(_ ops: [Op]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for op in ops {
            guard let line = try? encoder.encode(op) else { continue }
            data.append(line)
            data.append(0x0A) // "\n"
        }
        return data
    }

    /// Order-preserving. A line that fails to decode is skipped — one bad line
    /// must not poison the log.
    public static func decode(_ data: Data) -> [Op] {
        let decoder = JSONDecoder()
        var ops: [Op] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let op = try? decoder.decode(Op.self, from: Data(line)) {
                ops.append(op)
            }
        }
        return ops
    }
}
