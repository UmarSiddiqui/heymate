//
//  MateWake.swift
//  HeyMate
//
//  What makes an agent offer to work without being asked: a file that just
//  finished downloading, a link that was just copied, a meeting about to
//  start, an app coming to the front, or new mail. A match only produces an
//  offer. Nothing is read, copied or sent to the agent until the person
//  says yes, and every wake belongs to one agent and is shown on it.
//

import Foundation

nonisolated enum MateWakeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case downloadedFile
    case copiedLink
    case meetingSoon
    case appOpened
    case newMail

    var id: String { rawValue }

    var label: String {
        switch self {
        case .downloadedFile: return "A file finishes downloading"
        case .copiedLink: return "I copy a link"
        case .meetingSoon: return "A meeting is about to start"
        case .appOpened: return "I open an app"
        case .newMail: return "New mail arrives"
        }
    }

    /// Short form for a card or a row.
    var chip: String {
        switch self {
        case .downloadedFile: return "On download"
        case .copiedLink: return "On copied link"
        case .meetingSoon: return "Before meetings"
        case .appOpened: return "On app open"
        case .newMail: return "On new mail"
        }
    }

    /// What the optional filter narrows, as a text field prompt.
    var matchPrompt: String {
        switch self {
        case .downloadedFile: return "Only these file types, like pdf, png (optional)"
        case .copiedLink: return "Only these sites, like github.com (optional)"
        case .meetingSoon: return "Only meetings with these words (optional)"
        case .appOpened: return "App name, like Figma"
        case .newMail: return "Only from or about, like invoice (optional)"
        }
    }

    /// An app wake with no app named would fire on every switch.
    var requiresMatch: Bool { self == .appOpened }

    /// What HeyMate has to watch for this, said plainly before it is saved.
    var watchNote: String {
        switch self {
        case .downloadedFile:
            return "HeyMate watches the names of new files in Downloads. A file is copied to the agent only when you say yes. macOS asks once to allow Downloads."
        case .copiedLink:
            return "HeyMate checks whether what you copy is a link. Other copied text is not read and nothing is stored. macOS may ask once to allow pasting."
        case .meetingSoon:
            return "Needs Calendar turned on in Apps. HeyMate reads the next meeting's title and time."
        case .appOpened:
            return "HeyMate notices which app comes to the front. It does not read the screen."
        case .newMail:
            return "Needs Mail turned on in Apps and the Mail app open. HeyMate reads senders and subjects, never bodies."
        }
    }

    /// Minutes before the same wake may offer again.
    var defaultCooldownMinutes: Int {
        switch self {
        case .downloadedFile, .meetingSoon, .newMail: return 0
        case .copiedLink: return 2
        case .appOpened: return 240
        }
    }
}

nonisolated struct MateWake: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var mateID: UUID
    var kind: MateWakeKind
    /// Comma-separated filter. Empty means anything of this kind.
    var match: String
    /// What the agent is asked to do with the thing that woke it.
    var task: String
    var enabled: Bool
    var cooldownMinutes: Int
    var lastOfferedAt: Date? = nil
    /// The last thing offered, so the same file or link is not offered twice.
    var lastSubject: String? = nil

    var terms: [String] { MateWakeMatcher.terms(match) }

    static func make(mateID: UUID, kind: MateWakeKind, match: String, task: String) -> MateWake {
        MateWake(
            id: UUID(),
            mateID: mateID,
            kind: kind,
            match: MateWakeMatcher.cleanedMatch(match),
            task: String(task.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)),
            enabled: true,
            cooldownMinutes: kind.defaultCooldownMinutes
        )
    }
}

/// Something that just happened on this Mac. `subject` is the file name,
/// the link, the meeting title, the app name, or "sender: subject".
nonisolated struct MateWakeSignal: Equatable, Sendable {
    let kind: MateWakeKind
    let subject: String
    /// Set for a downloaded file: where it is, so a yes can hand it over.
    var fileURL: URL? = nil
    /// Tells two events with the same subject apart, such as a meeting's start.
    var occurrence: String = ""
    let observedAt: Date

    var subjectKey: String { occurrence.isEmpty ? subject : "\(subject)|\(occurrence)" }
}

