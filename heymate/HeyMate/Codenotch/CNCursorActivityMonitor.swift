// From vinzdg/codenotch Sessions/CursorActivityMonitor.swift, MIT, revision 6522e9f.
import Foundation
import SQLite3
nonisolated enum CNCursorActivityMonitor {
    static func read(store: URL, cursorLaunchedAt: Date?,
                     staleAfter: TimeInterval, now: Date = Date()) -> [CNAgentSession] {
        guard let db = CNSQLiteStore.open(store) else { return [] }
        defer { sqlite3_close(db) }

        // `isSubagent` lives on the row, not always in the JSON value. Nested
        // composers (continual-learning, explore, …) are not their own notch
        // rows: the parent chat already carries the busy/waiting state, and
        // finished subagents are what left `hasBlockingPendingActions` set for
        // months after the run ended.
        let rows = CNSQLiteStore.rows(
            in: db,
            sql: """
            SELECT value, isSubagent FROM composerHeaders
            WHERE isArchived = 0 ORDER BY recency DESC LIMIT 40
            """,
            columns: 2
        )
        return rows
            .compactMap { row in
                session(fromHeader: row[0],
                        isSubagent: flag(row.count > 1 ? row[1] : nil),
                        cursorLaunchedAt: cursorLaunchedAt,
                        staleAfter: staleAfter, now: now)
            }
            .sorted { $0.since > $1.since }
    }

    /// Only sessions that are *doing* something are worth a row — an editor
    /// with forty idle chats in its history is not forty things happening.
    ///
    /// `unfinishedRunAt` is set when a run begins and cleared when it ends, but
    /// two things leave it set on a run that is over and neither clears it: the
    /// editor killed mid-run, and a run abandoned with the editor still up.
    ///
    /// It cannot date either of them. Measured against a real store, its value
    /// is the *composer's creation time*, not the current run's: one row there
    /// has two user turns seven minutes apart, was killed during the second,
    /// and still reports the first. So it is a flag, and the timestamp that
    /// answers "is this still going" has to be
    /// `conversationCheckpointLastUpdatedAt`, which Cursor moves on every
    /// message and tool result (falling back to `lastUpdatedAt`, which a
    /// quarter of rows carry instead).
    ///
    /// That one timestamp settles both cases:
    ///
    /// - Written before the editor's current launch, it belongs to a process
    ///   that is already gone — as does everything, when Cursor is not running
    ///   at all and `cursorLaunchedAt` is nil.
    /// - Written longer than `staleAfter` ago, the conversation has stopped
    ///   being written to, which is the only evidence an abandoned run leaves.
    ///
    /// Waiting is different from busy on one point: checkpoints do not move
    /// until you answer, so a plan from this morning must keep its amber.
    /// The launch gate still applies — a blocking flag from a previous
    /// process is not a question — and a wait that has gone silent longer
    /// than `staleAfter` with the editor shut or restarted is retired the
    /// same way a dead run is.
    static func session(fromHeader json: String,
                        isSubagent: Bool = false,
                        cursorLaunchedAt: Date?,
                        staleAfter: TimeInterval,
                        now: Date = Date()) -> CNAgentSession? {
        guard let data = json.data(using: .utf8),
              let head = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = head["composerId"] as? String
        else { return nil }

        if isSubagent || flag(head["isSubagent"]) { return nil }

        let blocked = (head["hasBlockingPendingActions"] as? Bool) == true
            || (head["hasPendingPlan"] as? Bool) == true
        let runStart = date(head["unfinishedRunAt"])
        // A quarter of rows carry `lastUpdatedAt` and no checkpoint at all.
        let lastWrite = date(head["conversationCheckpointLastUpdatedAt"])
            ?? date(head["lastUpdatedAt"])
        let created = date(head["createdAt"])
        let touched = lastWrite ?? runStart ?? created

        let isRunning: Bool = {
            guard let runStart, let cursorLaunchedAt else { return false }
            // Nothing written yet means the composer was only just created, and
            // since `unfinishedRunAt` *is* its creation time that is the most
            // recent thing to have happened to it. The same value on a chat
            // opened last week is correctly stale.
            let stamp = lastWrite ?? runStart
            guard stamp >= cursorLaunchedAt else { return false }
            return now.timeIntervalSince(stamp) <= staleAfter
        }()

        let isSuccess: Bool = {
            guard let runStart, let cursorLaunchedAt else { return false }
            let stamp = lastWrite ?? runStart
            guard stamp >= cursorLaunchedAt else { return false }
            let age = now.timeIntervalSince(stamp)
            return age > staleAfter && age <= staleAfter + 9
        }()

        let isRecentlyFinished: Bool = {
            guard let runStart, let cursorLaunchedAt else { return false }
            let stamp = lastWrite ?? runStart
            guard stamp >= cursorLaunchedAt else { return false }
            let age = now.timeIntervalSince(stamp)
            return age > staleAfter + 9 && age <= staleAfter + 15
        }()

        let isWaiting = blocked && isCurrentWait(
            touched: touched,
            cursorLaunchedAt: cursorLaunchedAt,
            staleAfter: staleAfter,
            now: now
        )

        let state: CNAgentSession.State
        if isWaiting { state = .waiting }
        else if isRunning { state = .busy }
        else if isSuccess { state = .success }
        else if isRecentlyFinished { state = .idle }
        else { return nil }

        // `runStart` is the composer's creation time, so it dates a busy row the
        // way it always has — from when the chat began. A row that is merely
        // waiting must not borrow it: a session blocked since this morning did
        // not start waiting when the chat was opened last week.
        let since = (isRunning ? runStart : nil)
            ?? lastWrite
            ?? date(head["createdAt"])
            ?? now

        return CNAgentSession(
            id: "cursor.\(id)",
            name: (head["name"] as? String) ?? CNL10n.t("Untitled chat"),
            detail: (head["subtitle"] as? String) ?? "Cursor",
            state: state,
            waitingFor: isWaiting ? CNL10n.t("needs your input") : nil,
            since: since
        )
    }

    /// Waiting is live if it belongs to this editor launch — you may sit on
    /// a plan for hours — or if the last write is still inside the staleness
    /// window, which covers a crash-and-restart. An undated row with the
    /// editor up is trusted: we cannot prove it is old.
    private static func isCurrentWait(touched: Date?,
                                      cursorLaunchedAt: Date?,
                                      staleAfter: TimeInterval,
                                      now: Date) -> Bool {
        let recentlyTouched = touched.map { now.timeIntervalSince($0) <= staleAfter } ?? false
        guard let cursorLaunchedAt else { return recentlyTouched }
        guard let touched else { return true }
        return touched >= cursorLaunchedAt || recentlyTouched
    }

    /// Cursor stores booleans as 0/1 in SQLite, and JSONSerialization often
    /// hands them back as `NSNumber`. Empty and unknown values are false.
    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed == "1" || trimmed == "true" || trimmed == "yes"
        default:
            return false
        }
    }

    /// Cursor writes its timestamps as milliseconds since the epoch.
    private static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }
}
