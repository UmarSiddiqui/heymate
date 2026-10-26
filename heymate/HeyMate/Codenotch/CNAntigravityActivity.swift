// Vendored/adapted from vinzdg/codenotch, MIT. Revision 6522e9f3ee0fe35d46e428b441e6e80b586eacbb.
// Upstream: Sources/Providers/AntigravityActivity.swift; see Codenotch-PROVENANCE.md for local changes.
import Foundation

/// How much Antigravity has actually been used, counted from its own
/// transcripts.
///
/// This exists because Google publishes no usage figure. `loadCodeAssist`
/// returns tiers and nothing else, the conversation databases carry no token or
/// quota columns, and whatever metadata comes back on `streamGenerateContent`
/// is consumed by the stream and never written down. Counting locally is the
/// only honest number available.
///
/// It is a *count*, never a percentage. A fraction needs a limit and there is
/// no published limit to divide by — inventing a denominator would put a
/// confident ring on a guess.
nonisolated struct CNAntigravityActivity: Equatable {
    let requestsToday: Int
    let lastRequest: Date?

    /// Every Antigravity install's transcripts, not just the first one found.
    ///
    /// Antigravity keeps a directory per flavour under `~/.gemini` —
    /// `antigravity`, `antigravity-ide`, `antigravity-cli`, `antigravity-backup`
    /// — and each has its own `brain`. Picking the first that *exists* looked
    /// reasonable and was not: leaving a flavour behind leaves its directory
    /// behind too, so on a machine that has run the IDE and then moved to the
    /// CLI all four exist and the first is empty. The count came out zero while
    /// the transcripts sat one directory over.
    ///
    /// So: all of them. Trajectories are UUID-named per install, so nothing is
    /// counted twice, and somebody who uses the IDE and the CLI in the same day
    /// gets one number for the day rather than whichever half was looked at.
    static var transcriptRoots: [URL] { transcriptRoots(home: URL(fileURLWithPath: NSHomeDirectory())) }

    static func transcriptRoots(home: URL) -> [URL] {
        let gemini = home.appendingPathComponent(".gemini")
        let names = (try? CNReadBudget.directory(gemini).map(\.lastPathComponent)) ?? []
        return names
            .filter { $0.hasPrefix("antigravity") }
            .sorted()
            .map { gemini.appendingPathComponent($0).appendingPathComponent("brain") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every install's activity, as one day's worth.
    static func read(roots: [URL] = transcriptRoots, now: Date = Date()) -> CNAntigravityActivity {
        roots.reduce(CNAntigravityActivity(requestsToday: 0, lastRequest: nil)) { total, root in
            let one = read(root: root, now: now)
            return CNAntigravityActivity(
                requestsToday: total.requestsToday + one.requestsToday,
                lastRequest: [total.lastRequest, one.lastRequest].compactMap { $0 }.max()
            )
        }
    }

    /// A step the model actually answered. User input and system checkpoints
    /// share the transcript, and counting those would inflate the number with
    /// work the model never did.
    private static let modelSource = "MODEL"

    /// One install's, which is what the combining read above is made of.
    static func read(root: URL, now: Date = Date()) -> CNAntigravityActivity {
        guard let trajectories = try? CNReadBudget.directory(root) else { return CNAntigravityActivity(requestsToday: 0, lastRequest: nil) }

        var today = 0
        var latest: Date?
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        for trajectory in trajectories {
            let transcript = trajectory
                .appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard let text = try? CNReadBudget.text(transcript) else { continue }

            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let step = try? JSONDecoder().decode(Step.self, from: data),
                      step.source == modelSource,
                      let at = parse(step.created_at)
                else { continue }

                if latest == nil || at > latest! { latest = at }
                // `created_at` is UTC — the trailing Z is not decoration. The
                // comparison has to be against the *local* day, which is what
                // `isDate(_:inSameDayAs:)` on a local calendar does; treating
                // the timestamp as local instead would move every count either
                // side of midnight by the offset.
                if calendar.isDate(at, inSameDayAs: now) { today += 1 }
            }
        }
        return CNAntigravityActivity(requestsToday: today, lastRequest: latest)
    }

    private struct Step: Decodable {
        let created_at: String
        let source: String?
    }

    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

}
