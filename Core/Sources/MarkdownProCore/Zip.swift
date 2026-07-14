import Foundation

public struct ZipEntry: Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public enum ZipError: Error, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .malformed(let m): return "Malformed zip archive: \(m)"
        case .unsupported(let m): return "Unsupported zip archive: \(m)"
        }
    }
}

/// A minimal zip reader/writer supporting only *stored* (uncompressed) entries.
/// That is all MarkdownPro export bundles use, and it keeps Core dependency-free.
/// Not supported, and rejected on read: compression, encryption, zip64,
/// data descriptors, multi-disk archives.
public enum Zip {

    // MARK: - Writing

    public static func archive(_ entries: [ZipEntry]) -> Data {
        var output = Data()
        var directory = Data()
        var count: UInt16 = 0

        for entry in entries {
            let name = Array(entry.name.utf8)
            let bytes = [UInt8](entry.data)
            let crc = crc32(bytes)
            let size = UInt32(bytes.count)
            let offset = UInt32(output.count)

            // Local file header.
            output.append(uint32: 0x0403_4b50)
            output.append(uint16: 20)            // version needed
            output.append(uint16: 0)             // flags
            output.append(uint16: 0)             // method: stored
            output.append(uint16: dosTime)
            output.append(uint16: dosDate)
            output.append(uint32: crc)
            output.append(uint32: size)          // compressed size == uncompressed
            output.append(uint32: size)
            output.append(uint16: UInt16(name.count))
            output.append(uint16: 0)             // extra field length
            output.append(contentsOf: name)
            output.append(contentsOf: bytes)

            // Central directory header.
            directory.append(uint32: 0x0201_4b50)
            directory.append(uint16: 20)         // version made by
            directory.append(uint16: 20)         // version needed
            directory.append(uint16: 0)          // flags
            directory.append(uint16: 0)          // method: stored
            directory.append(uint16: dosTime)
            directory.append(uint16: dosDate)
            directory.append(uint32: crc)
            directory.append(uint32: size)
            directory.append(uint32: size)
            directory.append(uint16: UInt16(name.count))
            directory.append(uint16: 0)          // extra field length
            directory.append(uint16: 0)          // comment length
            directory.append(uint16: 0)          // disk number start
            directory.append(uint16: 0)          // internal attributes
            directory.append(uint32: 0)          // external attributes
            directory.append(uint32: offset)     // local header offset
            directory.append(contentsOf: name)

            count += 1
        }

        let directoryOffset = UInt32(output.count)
        let directorySize = UInt32(directory.count)
        output.append(directory)

        // End of central directory record.
        output.append(uint32: 0x0605_4b50)
        output.append(uint16: 0)                 // this disk
        output.append(uint16: 0)                 // disk with central directory
        output.append(uint16: count)             // entries on this disk
        output.append(uint16: count)             // entries total
        output.append(uint32: directorySize)
        output.append(uint32: directoryOffset)
        output.append(uint16: 0)                 // comment length

        return output
    }

    // MARK: - Reading

    public static func read(_ data: Data) throws -> [ZipEntry] {
        let bytes = [UInt8](data)
        let eocd = try findEndOfCentralDirectory(bytes)

        let entryCount = Int(bytes.uint16(at: eocd + 10))
        var cursor = Int(bytes.uint32(at: eocd + 16))   // central directory offset
        var entries: [ZipEntry] = []

        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count, bytes.uint32(at: cursor) == 0x0201_4b50 else {
                throw ZipError.malformed("bad central directory header")
            }
            let method = bytes.uint16(at: cursor + 10)
            guard method == 0 else {
                throw ZipError.unsupported("compression method \(method); only stored entries are supported")
            }
            let size = Int(bytes.uint32(at: cursor + 24))
            let nameLength = Int(bytes.uint16(at: cursor + 28))
            let extraLength = Int(bytes.uint16(at: cursor + 30))
            let commentLength = Int(bytes.uint16(at: cursor + 32))
            let localOffset = Int(bytes.uint32(at: cursor + 42))

            guard cursor + 46 + nameLength <= bytes.count else {
                throw ZipError.malformed("truncated central directory entry name")
            }
            let nameBytes = Array(bytes[(cursor + 46)..<(cursor + 46 + nameLength)])
            guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw ZipError.malformed("entry name is not valid UTF-8")
            }

            // The local header repeats the name/extra lengths, and its extra field
            // may differ from the central one, so read the data offset from there.
            guard localOffset + 30 <= bytes.count, bytes.uint32(at: localOffset) == 0x0403_4b50 else {
                throw ZipError.malformed("bad local header for \(name)")
            }
            let localNameLength = Int(bytes.uint16(at: localOffset + 26))
            let localExtraLength = Int(bytes.uint16(at: localOffset + 28))
            let start = localOffset + 30 + localNameLength + localExtraLength
            guard start + size <= bytes.count else {
                throw ZipError.malformed("truncated data for \(name)")
            }

            entries.append(ZipEntry(name: name, data: Data(bytes[start..<(start + size)])))
            cursor += 46 + nameLength + extraLength + commentLength
        }

        return entries
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 22 else { throw ZipError.malformed("file is too short to be a zip") }
        // Scan backwards; the record is 22 bytes plus a trailing comment (we write none).
        var index = bytes.count - 22
        while index >= 0 {
            if bytes.uint32(at: index) == 0x0605_4b50 { return index }
            index -= 1
        }
        throw ZipError.malformed("no end-of-central-directory record found")
    }

    // MARK: - Bits and pieces

    /// A fixed DOS timestamp (1980-01-01 00:00). Export bundles carry their real
    /// timestamps in the manifest, so per-entry mtimes add nothing, and a constant
    /// keeps archives byte-reproducible.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x0021

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 == 1) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}

private extension Array where Element == UInt8 {
    func uint16(at index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= count else { return 0 }
        return UInt16(self[index]) | (UInt16(self[index + 1]) << 8)
    }

    func uint32(at index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= count else { return 0 }
        return UInt32(self[index])
            | (UInt32(self[index + 1]) << 8)
            | (UInt32(self[index + 2]) << 16)
            | (UInt32(self[index + 3]) << 24)
    }
}
