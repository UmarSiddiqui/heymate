//
//  MateParityViews.swift
//  HeyMate
//
//  Small views for routine history and time limits, the one list of every
//  agent's schedule, the backup brain choice, and sharing an agent as a file.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Routine history

/// The last runs as a row of marks, newest on the left, with the list a
/// click away. Nothing shows until the routine has run once.
struct RoutineHistoryStrip: View {
    let routine: MateRoutine
    @State private var isExpanded = false

    var body: some View {
        if let history = routine.history, !history.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        ForEach(history) { run in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Self.color(run.outcome))
                                .frame(width: 8, height: 8)
                        }
                        Text(isExpanded ? "Hide runs" : Self.headline(history))
                            .font(DS.Fonts.micro)
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.leading, 4)
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Recent runs, newest first")
                .accessibilityLabel(Self.headline(history))
                if isExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(history) { run in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(run.finishedAt.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundColor(DS.Colors.textSecondary)
                                Text(Self.label(run))
                                    .foregroundColor(Self.color(run.outcome))
                                Text(run.summary)
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(1)
                            }
                            .font(DS.Fonts.micro)
                        }
                    }
                }
            }
        }
    }

    static func color(_ outcome: MateRoutineRun.Outcome) -> Color {
        switch outcome {
        case .succeeded: return DS.Colors.textSecondary
        case .interrupted: return DS.Colors.textTertiary
        case .failed, .timedOut: return DS.Colors.warningText
        }
    }

    static func label(_ run: MateRoutineRun) -> String {
        let took = duration(run.duration)
        switch run.outcome {
        case .succeeded: return "Done in \(took)"
        case .failed: return "Failed after \(took)"
        case .interrupted: return "Stopped after \(took)"
        case .timedOut: return "Hit time limit"
        }
    }

    static func headline(_ history: [MateRoutineRun]) -> String {
        let good = history.filter { $0.outcome == .succeeded }.count
        return "\(good) of last \(history.count) runs finished"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(1, Int(seconds.rounded())))s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// "Time limit: 30 min" with the choices behind it.
struct RoutineRunLimitMenu: View {
    let routine: MateRoutine
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        Menu {
            Button("No limit") { companionManager.setRoutineRunLimit(id: routine.id, minutes: nil) }
            ForEach(MateRoutineAccounting.runLimitChoices, id: \.self) { minutes in
                Button(Self.text(minutes)) { companionManager.setRoutineRunLimit(id: routine.id, minutes: minutes) }
            }
        } label: {
            Text(routine.maxRunMinutes.map { "Limit \(Self.text($0))" } ?? "No time limit")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Stop a run that is still going after this long")
    }

    static func text(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr"
    }
}

// MARK: Every schedule in one place

/// Every routine and wake across all agents, soonest first, so the person
/// can see what will happen without opening each agent.
struct MateSchedulesSheet: View {
    @ObservedObject var companionManager: CompanionManager
    @Environment(\.dismiss) private var dismiss

    private var sortedRoutines: [MateRoutine] {
        companionManager.routines.sorted { lhs, rhs in
            let lhsPaused = lhs.pausedReason != nil, rhsPaused = rhs.pausedReason != nil
            if lhsPaused != rhsPaused { return !lhsPaused }
            return lhs.nextRunAt < rhs.nextRunAt
        }
    }

    private var wakes: [(mate: Mate, wake: MateWake)] {
        companionManager.mates.filter { !$0.archived }.compactMap { mate in
            companionManager.wake(for: mate.id).map { (mate, $0) }
        }
    }

