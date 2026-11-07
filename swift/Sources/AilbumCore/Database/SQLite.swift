import Foundation
import SQLite3

public enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public static func integer(_ v: Int) -> SQLValue { .integer(Int64(v)) }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw AilbumError.sqlite(msg)
        }
    }

    deinit { sqlite3_close(handle) }

    private func lastError() -> AilbumError {
        .sqlite(String(cString: sqlite3_errmsg(handle)))
    }

    public func execute(_ sql: String, _ args: [SQLValue]) throws {
        _ = try query(sql, args)
    }

    public func query(_ sql: String, _ args: [SQLValue]) throws -> [[String: SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch a {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .integer(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case .blob(let v):
                rc = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(v.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
            }
            guard rc == SQLITE_OK else { throw lastError() }
        }
        var rows: [[String: SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            var row: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    row[name] = .blob(n == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, c), count: n))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Runs a multi-statement script without parameters.
    func executeScript(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    public func userVersion() throws -> Int {
        guard case .integer(let v)? = try query("PRAGMA user_version", []).first?["user_version"] else { return 0 }
        return Int(v)
    }

    private var depth = 0
    private let txLock = NSRecursiveLock()

    /// Serialises transactions across threads; nested calls use savepoints.
    public func transaction(_ body: () throws -> Void) throws {
        txLock.lock()
        defer { txLock.unlock() }
        let name = "sl_sp\(depth)"
        let nested = depth > 0
        try executeScript(nested ? "SAVEPOINT \(name)" : "BEGIN")
        depth += 1
        defer { depth -= 1 }
        do {
            try body()
            try executeScript(nested ? "RELEASE \(name)" : "COMMIT")
        } catch {
            try? executeScript(nested ? "ROLLBACK TO \(name); RELEASE \(name)" : "ROLLBACK")
            throw error
        }
    }
}
