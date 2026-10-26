// Vendored/adapted from vinzdg/codenotch, MIT. Revision 6522e9f3ee0fe35d46e428b441e6e80b586eacbb.
// Upstream: Sources/Providers/SQLiteStore.swift; see Codenotch-PROVENANCE.md for local changes.
import Foundation
import SQLite3

/// Read-only access to another app's SQLite store.
///
/// Both Cursor and Codex keep their state this way, and both run it in WAL mode,
/// which makes opening it more delicate than it looks:
///
/// - `immutable=1` tells SQLite to ignore the write-ahead log entirely, so a
///   running app's most recent writes are invisible. That is how a live agent
///   looks idle and a rotated token looks current.
/// - `mode=ro` sees the log, but needs the `-shm` sidecar to do it — and that
///   file exists only *while the owning app is running*. Once it has quit and
///   checkpointed, a read-only open fails outright with "unable to open
///   database file".
///
/// So: `mode=ro` first, `immutable=1` second. The fallback is only ever reached
/// when there is no write-ahead log left to miss, which is exactly when ignoring
/// it costs nothing.
nonisolated enum CNSQLiteStore {
    static func open(_ url: URL) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Never ignore an extant WAL: that would invent an older credential.
        let modes = FileManager.default.fileExists(atPath: url.path + "-wal") ? ["mode=ro"] : ["mode=ro", "immutable=1"]
        for query in modes {
            var db: OpaquePointer?
            if sqlite3_open_v2("file:\(url.path)?\(query)", &db,
                               SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
               let db {
                sqlite3_busy_timeout(db, 100)
                sqlite3_progress_handler(db, 10000, { _ in CNReadBudget.current?.stopped == true ? 1 : 0 }, nil)
                return db
            }
            sqlite3_close(db)
        }
        return nil
    }

    /// Every column of every row, as text. Needed where one row carries more
    /// than one fact — a thread's title *and* when it was last touched — and
    /// two queries would be two chances for them to disagree.
    static func rows(in db: OpaquePointer?, sql: String, columns: Int) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var out: [[String]] = []
        var steps = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            steps += 1
            if steps > 10000 || CNReadBudget.current?.stopped == true { CNReadBudget.sqlExceeded(); return [] }
            var row: [String] = []
            for index in 0..<Int32(columns) {
                guard sqlite3_column_bytes(statement, index) <= 1024 * 1024 else { CNReadBudget.sqlExceeded(); return [] }
                row.append(sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "")
            }
            out.append(row)
        }
        return out
    }

    /// First column of every row, as text.
    static func rows(in db: OpaquePointer?, sql: String, bind: String? = nil) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        if let bind {
            sqlite3_bind_text(statement, 1, bind, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var out: [String] = []
        var steps = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            steps += 1
            if steps > 10000 || CNReadBudget.current?.stopped == true { CNReadBudget.sqlExceeded(); return [] }
            guard sqlite3_column_bytes(statement, 0) <= 1024 * 1024 else { CNReadBudget.sqlExceeded(); return [] }
            if let raw = sqlite3_column_text(statement, 0) { out.append(String(cString: raw)) }
        }
        return out
    }
}