    private func name(_ id: UUID) -> String {
        companionManager.mates.first { $0.id == id }?.name ?? Mate.defaultName
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Schedules").font(DS.Fonts.title)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.small)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        label("Routines")
                        if sortedRoutines.isEmpty {
                            empty("No agent has a routine yet. Tell one “check my inbox every morning”.")
                        }
                        ForEach(sortedRoutines) { routine in
                            VStack(alignment: .leading, spacing: 4) {
                                if routine.pausedReason == nil {
                                    Text("Next " + routine.nextRunAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(DS.Fonts.micro)
                                        .foregroundColor(DS.Colors.textTertiary)
                                }
                                RoutineRow(
                                    routine: routine,
                                    showsMateName: true,
                                    mateName: name(routine.mateID),
                                    companionManager: companionManager
                                )
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        label("Offers to help when")
                        if wakes.isEmpty {
                            empty("No agent is watching for anything. Set one in an agent's settings.")
                        }
                        ForEach(wakes, id: \.wake.id) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.mate.name)
                                    .font(DS.Fonts.caption.weight(.semibold))
                                    .foregroundColor(DS.Colors.textTertiary)
                                Text(item.wake.kind.label + (item.wake.match.isEmpty ? "" : ": \(item.wake.match)"))
                                    .font(DS.Fonts.headline)
                                    .foregroundColor(DS.Colors.textPrimary)
                                if let last = item.wake.lastOfferedAt {
                                    Text("Last offered " + last.formatted(date: .abbreviated, time: .shortened))
                                        .font(DS.Fonts.body)
                                        .foregroundColor(DS.Colors.textTertiary)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                    .fill(DS.Colors.surface2)
                            )
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .preferredColorScheme(.dark)
        .background(DS.Colors.background)
        .frame(width: 520)
        .frame(minHeight: 360, idealHeight: 620, maxHeight: 760)
        .tint(DS.Colors.accent)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(DS.Fonts.sectionLabel).foregroundColor(DS.Colors.textTertiary)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(DS.Fonts.body).foregroundColor(DS.Colors.textTertiary)
    }
}

// MARK: Per-agent Brain, effort, and backup brain

struct MateBackupBrainField: View {
    let mate: Mate
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var setup = MateAgentSetupController.shared

    private var currentMate: Mate {
        companionManager.mates.first { $0.id == mate.id } ?? mate
    }
    private var appBrain: AgentBrain? { BrainProviderMapping.brain(forProvider: setup.currentProvider) }
    private var explicitPrimary: AgentBrain? { currentMate.brainRawValue.flatMap(AgentBrain.init(rawValue:)) }
    private var effectivePrimary: AgentBrain? { explicitPrimary ?? appBrain }
    private var explicitBackup: AgentBrain? { currentMate.backupBrainRawValue.flatMap(AgentBrain.init(rawValue:)) }

    private var authenticatedBrains: [AgentBrain] {
        AgentBrain.allCases.filter { brain in
            guard let provider = BrainProviderMapping.provider(for: brain) else { return false }
            return setup.providers.isEmpty || setup.providers.contains { $0.id == provider && $0.authenticated }
        }
    }

    private var backupChoices: [AgentBrain] {
        authenticatedBrains.filter { $0 != effectivePrimary }
    }

    private static let effortOptions: [(id: String?, label: String)] = [
        (nil, "App default"),
        ("low", "Low (faster)"),
        ("medium", "Medium"),
        ("high", "High (deeper)")
    ]

    private var currentEffortLabel: String {
        Self.effortOptions.first { $0.id == currentMate.effortRawValue }?.label
            ?? (currentMate.effortRawValue?.capitalized ?? "App default")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Brain & failover")
                    .font(DS.Fonts.sectionLabel)
                    .foregroundColor(DS.Colors.textTertiary)
                Text("For this agent only. Saved right away")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("Brain:")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                    Menu {
                        Button("App default (\(appBrain?.displayName ?? "Brain"))") {
                            companionManager.setMatePrimaryBrain(id: mate.id, brain: nil)
                        }
                        ForEach(authenticatedBrains, id: \.self) { brain in
                            Button(brain.displayName) {
                                companionManager.setMatePrimaryBrain(id: mate.id, brain: brain)
                            }
                        }
                    } label: {
                        Text(explicitPrimary?.displayName ?? "App default (\(appBrain?.displayName ?? "Brain"))")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                HStack(spacing: 6) {
                    Text("Effort:")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                    Menu {
                        ForEach(Self.effortOptions, id: \.label) { option in
                            Button(option.label) {
                                companionManager.setMateEffort(id: mate.id, effort: option.id)
                            }
                        }
                    } label: {
                        Text(currentEffortLabel)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            HStack(spacing: 8) {
                Text("When \(effectivePrimary?.displayName ?? "its Brain") hits a usage limit, use")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                Menu {
                    if !mate.conductsOthers, let appBackup = companionManager.appBackupBrain {
                        Button("App default (\(appBackup.displayName))") {
                            companionManager.setMateBackupBrain(id: mate.id, brain: nil)
                        }
                    } else {
                        Button("Nothing, wait for reset") {
                            companionManager.setMateBackupBrain(id: mate.id, brain: nil)
                        }
                    }
                    ForEach(backupChoices, id: \.self) { brain in
                        Button(brain.displayName) {
                            companionManager.setMateBackupBrain(id: mate.id, brain: brain)
                        }
                    }
                } label: {
                    if let explicitBackup {
                        Text(explicitBackup.displayName)
                    } else if !mate.conductsOthers, let appBackup = companionManager.appBackupBrain {
                        Text("App default (\(appBackup.displayName))")
                    } else {
                        Text("nothing")
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let effectivePrimary, let until = companionManager.brainLimitLedger.limitedUntil(effectivePrimary) {
                Text("\(effectivePrimary.displayName) is at its limit until about \(until.formatted(date: .omitted, time: .shortened)).")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
            }
        }
    }
}

// MARK: Share an agent as a file

@MainActor
enum MateFileTransfer {
    /// Asks where to save, then writes the agent's Markdown there.
    static func export(mateID: UUID, companionManager: CompanionManager) {
        guard let mate = companionManager.mates.first(where: { $0.id == mateID }),
              let text = companionManager.mateMarkdown(id: mateID) else { return }
        let panel = NSSavePanel()
        panel.title = "Export \(mate.name)"
        panel.message = "Chats, folders, and sign-ins stay on this Mac."
        panel.nameFieldStringValue = MateMarkdown.suggestedFileName(for: mate.name)
        panel.allowedContentTypes = [UTType(filenameExtension: MateMarkdown.fileExtension) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert("Couldn't save \(mate.name).", detail: error.localizedDescription)
        }
    }

    /// Picks a file, shows what it would add, and adds it on yes.
    static func importFromFile(companionManager: CompanionManager, onImported: (Mate) -> Void = { _ in }) {
        let panel = NSOpenPanel()
        panel.title = "Import an agent"
        panel.allowedContentTypes = [UTType(filenameExtension: MateMarkdown.fileExtension) ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), data.count <= MateMarkdown.maximumBytes,
              let text = String(data: data, encoding: .utf8) else {
            alert("Couldn't read that file.", detail: MateMarkdown.ReadError.tooLarge.message)
            return
        }
        let document: MateMarkdownDocument
        switch MateMarkdown.parse(text) {
        case .success(let parsed): document = parsed
        case .failure(let error):
            alert("Couldn't import that file.", detail: error.message)
            return
        }
        let review = NSAlert()
        review.messageText = "Add \(document.name)?"
        var lines = [document.job]
        if !document.routines.isEmpty {
            lines.append("\(document.routines.count) routine\(document.routines.count == 1 ? "" : "s") arrive paused. Nothing runs until you resume it.")
        }
        if let kind = document.wakeKind { lines.append("Offers to help: \(kind.label.lowercased()).") }
        if !document.asksFirst.isEmpty { lines.append("Asks you before: " + document.asksFirst.joined(separator: ", ") + ".") }
        review.informativeText = lines.joined(separator: "\n\n")
        review.addButton(withTitle: "Add agent")
        review.addButton(withTitle: "Cancel")
        guard review.runModal() == .alertFirstButtonReturn else { return }
        switch companionManager.importMate(document) {
        case .success(let mate): onImported(mate)
        case .failure(let error): alert("Couldn't import that agent.", detail: error.message)
        }
    }

    private static func alert(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
