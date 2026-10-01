//
//  MacAccountContext.swift
//  leanring-buddy
//
//  Gmail and Google Calendar without a key, a Composio account, or our own
//  OAuth app.
//
//  macOS already syncs a Google (or iCloud, Exchange, Yahoo) account into
//  Calendar and Mail once the user adds it in System Settings → Internet
//  Accounts. HeyMate reads those two apps — EventKit for Calendar, a short
//  read-only AppleScript for Mail — and hands the result to the model as
//  plain text in the prompt. No tool plumbing, so it works the same for
//  every brain, including the CLI ones that cannot call Talk tools.
//
//  It only runs when the question is plainly about the calendar or email,
//  and only for the Mac apps the user switched on in Apps. Nothing is
//  stored; the text lives for one turn.
//

import AppKit
import EventKit
import Foundation

nonisolated enum MacAccountContext {

    enum Topic: Equatable {
        case calendar
        case mail
    }

    // MARK: - Intent

    private static let calendarWords = [
        "calendar", "schedule", "meeting", "meetings", "event", "events",
        "agenda", "appointment", "free time", "am i free", "am i busy",
        "what's on today", "whats on today", "what's on tomorrow", "next call"
    ]

    private static let mailWords = [
        "email", "emails", "e-mail", "inbox", "gmail", "unread", "mail from",
        "mails", "my mail", "reply to"
    ]

    /// Which Mac apps a question needs. Empty for nearly every turn, which
    /// is what keeps a screen question from paying for a calendar read.
    static func topics(in transcript: String) -> [Topic] {
        let lowered = transcript.lowercased()
        var topics: [Topic] = []
        if calendarWords.contains(where: { lowered.contains($0) }) { topics.append(.calendar) }
        if mailWords.contains(where: { lowered.contains($0) }) { topics.append(.mail) }
        return topics
    }

    // MARK: - Calendar

    static let calendarLookaheadDays = 7
    static let calendarEventLimit = 30

    /// Upcoming events across every calendar on this Mac, including any
    /// Google account added in Internet Accounts. Nil without full access —
    /// this never prompts; the Apps page owns asking.
    static func calendarBlock(now: Date = Date()) -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        guard let end = Calendar.current.date(byAdding: .day, value: calendarLookaheadDays, to: now) else { return nil }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(calendarEventLimit)
        let lines = events.map { event in
            formattedEventLine(
                title: event.title,
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                calendarName: event.calendar?.title,
                accountName: event.calendar?.source?.title
            )
        }
        return calendarPromptBlock(eventLines: Array(lines), lookaheadDays: calendarLookaheadDays)
    }

    static func calendarPromptBlock(eventLines: [String], lookaheadDays: Int) -> String {
        var block = "the user's calendar on this Mac, next \(lookaheadDays) days (includes Google or iCloud calendars they added to macOS):"
        if eventLines.isEmpty {
            block += "\n- nothing scheduled."
        } else {
            block += "\n" + eventLines.joined(separator: "\n")
        }
        block += "\nanswer from this list. you can read it but not change it from here."
        return block
    }

    static func formattedEventLine(
        title: String?,
        start: Date,
        end: Date,
        isAllDay: Bool,
        calendarName: String?,
        accountName: String?
    ) -> String {
        let dayFormatter = DateFormatter()
        // Fixed English: the prompt is English whatever the Mac's locale.
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "EEE d MMM"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"

        let when = isAllDay
            ? "\(dayFormatter.string(from: start)), all day"
            : "\(dayFormatter.string(from: start)) \(timeFormatter.string(from: start))–\(timeFormatter.string(from: end))"
        let name = (title?.isEmpty == false ? title! : "Untitled")
        var line = "- \(when) · \(name)"
        let source = [calendarName, accountName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !source.isEmpty {
            line += " (\(source.joined(separator: ", ")))"
        }
        return line
    }

    /// True when a Google account's calendars are syncing into this Mac.
    /// Only answerable with Calendar access; nil means "can't tell yet".
    static func hasGoogleCalendarAccount() -> Bool? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        return EKEventStore().sources.contains { source in
            let title = source.title.lowercased()
            return title.contains("google") || title.contains("gmail")
        }
    }

    // MARK: - Mail

    static let mailMessageLimit = 15
    static let mailTimeout: TimeInterval = 6

    /// The newest messages across every inbox in Mail.app — which is where a
    /// Gmail account added in Internet Accounts lands. Read-only: subject,
    /// sender, date, read state. Bodies stay in Mail.
    static func mailBlock() -> String? {
        let script = """
        tell application "Mail"
            set output to ""
            set messageCount to count of messages of inbox
            if messageCount > \(mailMessageLimit) then set messageCount to \(mailMessageLimit)
            if messageCount is 0 then return ""
            set recentMessages to messages 1 thru messageCount of inbox
            repeat with i from 1 to messageCount
                set m to item i of recentMessages
                set readMark to "read"
                if read status of m is false then set readMark to "unread"
                set output to output & (date received of m as string) & tab & (sender of m) & tab & (subject of m) & tab & readMark & linefeed
            end repeat
            return output
        end tell
        """
        guard let output = runAppleScript(script, timeout: mailTimeout) else { return nil }
        return mailPromptBlock(rawOutput: output)
    }

    static func mailPromptBlock(rawOutput: String) -> String {
        // `osascript -ss` wraps a string result in quotes and escapes tabs
        // and newlines; undo that so each message is one line again.
        var text = rawOutput
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        text = text
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")

        let lines = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 4 else { return nil }
                return "- \(fields[0]) · from \(fields[1]) · \"\(fields[2])\" · \(fields[3])"
            }

        var block = "the user's newest email in Mail on this Mac (includes Gmail or iCloud accounts they added to macOS):"
        block += lines.isEmpty ? "\n- the inbox is empty." : "\n" + lines.joined(separator: "\n")
        block += "\nyou only have subjects and senders, not message bodies. never send or delete mail from here."
        return block
    }

    /// osascript with a deadline: a large or still-syncing Mail store can
    /// stall a script, and a stalled read must never hold up an answer.
    private static func runAppleScript(_ script: String, timeout: TimeInterval) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-ss", "-e", script]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Internet Accounts

    /// Opens System Settings → Internet Accounts, where a Google account is
    /// added once and then shows up in Mail and Calendar.
    @MainActor
    static func openInternetAccountsSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.internetaccounts"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}