nonisolated struct MateWakeOffer: Equatable, Identifiable, Sendable {
    let id: UUID
    let wakeID: UUID
    let mateID: UUID
    let mateName: String
    let kind: MateWakeKind
    /// One line the person can answer with a tap, such as "Tidy invoice.pdf?".
    let question: String
    /// What is sent to the agent on yes.
    let prompt: String
    let fileURL: URL?
    let createdAt: Date
}

nonisolated enum MateWakeMatcher {
    static let maximumOffers = 3
    static let offerLifetime: TimeInterval = 30 * 60
    static let meetingLeadTime: TimeInterval = 10 * 60

    static func terms(_ match: String) -> [String] {
        match.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
    }

    static func cleanedMatch(_ match: String) -> String {
        String(terms(match).joined(separator: ", ").prefix(120))
    }

    /// The link when the copied text is one web address and nothing else.
    /// Anything longer, or with other words around it, is not a link copy.
    static func link(in copiedText: String) -> URL? {
        let text = copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2_000,
              !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, host.contains(".") else { return nil }
        return url
    }

    static func matches(_ wake: MateWake, signal: MateWakeSignal) -> Bool {
        guard wake.enabled, wake.kind == signal.kind else { return false }
        let terms = wake.terms
        if terms.isEmpty { return !wake.kind.requiresMatch }
        let subject = signal.subject.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        switch wake.kind {
        case .downloadedFile:
            let ext = (signal.subject as NSString).pathExtension.lowercased()
            return terms.contains(ext)
        case .copiedLink:
            let host = URL(string: signal.subject)?.host?.lowercased() ?? ""
            return terms.contains { host == $0 || host.hasSuffix("." + $0) || host.contains($0) }
        case .appOpened:
            return terms.contains { subject == $0 }
        case .meetingSoon, .newMail:
            return terms.contains { subject.contains($0) }
        }
    }

    static func cooldownAllows(_ wake: MateWake, signal: MateWakeSignal) -> Bool {
        if wake.lastSubject == signal.subjectKey { return false }
        guard let last = wake.lastOfferedAt else { return true }
        return signal.observedAt.timeIntervalSince(last) >= TimeInterval(max(0, wake.cooldownMinutes) * 60)
    }

    /// The offer for this signal, if an agent is waiting for it. A wake with
    /// a filter beats one that takes anything, so "github.com links" wins
    /// over "any link". Archived agents never offer.
    static func offer(
        for signal: MateWakeSignal,
        wakes: [MateWake],
        mates: [Mate],
        pending: [MateWakeOffer] = []
    ) -> MateWakeOffer? {
        let live = Dictionary(uniqueKeysWithValues: mates.filter { !$0.archived }.map { ($0.id, $0) })
        let candidates = wakes
            .filter { live[$0.mateID] != nil && matches($0, signal: signal) && cooldownAllows($0, signal: signal) }
            .sorted { !$0.terms.isEmpty && $1.terms.isEmpty }
        guard let wake = candidates.first, let mate = live[wake.mateID] else { return nil }
        // One open offer per wake: a burst of downloads asks once.
        guard !pending.contains(where: { $0.wakeID == wake.id }) else { return nil }
        return MateWakeOffer(
            id: UUID(),
            wakeID: wake.id,
            mateID: mate.id,
            mateName: mate.name,
            kind: wake.kind,
            question: question(for: wake, signal: signal),
            prompt: prompt(for: wake, signal: signal),
            fileURL: signal.fileURL,
            createdAt: signal.observedAt
        )
    }

    static func recordOffer(_ wake: MateWake, signal: MateWakeSignal) -> MateWake {
        var copy = wake
        copy.lastOfferedAt = signal.observedAt
        copy.lastSubject = signal.subjectKey
        return copy
    }

    /// Offers still worth showing, newest first.
    static func current(_ offers: [MateWakeOffer], now: Date) -> [MateWakeOffer] {
        Array(offers
            .filter { now.timeIntervalSince($0.createdAt) < offerLifetime }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(maximumOffers))
    }

    static func shortSubject(_ signal: MateWakeSignal) -> String {
        let text: String
        switch signal.kind {
        case .copiedLink:
            text = URL(string: signal.subject)?.host?.replacingOccurrences(of: "www.", with: "") ?? signal.subject
        default:
            text = signal.subject
        }
        let single = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return single.count > 48 ? String(single.prefix(47)) + "…" : single
    }

    static func question(for wake: MateWake, signal: MateWakeSignal) -> String {
        let subject = shortSubject(signal)
        switch wake.kind {
        case .downloadedFile: return "Take \(subject)?"
        case .copiedLink: return "Look into the link from \(subject)?"
        case .meetingSoon: return "Prepare for \(subject)?"
        case .appOpened: return "Start now that \(subject) is open?"
        case .newMail: return "Handle mail from \(subject)?"
        }
    }

    /// The task, then the one fact that woke the agent. A downloaded file is
    /// named by the hand-off line added when it is copied, not here.
    static func prompt(for wake: MateWake, signal: MateWakeSignal) -> String {
        let task = wake.task.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = task.isEmpty ? defaultTask(wake.kind) : task
        switch wake.kind {
        case .downloadedFile: return lead
        case .copiedLink: return "\(lead)\nLink: \(signal.subject)"
        case .meetingSoon: return "\(lead)\nMeeting: \(signal.subject)"
        case .appOpened: return "\(lead)\nI just opened \(signal.subject)."
        case .newMail: return "\(lead)\nNew mail: \(signal.subject)"
        }
    }

    static func defaultTask(_ kind: MateWakeKind) -> String {
        switch kind {
        case .downloadedFile: return "Deal with this file I just downloaded and tell me what you did."
        case .copiedLink: return "Read this link and tell me what matters in it."
        case .meetingSoon: return "Write a short prep note for this meeting."
        case .appOpened: return "Do your usual work for this app."
        case .newMail: return "Look at this new mail and draft a reply if it needs one."
        }
    }
}

