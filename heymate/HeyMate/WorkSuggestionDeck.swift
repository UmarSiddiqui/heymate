import AppKit
import Combine
import SwiftUI

/// Passive, local-only suggestions. Nothing starts until reviewed and sent.
@MainActor
final class WorkSuggestionMemory: ObservableObject {
    private let defaults = UserDefaults.standard
    private let key = "heymate.workSuggestions.v1"
    @Published private var hiddenUntil: [String: Double]
    @Published private(set) var newSkillIDs: [String] = []
    private var knownSkills: Set<String>?

    init() { hiddenUntil = defaults.dictionary(forKey: key) as? [String: Double] ?? [:] }

    func isVisible(_ id: String, now: Date = Date()) -> Bool {
        (hiddenUntil[id] ?? 0) <= now.timeIntervalSince1970
    }

    func hide(_ id: String, for interval: TimeInterval) {
        hiddenUntil[id] = Date().addingTimeInterval(interval).timeIntervalSince1970
        if hiddenUntil.count > 128 {
            hiddenUntil = Dictionary(uniqueKeysWithValues: hiddenUntil.sorted { $0.value > $1.value }.prefix(128).map { ($0.key, $0.value) })
        }
        defaults.set(hiddenUntil, forKey: key)
    }

    func observeSkills(_ skills: [DiscoveredSkill]) {
        let current = Set(skills.filter { $0.origin != .bundledDefault }.map(\.id))
        if let knownSkills {
            newSkillIDs = Array(Set(newSkillIDs).union(current.subtracting(knownSkills))).filter(current.contains).sorted()
        }
        knownSkills = current
    }

    func dismissSkill(_ id: String) { newSkillIDs.removeAll { $0 == id } }
}

struct WorkSuggestionDeck: View {
    @ObservedObject var manager: CompanionManager
    @ObservedObject var memory: WorkSuggestionMemory
    @State private var selectedRun: AgentRun?
    @State private var instruction = ""
    @State private var error: String?

    private var isReady: Bool {
        !QuietPolicy.shouldSilenceAnnouncements() && !manager.isResponseInFlight && !manager.agentRuns.contains { !$0.status.isTerminal }
    }
    private var suggestions: [AgentRun] {
        guard isReady else { return [] }
        return Array(manager.agentRuns.filter {
            ($0.status == .failed || $0.status == .cancelled) && !$0.sessionIdentifier.isEmpty
                && Date().timeIntervalSince($0.finishedAt ?? $0.createdAt) < 7 * 86_400
                && memory.isVisible($0.id.uuidString)
        }.sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ideas & updates").font(.headline)
            Text("From your recent work. Review before anything starts.").font(.caption).foregroundStyle(.secondary)
            if !isReady { Text("Suggestions wait during quiet mode, work, or approvals.").font(.caption) }
            ForEach(manager.agentRuns.filter { !AgentProgressHealth.summary(for: $0).isEmpty }) { run in
                Text("\(run.title):\(AgentProgressHealth.summary(for: run))").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(suggestions) { run in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick up “\(run.title)”").font(.headline)
                    Text("\(run.status == .failed ? "Stopped with an error" : "Cancelled") · recent task").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Review / adjust") {
                            selectedRun = run
                            instruction = "Review the previous task and explain what remains before proposing the next small step."
                            error = nil
                        }
                        Button("Dismiss") { memory.hide(run.id.uuidString, for: 7 * 86_400) }
                        Button("Snooze 1 day") { memory.hide(run.id.uuidString, for: 86_400) }
                    }.font(.caption)
                }.padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(manager.discoveredSkills.filter { memory.newSkillIDs.contains($0.id) }) { skill in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Skill found: \(skill.skill.name)").font(.headline)
                    Text("\(skill.origin.displayLabel) · \(manager.isSkillActive(skill) ? "Active under existing skill settings" : "Available to review")")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Inspect") { NSWorkspace.shared.open(skill.fileURL) }
                        Button("Manage skills") {
                            NotificationCenter.default.post(name: .heyMateDesktopSelectSection, object: nil,
                                userInfo: ["section": DesktopSection.skills.rawValue])
                        }
                        Button("Dismiss") { memory.dismissSkill(skill.id) }
                    }.font(.caption)
                }.padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            if suggestions.isEmpty && memory.newSkillIDs.isEmpty && isReady {
                Text("Nothing needs a nudge. New skill discoveries appear here after tasks finish.").foregroundStyle(.secondary)
            }
        }.padding(18).frame(width: 480)
        .sheet(item: $selectedRun) { run in
            VStack(alignment: .leading, spacing: 16) {
                Text("Continue “\(run.title)”").font(.headline)
                Text("This resumes the same task and keeps its existing owner and approval gate.").font(.caption)
                TextEditor(text: $instruction).frame(height: 140)
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("Cancel") { selectedRun = nil }
                    Spacer()
                    Button("Send follow-up") {
                        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        guard isReady, let current = manager.agentRuns.first(where: { $0.id == run.id }),
                              current.status.isTerminal, current.resultDeliveryKey == run.resultDeliveryKey,
                              current.chatOwner == run.chatOwner else {
                            error = "Task changed or work is active. Close this review and check again; your draft is still here."
                            return
                        }
                        if manager.sendAgentFollowUp(runID: run.id, instruction: instruction) {
                            memory.hide(run.id.uuidString, for: 86_400)
                            selectedRun = nil
                        } else { error = "Task unavailable. Your draft is still here." }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 500)
        }
    }
}
