import Foundation
import CryptoKit

/// SHA-256 helper for content-addressed blobs.
public enum SyncHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The seam Spec B (GitHub) will swap. Spec A ships `FolderTransport`.
public protocol SyncTransport {
    /// Remote device logs (excluding our own) beyond the given per-device cursor.
    func fetch(since cursors: [String: Int]) throws -> RemoteChanges
    /// Append our ops to our own log and store new blobs.
    func publish(ops: [Op], blobs: [Blob], selfDevice: SyncDevice) throws
    /// The bytes for a content hash, or nil if the transport doesn't have them yet.
    func fetchBlob(hash: String) throws -> Data?
}
