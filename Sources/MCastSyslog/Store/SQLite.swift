import Foundation
import SQLite3

/// A thin, honest wrapper over the system `libsqlite3`.
///
/// Deliberately small: it exists so the rest of the store can read as SQL plus
/// binding, not as C pointer ceremony. It is not an ORM and should not grow
/// into one.
enum SQLiteError: LocalizedError {
    case open(String, Int32)
    case prepare(String, String)
    case step(String, String)

    var errorDescription: String? {
        switch self {
        case .open(let path, let code):
            return "could not open \(path) (sqlite \(code))"
        case .prepare(let sql, let message):
            return "could not prepare \(sql.prefix(120)): \(message)"
        case .step(let sql, let message):
            return "\(message) — while running \(sql.prefix(120))"
        }
    }
}

/// SQLite must copy bound bytes: the Swift buffers they came from are gone by
/// the time the statement runs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteConnection {
    let handle: OpaquePointer
    let path: String

    init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        // FULLMUTEX: a connection may be used from whichever queue owns it, and
        // `interrupt` is called from another thread by design.
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError.open(path, rc)
        }
        self.handle = handle
        self.path = path
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    var lastMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        guard rc == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(error)
            throw SQLiteError.step(sql, message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(sql, lastMessage)
        }
        return SQLiteStatement(stmt, sql: sql, connection: self)
    }

    /// Ask the current statement on this connection to stop. Safe from another
    /// thread — that is the whole point of it. A long substring scan is
    /// cancelled this way.
    func interrupt() { sqlite3_interrupt(handle) }

    func scalarInt(_ sql: String) throws -> Int64 {
        let stmt = try prepare(sql)
        defer { stmt.finalize() }
        return try stmt.step() ? stmt.int(0) : 0
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

final class SQLiteStatement {
    private let stmt: OpaquePointer
    private let sql: String
    private unowned let connection: SQLiteConnection

    init(_ stmt: OpaquePointer, sql: String, connection: SQLiteConnection) {
        self.stmt = stmt
        self.sql = sql
        self.connection = connection
    }

    func finalize() { sqlite3_finalize(stmt) }

    // MARK: Binding — one-based, as SQLite counts them.

    func bind(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(stmt, index, value) }
    func bind(_ index: Int32, _ value: Int) { sqlite3_bind_int64(stmt, index, Int64(value)) }

    func bind(_ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    func bind(_ index: Int32, _ value: Int64?) {
        if let value { sqlite3_bind_int64(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    func bind(_ index: Int32, _ value: Data?) {
        guard let value, !value.isEmpty else { sqlite3_bind_null(stmt, index); return }
        value.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
    }

    // MARK: Stepping

    /// True when a row is available.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(sql, connection.lastMessage)
        }
    }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    // MARK: Reading — zero-based, as SQLite counts them.

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }

    func intOrNil(_ column: Int32) -> Int64? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, column)
    }

    func string(_ column: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: c)
    }

    func data(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }
}
