// Vendored/adapted from vinzdg/codenotch, MIT. Revision 6522e9f3ee0fe35d46e428b441e6e80b586eacbb.
// Upstream: Sources/Providers/OpenCodeGeminiUsage.swift; see Codenotch-PROVENANCE.md for local changes.
import Foundation
import SQLite3

/// Tokens OpenCode billed to a `GEMINI_API_KEY`, read out of its own message log.
///
/// OpenCode keeps every message in `~/.local/share/opencode/opencode.db`, one
/// row per message with the interesting part as JSON in `data`:
///
/// ```
/// message(id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)
/// {"role":"assistant","providerID":"google","modelID":"gemini-2.5-pro",
///  "tokens":{"input":2834,"output":51,"reasoning":17,"cache":{"read":93106,"write":0},
///            "total":96008},"cost":0.0}
/// ```
///
/// `providerID == "google"` is OpenCode's name for the bare API key, and only
/// that: `google-vertex` is Vertex AI, billed against a GCP project rather than
/// this key, so it must not be added here.
///
/// `total` is authoritative when OpenCode wrote one, and the five components
/// are the fallback because `input` there excludes the cache — the real row
/// above adds up as 2834 + 51 + 17 + 93106 + 0 = 96008 only when `cache.read`
/// is included. An aborted message is stored with every counter at zero and no
/// `total`; `CNGeminiTokenUsage.bucket` drops it.
///
/// Nothing is linked to run `json_extract`: the system libsqlite3 already
/// carries the JSON functions. The unrelated `OpenCodeProvider` next door
/// measures the OpenCode Go plan against OpenCode's own server; this reader
/// never leaves the disk.
nonisolated enum CNOpenCodeGeminiUsage {
    static var database: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    /// `nil` means OpenCode has no database on disk, which is a different
    /// answer from "it ran and spent nothing" — the provider drops the row
    /// entirely rather than showing a zero for a tool that was never installed.
    static func read(
        database: URL = CNOpenCodeGeminiUsage.database,
        now: Date = Date()
    ) -> CNGeminiTokenUsage? {
        guard let db = CNSQLiteStore.open(database) else { return nil }
        defer { sqlite3_close(db) }

        // `time_created` is indexed and holds milliseconds. Filtering on it in
        // SQL keeps the JSON extraction off every message the user ever sent.
        let startOfMonth = Int(CNGeminiTokenUsage.startOfMonth(now: now).timeIntervalSince1970 * 1000)
        // Neither shape means a database that is not OpenCode's, which is the
        // same "no database" answer as failing to open one.
        guard let schema = CNOpenCodeSchema.of(db) else { return nil }
        let rows = CNSQLiteStore.rows(
            in: db,
            sql: schema.geminiUsageSQL(startOfMonth: startOfMonth),
            columns: 7
        )

        let entries: [(at: Date, tokens: Int, calls: Int)] = rows.compactMap { row in
            guard let milliseconds = Double(row[0]) else { return nil }
            // A stored total wins: 1.x can record one without the breakdown.
            // 2.x has no such key, so it reads as 0 and the five components are
            // the whole figure — and where both are present they agree, because
            // 1.x's `input` excludes the cache and the sum includes it.
            let total = Int(row[1]) ?? 0
            let tokens = total > 0 ? total : (2...6).reduce(0) { CNCount.add($0, Int(row[$1]) ?? 0) }
            return (at: Date(timeIntervalSince1970: milliseconds / 1000), tokens: tokens, calls: 1)
        }
        return CNGeminiTokenUsage.bucket(entries, now: now)
    }
}
