//
//  AgentRunStore.swift
//  leanring-buddy
//
//  JSON-file history of agent jobs. Artifact bytes stay in the workspace
//  folder; this store only keeps enough to render Agents-tab cards and
//  reopen Finder. Atomic writes match FileMemoryRepository.
//

import Foundation

@MainActor
final class FileAgentRunStore {

    private let fileURL: URL
    private var runs: [AgentRun]

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let fileData = try? Data(contentsOf: fileURL),
           let decodedRuns = try? JSONDecoder().decode([AgentRun].self, from: fileData) {
            self.runs = decodedRuns
        } else {
            self.runs = []
        }
    }

    /// Newest first — the Agents tab renders in this order inside a day group.
    func loadAll() -> [AgentRun] {
        runs.sorted { $0.createdAt > $1.createdAt }
    }

    func run(id: UUID) -> AgentRun? {
        runs.first { $0.id == id }
    }

    func upsert(_ run: AgentRun) {
        if let existingIndex = runs.firstIndex(where: { $0.id == run.id }) {
            runs[existingIndex] = run
        } else {
            runs.append(run)
        }
        persist()
    }

    func update(id: UUID, mutate: (inout AgentRun) -> Void) -> AgentRun? {
        guard let existingIndex = runs.firstIndex(where: { $0.id == id }) else { return nil }
        mutate(&runs[existingIndex])
        persist()
        return runs[existingIndex]
    }

    func runningRuns() -> [AgentRun] {
        loadAll().filter { !$0.status.isTerminal }
    }

    /// Closes out runs that were mid-flight when HeyMate last quit.
    ///
    /// A spawned CLI does not outlive the app, but this store does — so a job
    /// interrupted by a quit stays `running` forever, and its card goes on
    /// claiming to be working with no process behind it. At launch nothing is
    /// in flight by definition, so every non-terminal run found here was
    /// interrupted.
    ///
    /// `awaitingPlanApproval` is deliberately left alone: no process is meant
    /// to be alive for it. That plan is still good and still waiting on a
    /// decision, and closing it would throw away work the user was asked to
    /// review.
    ///
    /// Interrupted runs are marked failed rather than cancelled, because
    /// failed is terminal *and* keeps the session id — which is exactly what
    /// `canSendFollowUp` needs, so a job cut off mid-flight can be picked back
    /// up with Continue instead of started again from nothing.
    @discardableResult
    func reconcileInterruptedRuns(finishedAt: Date = Date()) -> [UUID] {
        var reconciledRunIDs: [UUID] = []

        for index in runs.indices {
            switch runs[index].status {
            case .queued, .planning, .running, .waitingForApproval:
                runs[index].status = .failed
                runs[index].error = "Interrupted — HeyMate quit while this was running."
                runs[index].latestAction = "Interrupted"
                runs[index].finishedAt = finishedAt
                runs[index].pid = nil
                runs[index].pendingApprovalID = ""
                reconciledRunIDs.append(runs[index].id)
            case .awaitingPlanApproval, .succeeded, .failed, .cancelled:
                continue
            }
        }

        if !reconciledRunIDs.isEmpty {
            persist()
        }
        return reconciledRunIDs
    }

    nonisolated static func appSupportFileURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let heymateDirectory = applicationSupportDirectory.appendingPathComponent("heymate", isDirectory: true)
        try? FileManager.default.createDirectory(at: heymateDirectory, withIntermediateDirectories: true)
        return heymateDirectory.appendingPathComponent("agent-runs.json")
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let fileData = try encoder.encode(runs)
            try fileData.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: an unwritable volume should not crash the app.
        }
    }
}

/// Day buckets for the Agents tab. Pure so tests can pin `now`.
nonisolated enum AgentRunDayGrouping {

    struct Section: Equatable {
        let title: String
        let runs: [AgentRun]
    }

    static func sections(
        from runs: [AgentRun],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Section] {
        let sortedRuns = runs.sorted { $0.createdAt > $1.createdAt }
        var buckets: [(title: String, runs: [AgentRun])] = []

        for run in sortedRuns {
            let title = dayTitle(for: run.createdAt, now: now, calendar: calendar)
            if let lastIndex = buckets.indices.last, buckets[lastIndex].title == title {
                buckets[lastIndex].runs.append(run)
            } else {
                buckets.append((title: title, runs: [run]))
            }
        }

        return buckets.map { Section(title: $0.title, runs: $0.runs) }
    }

    private static func dayTitle(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "TODAY"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "YESTERDAY"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date).uppercased()
    }
}
