import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)
    case bind(String)

    public var description: String {
        switch self {
        case .open(let m): return "SQLite open error: \(m)"
        case .prepare(let m, let sql): return "SQLite prepare error: \(m) in [\(sql)]"
        case .step(let m, let sql): return "SQLite step error: \(m) in [\(sql)]"
        case .bind(let m): return "SQLite bind error: \(m)"
        }
    }
}

/// A value that can be bound to / read from a SQLite column.
public enum SQLValue: Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
}

extension SQLValue: ExpressibleByNilLiteral, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
}

/// One result row, addressable by column name.
public struct SQLRow {
    let values: [String: SQLValue]

    public func int(_ column: String) -> Int64 {
        if case .integer(let v)? = values[column] { return v }
        if case .real(let v)? = values[column] { return Int64(v) }
        return 0
    }

    public func intOrNil(_ column: String) -> Int64? {
        if case .integer(let v)? = values[column] { return v }
        return nil
    }

    public func double(_ column: String) -> Double {
        if case .real(let v)? = values[column] { return v }
        if case .integer(let v)? = values[column] { return Double(v) }
        return 0
    }

    public func string(_ column: String) -> String {
        if case .text(let v)? = values[column] { return v }
        return ""
    }

    public func stringOrNil(_ column: String) -> String? {
        if case .text(let v)? = values[column] { return v }
        return nil
    }

    public func bool(_ column: String) -> Bool { int(column) != 0 }

    public func date(_ column: String) -> Date {
        guard let s = stringOrNil(column), let d = DateCoding.decode(s) else { return Date(timeIntervalSince1970: 0) }
        return d
    }

    public func dateOrNil(_ column: String) -> Date? {
        guard let s = stringOrNil(column) else { return nil }
        return DateCoding.decode(s)
    }
}

/// Minimal thread-unsafe SQLite connection. Callers serialize access
/// (the app uses it from the main actor; the MCP server is single-threaded).
public final class SQLiteConnection {
    private var db: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SQLiteError.open(message)
        }
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(db)
    }

    private var lastMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(lastMessage, sql: sql)
        }
        for (index, value) in bindings.enumerated() {
            let slot = Int32(index + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, slot)
            case .integer(let v): rc = sqlite3_bind_int64(stmt, slot, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, slot, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, slot, v, -1, SQLITE_TRANSIENT)
            }
            guard rc == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw SQLiteError.bind(lastMessage)
            }
        }
        return stmt
    }

    /// Run a statement that returns no rows.
    public func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        let stmt = try prepare(sql, bindings)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.step(lastMessage, sql: sql)
        }
    }

    /// Run a query and collect all rows.
    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        let stmt = try prepare(sql, bindings)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError.step(lastMessage, sql: sql) }
            var values: [String: SQLValue] = [:]
            let count = sqlite3_column_count(stmt)
            for i in 0..<count {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                default: values[name] = .null
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    public var lastInsertRowId: Int64 {
        sqlite3_last_insert_rowid(db)
    }

    /// Changes whenever *any* connection (including other processes)
    /// commits to the database — used to live-refresh the UI.
    public func dataVersion() -> Int64 {
        (try? query("PRAGMA data_version").first?.int("data_version")) ?? 0
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