/// Names in Downloads that are finished files, and which of them are new.
nonisolated enum MateWakeDownloads {
    static let partialSuffixes = [".download", ".crdownload", ".part", ".partial", ".tmp", ".opdownload"]

    static func isFinishedName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard !lowered.hasPrefix("."), !lowered.hasPrefix("~") else { return false }
        return !partialSuffixes.contains { lowered.hasSuffix($0) }
    }

    /// Finished names in `current` that were not there before, oldest name
    /// first. A first look has no "before", so it reports nothing.
    static func newlyFinished(previous: Set<String>?, current: Set<String>) -> [String] {
        guard let previous else { return [] }
        return current.subtracting(previous).filter(isFinishedName).sorted()
    }
}

/// Unread inbox lines that were not there on the last look.
nonisolated enum MateWakeMail {
    struct Row: Equatable, Sendable {
        let received: String
        let sender: String
        let subject: String
        let unread: Bool

        var key: String { "\(received)|\(sender)|\(subject)" }
        /// "Ada Lovelace: Invoice 42", without the address in angle brackets.
        var summary: String {
            let name = sender.split(separator: "<").first
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? sender
            return "\(name.isEmpty ? sender : name): \(subject)"
        }
    }

    /// Rows from the tab-separated text the Mail reader returns.
    static func rows(rawOutput: String) -> [Row] {
        var text = rawOutput
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        text = text
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { return nil }
            return Row(received: fields[0], sender: fields[1], subject: fields[2], unread: fields[3] == "unread")
        }
    }

    static func newUnread(previousKeys: Set<String>?, rows: [Row]) -> [Row] {
        guard let previousKeys else { return [] }
        return rows.filter { $0.unread && !previousKeys.contains($0.key) }
    }
}
