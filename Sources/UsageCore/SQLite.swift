import Foundation
import SQLite3

enum SQLiteError: Error, Equatable {
    case open(String), prepare(String), step(String), exec(String)
}

enum SQLValue: Equatable, Sendable {
    case int(Int64), double(Double), text(String), null

    var intValue: Int64 {
        switch self {
        case .int(let v): return v
        case .double(let v):
            guard v.isFinite else { return 0 }
            return Int64(exactly: v.rounded(.towardZero)) ?? (v < 0 ? .min : .max)
        default: return 0
        }
    }

    var doubleValue: Double {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return 0
        }
    }

    var textValue: String? {
        if case .text(let v) = self { return v }
        return nil
    }
}

private var sqliteTransient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

/// Minimal wrapper over the system SQLite. Not thread-safe: owned by one actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw SQLiteError.open(String(cString: sqlite3_errmsg(handle)))
        }
        sqlite3_busy_timeout(handle, 5_000)   // the app and the CLI share this file: wait instead of failing
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
    }

    deinit { sqlite3_close_v2(handle) }

    var message: String { String(cString: sqlite3_errmsg(handle)) }
    var changes: Int32 { sqlite3_changes(handle) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let text = error.map { String(cString: $0) } ?? message
            sqlite3_free(error)
            throw SQLiteError.exec(text)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(message)
        }
        return Statement(stmt: stmt, db: self)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class Statement {
    private let stmt: OpaquePointer
    private unowned let db: SQLiteDatabase

    init(stmt: OpaquePointer, db: SQLiteDatabase) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    private func bind(_ values: [SQLValue]) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .double(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, sqliteTransient)
            case .null: sqlite3_bind_null(stmt, i)
            }
        }
    }

    func run(_ values: [SQLValue] = []) throws {
        bind(values)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError.step(db.message) }
    }

    func rows(_ values: [SQLValue] = []) throws -> [[SQLValue]] {
        bind(values)
        var out: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError.step(db.message) }
            out.append((0..<sqlite3_column_count(stmt)).map { column in
                switch sqlite3_column_type(stmt, column) {
                case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, column))
                case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, column))
                case SQLITE_TEXT:
                    guard let text = sqlite3_column_text(stmt, column) else { return .null }
                    return .text(String(cString: text))
                default: return .null
                }
            })
        }
        return out
    }
}
