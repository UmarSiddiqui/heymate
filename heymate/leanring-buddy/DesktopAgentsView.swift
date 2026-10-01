//
//  DesktopAgentsView.swift
//  leanring-buddy
//
//  Jobs: the work mates do over time (an agent run underneath), with room
//  to actually watch one work. Reached from the Jobs button in chat.
//
//  Structure follows the shape of the job rather than the shape of the
//  data: a composer at the top (say what you want), a live section for
//  anything still running or waiting on you, then history grouped by day.
//  A run that needs approval is pulled to the very top and given a
//  different card treatment, because "the agent is blocked on you" is the
//  only state in this screen that is time-sensitive.
//
//  Progress lines are the agent's own `latestAction` — real steps like
//  "Reading the visible PDF", never a fake percentage.
//

import AppKit
import SwiftUI

struct DesktopAgentsView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var promptText = ""
    @State private var attachedFolderURL: URL?
    @State private var selectedRunID: UUID?
    @State private var selectedThreadSurface: AgentThreadSurface = .activity
    @State private var conversationText = ""
    @State private var isCreatingStandingOrder = false
    @State private var standingOrderName = ""
    @State private var standingOrderContains = ""
    @State private var standingOrderTask = ""
    @State private var standingOrderSignalKind: StandingOrderSignalKind = .clipboard
    @State private var standingOrderCooldownMinutes = "60"
    @State private var standingOrderForMinutes = "0"
    @State private var editingStandingOrderID: String?
    @State private var standingOrderPendingDelete: StandingOrder?
    @State private var isConfirmingUndo = false

    /// The job whose takeover is waiting on confirmation. Taking over kills
    /// the process HeyMate is driving, so it asks first.
    @State private var runPendingTerminalTakeover: AgentRun?
    @State private var runIDPendingCancel: UUID?
    @State private var runIDPendingRemoval: UUID?
    @State private var runIDPendingFolderTrash: UUID?
    @State private var undoEntryPendingRestore: AgentUndoEntry?

    /// Drives only the composer focus ring and glow — pure presentation.
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        DesktopPage(
            title: "Jobs",
            subtitle: subtitleText,
            accessory: AnyView(
                DesktopComposerModelButton(companionManager: companionManager)
            )
        ) {
            composer

            if let proposal = companionManager.standingOrderProposal {
                standingOrderProposalCard(proposal)
            }

            standingOrdersAndUndoCard

            if !companionManager.agentRevealErrorText.isEmpty {
                Text(companionManager.agentRevealErrorText)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
            }

            if !runsNeedingAttention.isEmpty {
                section(title: "Needs you") {
                    ForEach(runsNeedingAttention) { run in
                        agentCard(run, isHighlighted: true)
                    }
                }
            }

            if !activeRuns.isEmpty {
                section(title: "Running") {
                    ForEach(activeRuns) { run in
                        agentCard(run, isHighlighted: false)
                    }
                }
            }

            if finishedSections.isEmpty && activeRuns.isEmpty && runsNeedingAttention.isEmpty {
                DesktopEmptyState(
                    symbolName: "sparkles",
                    title: "No jobs yet",
                    message: "Ask a mate to make or change something, or type a job above. HeyMate plans first, asks before changing anything, and works in its own folder under ~/Projects/heymate unless you pick one."
                )
            }

            ForEach(finishedSections, id: \.title) { daySection in
                section(title: daySection.title.capitalized) {
                    ForEach(daySection.runs) { run in
                        agentCard(run, isHighlighted: false)
                    }
                }
            }
        }
        .confirmationDialog(
            "Undo the last job?",
            isPresented: $isConfirmingUndo,
            titleVisibility: .visible
        ) {
            Button("Undo last job", role: .destructive) {
                companionManager.undoLastAgentWork()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The folder goes back to how it was before that job. A copy of what is there now is kept, just in case.")
        }
        .confirmationDialog(
            "Take over this job in Terminal?",
            isPresented: Binding(
                get: { runPendingTerminalTakeover != nil },
                set: { isPresented in
                    if !isPresented { runPendingTerminalTakeover = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Open in Terminal") {
                if let runPendingTerminalTakeover {
                    companionManager.takeOverAgentInTerminal(runID: runPendingTerminalTakeover.id)
                }
                runPendingTerminalTakeover = nil
            }
            Button("Cancel", role: .cancel) { runPendingTerminalTakeover = nil }
        } message: {
            Text(
                runPendingTerminalTakeover
                    .map { AgentTerminalTakeover.takeoverDescription(for: $0.executor) }
                    ?? ""
            )
        }
        .confirmationDialog(
            "Stop this job?",
            isPresented: Binding(
                get: { runIDPendingCancel != nil },
                set: { isPresented in
                    if !isPresented { runIDPendingCancel = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop job", role: .destructive) {
                if let runIDPendingCancel {
                    companionManager.cancelAgent(runID: runIDPendingCancel)
                }
                runIDPendingCancel = nil
            }
            Button("Cancel", role: .cancel) { runIDPendingCancel = nil }
        } message: {
            Text("Work already written in its folder stays.")
        }
        .confirmationDialog(
            "Remove this job from the list?",
            isPresented: Binding(
                get: { runIDPendingRemoval != nil },
                set: { isPresented in
                    if !isPresented { runIDPendingRemoval = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let runIDPendingRemoval {
                    companionManager.deleteAgentRun(runID: runIDPendingRemoval)
                }
                runIDPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { runIDPendingRemoval = nil }
        } message: {
            Text("The folder on disk stays unless you also delete it.")
        }
        .confirmationDialog(
            "Move folder to Trash?",
            isPresented: Binding(
                get: { runIDPendingFolderTrash != nil },
                set: { isPresented in
                    if !isPresented { runIDPendingFolderTrash = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Move folder to Trash", role: .destructive) {
                if let runIDPendingFolderTrash {
                    companionManager.moveAgentFolderToTrash(runID: runIDPendingFolderTrash)
                }
                runIDPendingFolderTrash = nil
            }
            Button("Cancel", role: .cancel) { runIDPendingFolderTrash = nil }
        } message: {
            Text("HeyMate then removes this job from the list. If the folder is already gone, the list entry stays.")
        }
        .confirmationDialog(
            "Restore this earlier snapshot?",
            isPresented: Binding(
                get: { undoEntryPendingRestore != nil },
                set: { isPresented in
                    if !isPresented { undoEntryPendingRestore = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore snapshot", role: .destructive) {
                if let undoEntryPendingRestore {
                    companionManager.restoreAgentUndoEntry(entryID: undoEntryPendingRestore.id)
                }
                undoEntryPendingRestore = nil
            }
            Button("Cancel", role: .cancel) { undoEntryPendingRestore = nil }
        } message: {
            Text("A copy of what is in the folder now is kept before this snapshot is restored.")
        }
    }

    private var subtitleText: String {
        let runningCount = activeRuns.count + runsNeedingAttention.count
        if runningCount > 0 {
            return "\(runningCount) in progress. Chat answers now; jobs are work your mates do over time."
        }
        return "Chat answers now. Jobs are work your mates do over time, in their own folder."
    }

    // MARK: Partitions

    private var runsNeedingAttention: [AgentRun] {
        companionManager.agentRuns.filter(\.status.needsUser)
    }

    private var activeRuns: [AgentRun] {
        companionManager.agentRuns.filter {
            $0.status == .running || $0.status == .queued || $0.status == .planning
        }
    }

    private var finishedSections: [AgentRunDayGrouping.Section] {
        AgentRunDayGrouping.sections(
            from: companionManager.agentRuns.filter { $0.status.isTerminal }
        )
    }

    // MARK: Composer

    private var composer: some View {
        DesktopCard {
            VStack(alignment: .leading, spacing: 10) {
                TextField(
                    attachedFolderURL == nil
                        ? "Describe a job for HeyMate"
                        : "What should HeyMate do in \(attachedFolderURL!.lastPathComponent)?",
                    text: $promptText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(DS.Fonts.body)
                .lineLimit(1...4)
                .focused($isComposerFocused)
                .onSubmit(startRun)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isComposerFocused
                                ? companionManager.themeColor.opacity(0.55)
                                : DS.Colors.borderSubtle,
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: companionManager.themeColor.opacity(isComposerFocused ? 0.18 : 0),
                    radius: 10
                )

                HStack(spacing: 8) {
                    Button {
                        pickAttachedFolder()
                    } label: {
                        Label(
                            attachedFolderURL?.lastPathComponent ?? "Run in folder…",
                            systemImage: attachedFolderURL == nil ? "folder.badge.plus" : "folder.fill"
                        )
                        .font(DS.Fonts.caption)
                    }
                    .buttonStyle(DSTertiaryButtonStyle())
                    .help("Attach an existing repository. Writes there pause for your approval.")

                    if attachedFolderURL != nil {
                        Button {
                            attachedFolderURL = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help("Back to a new folder of its own")
                    }

                    Spacer(minLength: 0)

                    Button("Start", action: startRun)
                        .buttonStyle(DSPrimaryButtonStyle())
                        .disabled(trimmedPrompt.isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        } 
    }

    private var trimmedPrompt: String {
        promptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var standingOrderProposalTask: String {
        standingOrderTask.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var standingOrderCooldownValue: Int? {
        let trimmed = standingOrderCooldownMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 1 else { return nil }
        return value
    }

    private var standingOrderForMinutesValue: Int? {
        let trimmed = standingOrderForMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    private var canSaveStandingOrder: Bool {
        !standingOrderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !standingOrderContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !standingOrderProposalTask.isEmpty
            && standingOrderCooldownValue != nil
            && standingOrderForMinutesValue != nil
    }

    private func startRun() {
        guard !trimmedPrompt.isEmpty else { return }
        if let attachedFolderURL {
            companionManager.startAttachedAgent(
                prompt: trimmedPrompt,
                workspaceURL: attachedFolderURL
            )
        } else {
            companionManager.startSandboxAgent(prompt: trimmedPrompt)
        }
        promptText = ""
    }

    private func pickAttachedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Attach"
        panel.message = "Pick the folder this job may work in. Changes there will ask for your approval."
        guard panel.runModal() == .OK, let chosenURL = panel.url else { return }
        attachedFolderURL = chosenURL
    }

    // MARK: Suggestions and Undo
    //
    // Standing orders are shown to people as "Suggestions": rules for work
    // HeyMate may offer when it notices a match, and never starts unasked.

    private func standingOrderProposalCard(_ proposal: StandingOrderProposal) -> some View {
        DesktopCard {
            VStack(alignment: .leading, spacing: 9) {
                Label("Suggestion", systemImage: "bell.badge")
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(DS.Colors.warningText)
                Text(proposal.title)
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(proposal.task)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Want me to look into this? Saying yes only makes a plan. Nothing changes until you approve that plan too.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                HStack(spacing: 8) {
                    Button("Plan it") { companionManager.approveStandingOrderProposal() }
                        .buttonStyle(DSPrimaryButtonStyle())
                    Button("Dismiss") { companionManager.dismissStandingOrderProposal() }
                        .buttonStyle(DSSecondaryButtonStyle())
                }
            }
        }
    }

    private var suggestionsSummary: String {
        let count = companionManager.loadedStandingOrders.count
        let saved = count == 1 ? "1 saved" : "\(count) saved"
        return "\(saved) · HeyMate offers these jobs and never starts one unasked"
    }

    private var standingOrdersAndUndoCard: some View {
        DesktopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggestions")
                            .font(DS.Fonts.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(suggestionsSummary)
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Button(isCreatingStandingOrder ? "Close" : "New suggestion") {
                        if isCreatingStandingOrder {
                            resetStandingOrderComposer()
                        } else {
                            editingStandingOrderID = nil
                            isCreatingStandingOrder = true
                        }
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    Button("Open folder") { companionManager.revealStandingOrdersFolder() }
                        .buttonStyle(DSTertiaryButtonStyle())
                }

                if isCreatingStandingOrder {
                    standingOrderComposer
                }

                if companionManager.loadedStandingOrders.isEmpty {
                    Text("No suggestions yet. Add one and HeyMate will offer that job when it sees a match.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    ForEach(companionManager.loadedStandingOrders) { order in
                        standingOrderRow(order)
                    }
                }

                Divider().overlay(DS.Colors.borderSubtle)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Undo")
                            .font(DS.Fonts.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(companionManager.latestAgentUndoEntry?.runTitle ?? "Nothing to undo yet")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Undo last job") { isConfirmingUndo = true }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .disabled(companionManager.latestAgentUndoEntry == nil)
                }

                agentUndoSnapshotDetail

                if !companionManager.agentUndoErrorText.isEmpty {
                    Text(companionManager.agentUndoErrorText)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.destructiveText)
                }
            }
        }
        .confirmationDialog(
            "Delete this suggestion?",
            isPresented: Binding(
                get: { standingOrderPendingDelete != nil },
                set: { isPresented in
                    if !isPresented { standingOrderPendingDelete = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete suggestion", role: .destructive) {
                guard let order = standingOrderPendingDelete else { return }
                let didDelete = companionManager.deleteStandingOrder(order)
                guard didDelete else { return }
                if editingStandingOrderID == order.id {
                    resetStandingOrderComposer()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the Markdown file for \(standingOrderPendingDelete?.name ?? "this suggestion"). HeyMate will stop offering the task.")
        }
    }

    @ViewBuilder
    private var agentUndoSnapshotDetail: some View {
        let snapshots = companionManager.readyAgentUndoEntries()
        if snapshots.count > 1 {
            ForEach(snapshots) { entry in
                HStack(spacing: 8) {
                    Text(agentUndoSnapshotLabel(entry))
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if entry.id != companionManager.latestAgentUndoEntry?.id {
                        Button("Restore") { undoEntryPendingRestore = entry }
                            .buttonStyle(DSTertiaryButtonStyle())
                    }
                }
            }
        } else if snapshots.count == 1 {
            Text("Only the latest job can be undone.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private func agentUndoSnapshotLabel(_ entry: AgentUndoEntry) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(entry.runTitle) · \(formatter.string(from: entry.createdAt))"
    }

    private var standingOrderComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editingStandingOrderID != nil {
                Text("Editing this suggestion rewrites its Markdown file.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            TextField("Name", text: $standingOrderName)
                .textFieldStyle(.roundedBorder)
            Picker("Signal", selection: $standingOrderSignalKind) {
                ForEach(StandingOrderSignalKind.allCases, id: \.self) { signalKind in
                    Text(signalKind.rawValue).tag(signalKind)
                }
            }
            .pickerStyle(.segmented)
            TextField("Match text (comma-separated)", text: $standingOrderContains)
                .textFieldStyle(.roundedBorder)
            TextField("Task HeyMate should offer", text: $standingOrderTask, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            TextField("Cooldown minutes", text: $standingOrderCooldownMinutes)
                .textFieldStyle(.roundedBorder)
            TextField("For minutes (0 = until disabled)", text: $standingOrderForMinutes)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer(minLength: 0)
                Button(editingStandingOrderID == nil ? "Save suggestion" : "Save changes") {
                    saveStandingOrderFromComposer()
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(!canSaveStandingOrder)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func standingOrderRow(_ order: StandingOrder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(order.name)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(order.enabled ? "Enabled" : "Paused")
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(order.enabled ? DS.Colors.textSecondary : DS.Colors.warningText)
            }
            standingOrderDetail("Signal", order.signalKind.rawValue)
            standingOrderDetail("Match", order.containsAny.joined(separator: ", "))
            standingOrderDetail("Task", order.task)
            standingOrderDetail("Cooldown", "\(order.cooldownMinutes) min")
            standingOrderDetail("For", standingOrderDurationText(order))
            HStack(spacing: 8) {
                Button("Edit") { beginEditingStandingOrder(order) }
                    .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                Button(order.enabled ? "Pause" : "Resume") {
                    _ = companionManager.setStandingOrderEnabled(!order.enabled, order: order)
                }
                .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                Button("Delete") { standingOrderPendingDelete = order }
                    .buttonStyle(DSDestructiveButtonStyle())
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func standingOrderDetail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func standingOrderDurationText(_ order: StandingOrder) -> String {
        order.minimumMatchMinutes == 0 ? "Until disabled" : "\(order.minimumMatchMinutes) min"
    }

    private func beginEditingStandingOrder(_ order: StandingOrder) {
        editingStandingOrderID = order.id
        standingOrderName = order.name
        standingOrderSignalKind = order.signalKind
        standingOrderContains = order.containsAny.joined(separator: ", ")
        standingOrderTask = order.task
        standingOrderCooldownMinutes = String(order.cooldownMinutes)
        standingOrderForMinutes = String(order.minimumMatchMinutes)
        isCreatingStandingOrder = true
    }

    private func saveStandingOrderFromComposer() {
        let name = standingOrderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let contains = standingOrderContains.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cooldownMinutes = standingOrderCooldownValue,
              let forMinutes = standingOrderForMinutesValue else { return }

        if let editingStandingOrderID {
            guard let order = companionManager.loadedStandingOrders.first(where: { $0.id == editingStandingOrderID }) else {
                return
            }
            let didUpdate = companionManager.updateStandingOrder(
                order,
                name: name,
                signalKind: standingOrderSignalKind,
                contains: contains,
                task: standingOrderProposalTask,
                cooldownMinutes: cooldownMinutes,
                forMinutes: forMinutes
            )
            guard didUpdate else { return }
            resetStandingOrderComposer()
            return
        }

        let didCreate = companionManager.createStandingOrder(
            name: name,
            signalKind: standingOrderSignalKind,
            contains: contains,
            task: standingOrderProposalTask,
            cooldownMinutes: cooldownMinutes,
            forMinutes: forMinutes
        )
        guard didCreate else { return }
        resetStandingOrderComposer()
    }

    private func resetStandingOrderComposer() {
        standingOrderName = ""
        standingOrderContains = ""
        standingOrderTask = ""
        standingOrderSignalKind = .clipboard
        standingOrderCooldownMinutes = "60"
        standingOrderForMinutes = "0"
        editingStandingOrderID = nil
        isCreatingStandingOrder = false
    }

    // MARK: Sections

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionLabel(title: title)
            content()
        }
    }

    // MARK: Card

    private func agentCard(_ run: AgentRun, isHighlighted: Bool) -> some View {
        let projectColor = Color(
            hue: AgentFilament.stableHue(forFolderSlug: run.workspaceURL.lastPathComponent),
            saturation: 0.64,
            brightness: 0.92
        )

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                statusGlyph(for: run.status)

                VStack(alignment: .leading, spacing: 3) {
                    Text(run.title)
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(run.executor.displayName)
                        Text("·")
                        Text(run.origin == .sandbox ? "Own folder" : "Your folder")
                        Text("·")
                        Text(run.workspaceURL.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer(minLength: 0)
                Text(statusLabel(for: run.status))
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(statusColor(for: run.status))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous).fill(statusColor(for: run.status).opacity(0.14))
                    )
            }

            // The live step. Real progress language only — no percentage.
            if !run.latestAction.isEmpty, !run.status.isTerminal {
                Text(run.latestAction)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }

            // The plan is the thing being approved, so it is shown in full
            // rather than truncated — a plan you have to expand to read is a
            // plan nobody reads.
            if !run.planText.isEmpty, run.status == .awaitingPlanApproval {
                planBlock(for: run)
            }

            if !run.summary.isEmpty,
               run.status != .awaitingPlanApproval,
               selectedRunID != run.id {
                Text(run.summary)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(selectedRunID == run.id ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !run.error.isEmpty {
                Text(run.error)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(selectedRunID == run.id ? nil : 2)
            }

            if selectedRunID == run.id {
                agentConversation(for: run, projectColor: projectColor)
            }

            if run.status == .succeeded {
                completionReceiptBlock(for: run)
            }

            actionRow(for: run)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            (isHighlighted ? DS.Colors.warning : projectColor).opacity(0.16),
                            DS.Colors.surface1
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(
                    isHighlighted ? DS.Colors.warning.opacity(0.55) : projectColor.opacity(0.24),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if selectedRunID != run.id {
                conversationText = ""
                selectedThreadSurface = .activity
            }
            selectedRunID = selectedRunID == run.id ? nil : run.id
        }
    }

    /// What the agent said it would do, before it was allowed to do anything.
    private func planBlock(for run: AgentRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSectionLabel(title: "The plan")
            Text(run.planText)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("Nothing has been written yet.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func completionReceiptBlock(for run: AgentRun) -> some View {
        let changes = run.workspaceChangeSummary
        let receipt = AgentCompletionReceipt.markdown(for: run, changes: changes)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DSSectionLabel(title: "Completion receipt")
                Spacer(minLength: 0)
                ShareLink(item: receipt) {
                    Label("Share receipt", systemImage: "square.and.arrow.up")
                        .font(DS.Fonts.caption)
                }
                .buttonStyle(DSTertiaryButtonStyle())
                .help("Share a privacy-bounded Markdown proof of this completed run")
            }

            HStack(spacing: 7) {
                receiptFact(
                    value: receiptDuration(for: run),
                    label: "elapsed",
                    systemImage: "clock"
                )
                receiptFact(
                    value: changes.map { "\($0.totalCount)" } ?? "—",
                    label: "files changed",
                    systemImage: "doc.on.doc"
                )
                receiptFact(
                    value: run.undoEntryIdentifier.isEmpty ? "No" : "Ready",
                    label: "undo",
                    systemImage: "arrow.uturn.backward.circle"
                )
            }

            if let changes, !changes.displayedChanges.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(changes.displayedChanges.prefix(4).enumerated()), id: \.offset) { _, change in
                        Text("\(receiptChangeGlyph(change.kind))  \(change.path)")
                            .font(DS.Fonts.micro.monospaced())
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if changes.totalCount > 4 {
                        Text("+ \(changes.totalCount - 4) more")
                            .font(DS.Fonts.micro)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            } else if changes == nil {
                Text("Measuring changed files…")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Text("Prompt, absolute paths, session IDs, and raw logs stay out. Review outcome above before sharing.")
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func receiptFact(value: String, label: String, systemImage: String) -> some View {
        Label {
            Text("\(value) \(label)")
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(DS.Fonts.micro)
        .foregroundColor(DS.Colors.textSecondary)
    }

    private func receiptDuration(for run: AgentRun, now: Date = Date()) -> String {
        let start = run.startedAt ?? run.createdAt
        let end = run.finishedAt ?? now
        let totalSeconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        if totalSeconds < 3_600 { return "\(totalSeconds / 60)m" }
        return "\(totalSeconds / 3_600)h \((totalSeconds % 3_600) / 60)m"
    }

    private func receiptChangeGlyph(_ kind: AgentWorkspaceChangeKind) -> String {
        switch kind {
        case .added: return "+"
        case .modified: return "~"
        case .deleted: return "−"
        }
    }

    private func agentConversation(for run: AgentRun, projectColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Thread surface", selection: $selectedThreadSurface) {
                    Label("Activity", systemImage: "waveform.path.ecg")
                        .tag(AgentThreadSurface.activity)
                    Label("Preview", systemImage: "macwindow")
                        .tag(AgentThreadSurface.preview)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)

                Spacer(minLength: 0)
                Text(
                    selectedThreadSurface == .activity
                        ? "\(run.activity.count) updates"
                        : "Interactive output"
                )
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if selectedThreadSurface == .activity {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(run.activity) { entry in
                        activityRow(entry, projectColor: projectColor)
                    }
                }
            } else {
                AgentWorkspacePreview(run: run)
            }

            if !run.queuedFollowUpInstructions.isEmpty {
                Label(
                    "\(run.queuedFollowUpInstructions.count) follow-up\(run.queuedFollowUpInstructions.count == 1 ? "" : "s") queued",
                    systemImage: "text.bubble.fill"
                )
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.info)
            }

            if companionManager.canSendAgentFollowUp(runID: run.id) {
                conversationComposer(for: run)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func activityRow(_ entry: AgentActivityEntry, projectColor: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(spacing: 0) {
                Circle()
                    .fill(activityColor(entry.kind, projectColor: projectColor))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                Rectangle()
                    .fill(projectColor.opacity(0.22))
                    .frame(width: 1, height: 22)
            }
            .frame(width: 9)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(activityLabel(entry.kind))
                        .font(DS.Fonts.statusWord)
                        .foregroundColor(activityColor(entry.kind, projectColor: projectColor))
                    Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Text(entry.text)
                    .font(DS.Fonts.body)
                    .foregroundColor(
                        entry.kind == .user || entry.kind == .agent
                            ? DS.Colors.textPrimary
                            : DS.Colors.textSecondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.bottom, 9)
        }
    }

    private func conversationComposer(for run: AgentRun) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField(conversationPlaceholder(for: run), text: $conversationText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Fonts.body)
                .lineLimit(2...5)
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface1)
                )

            HStack(spacing: 8) {
                Text(conversationDeliveryNote(for: run))
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer(minLength: 0)
                Button(conversationButtonLabel(for: run)) {
                    sendConversationMessage(to: run)
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(conversationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func sendConversationMessage(to run: AgentRun) {
        let trimmedMessage = conversationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }

        if run.status == .awaitingPlanApproval {
            companionManager.requestAgentReplan(runID: run.id, feedback: trimmedMessage)
        } else {
            companionManager.sendAgentFollowUp(runID: run.id, instruction: trimmedMessage)
        }
        conversationText = ""
    }

    private func conversationPlaceholder(for run: AgentRun) -> String {
        run.status == .awaitingPlanApproval
            ? "Say what to change in the plan"
            : "Message this job…"
    }

    private func conversationButtonLabel(for run: AgentRun) -> String {
        if run.status == .awaitingPlanApproval { return "Revise plan" }
        return run.status.isTerminal ? "Send follow-up" : "Send message"
    }

    private func conversationDeliveryNote(for run: AgentRun) -> String {
        if run.status == .awaitingPlanApproval { return "Replans now; still read-only" }
        if run.status.isTerminal { return "Continues same session with a new plan" }
        return "Status answers now; requested changes queue"
    }

    private func activityLabel(_ kind: AgentActivityEntry.Kind) -> String {
        switch kind {
        case .user: return "You"
        case .agent: return "Mate"
        case .progress: return "Work"
        case .status: return "Status"
        }
    }

    private func activityColor(_ kind: AgentActivityEntry.Kind, projectColor: Color) -> Color {
        switch kind {
        case .user: return DS.Colors.info
        case .agent: return projectColor
        case .progress: return DS.Colors.textSecondary
        case .status: return DS.Colors.textTertiary
        }
    }

    @ViewBuilder
    private func actionRow(for run: AgentRun) -> some View {
        HStack(spacing: 8) {
            Button(selectedRunID == run.id ? "Close thread" : "Open thread") {
                selectedRunID = selectedRunID == run.id ? nil : run.id
                conversationText = ""
                selectedThreadSurface = .activity
            }
            .buttonStyle(DSSecondaryButtonStyle())

            if run.status == .awaitingPlanApproval {
                Button("Approve plan") { companionManager.approveAgentPlan(runID: run.id) }
                    .buttonStyle(DSPrimaryButtonStyle())
                Button("Dismiss") { companionManager.dismissAgentPlan(runID: run.id) }
                    .buttonStyle(DSTertiaryButtonStyle())
            } else if run.status == .waitingForApproval {
                Button("Approve") { companionManager.approveAgent(runID: run.id) }
                    .buttonStyle(DSPrimaryButtonStyle())
                Button("Deny") { companionManager.denyAgent(runID: run.id) }
                    .buttonStyle(DSSecondaryButtonStyle())
            } else if !run.status.isTerminal {
                Button("Cancel") { runIDPendingCancel = run.id }
                    .buttonStyle(DSSecondaryButtonStyle())
            }

            // The session is what makes a takeover possible, and only the
            // first leg's stream reports it — a job that has not got there
            // yet has nothing to hand over, so the button stays hidden.
            if !run.sessionIdentifier.isEmpty, run.status != .cancelled {
                Button("Take over") { runPendingTerminalTakeover = run }
                    .buttonStyle(DSTertiaryButtonStyle())
                    .help("Stop HeyMate driving and continue this session yourself in Terminal")
            }

            Spacer(minLength: 0)

            if run.status.isTerminal {
                Button("Remove", role: .destructive) {
                    runIDPendingRemoval = run.id
                }
                .buttonStyle(DSTertiaryButtonStyle())
            }

            if run.status.isTerminal,
               !run.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Move folder to Trash", role: .destructive) {
                    runIDPendingFolderTrash = run.id
                }
                .buttonStyle(DSTertiaryButtonStyle())
            }

            Button {
                companionManager.revealAgentFolder(runID: run.id)
            } label: {
                Label("Open folder", systemImage: "folder")
                    .font(DS.Fonts.caption)
            }
            .buttonStyle(DSTertiaryButtonStyle())
            .help(run.workspacePath)
        }
    }

    private func statusGlyph(for status: AgentRunStatus) -> some View {
        Group {
            switch status {
            case .running, .queued, .planning:
                ProgressView().controlSize(.small)
            case .awaitingPlanApproval:
                Image(systemName: "checklist")
            case .waitingForApproval:
                Image(systemName: "hand.raised.fill")
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
            case .cancelled:
                Image(systemName: "slash.circle")
            }
        }
        .font(DS.Fonts.headline)
        .foregroundColor(statusColor(for: status))
        .frame(width: 18, height: 18)
    }

    private func statusLabel(for status: AgentRunStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .planning: return "Planning"
        case .awaitingPlanApproval: return "Read the plan"
        case .running: return "Working"
        case .waitingForApproval: return "Needs you"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }

    private func statusColor(for status: AgentRunStatus) -> Color {
        switch status {
        case .queued, .running, .planning: return DS.Colors.info
        case .awaitingPlanApproval, .waitingForApproval: return DS.Colors.warningText
        case .succeeded: return DS.Colors.success
        case .failed: return DS.Colors.destructiveText
        case .cancelled: return DS.Colors.textTertiary
        }
    }
}

private enum AgentThreadSurface: String {
    case activity
    case preview
}
