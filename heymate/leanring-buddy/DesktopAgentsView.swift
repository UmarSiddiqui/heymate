//
//  DesktopAgentsView.swift
//  leanring-buddy
//
//  Agents, with room to actually watch one work.
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
    @State private var isConfirmingUndo = false

    /// The job whose takeover is waiting on confirmation. Taking over kills
    /// the process HeyMate is driving, so it asks first.
    @State private var runPendingTerminalTakeover: AgentRun?

    /// Drives only the composer focus ring and glow — pure presentation.
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        DesktopPage(
            title: "Agents",
            subtitle: subtitleText,
            accessory: AnyView(
                Text(companionManager.selectedBrain.displayName)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
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
                    title: "No agents yet",
                    message: "Say “agent, build me a landing page”, or type a task above. HeyMate makes a folder under ~/Projects/heymate and works there — nothing outside it is touched unless you attach a folder yourself."
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
            "Restore workspace from before the last agent?",
            isPresented: $isConfirmingUndo,
            titleVisibility: .visible
        ) {
            Button("Undo last agent work", role: .destructive) {
                companionManager.undoLastAgentWork()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Current workspace is retained in Undo Ledger recovery before the previous version is restored.")
        }
        .confirmationDialog(
            "Take over this agent in Terminal?",
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
    }

    private var subtitleText: String {
        let runningCount = activeRuns.count + runsNeedingAttention.count
        if runningCount > 0 {
            return "\(runningCount) working. Talk answers now; agents do work over time."
        }
        return "Talk answers now. Agents do work over time, in their own folder."
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
                        ? "What should the agent build?"
                        : "What should the agent do in \(attachedFolderURL!.lastPathComponent)?",
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
                        .help("Back to a fresh sandbox folder")
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
        panel.message = "Pick the folder this agent may work in. Writes there will ask for your approval."
        guard panel.runModal() == .OK, let chosenURL = panel.url else { return }
        attachedFolderURL = chosenURL
    }

    // MARK: Standing Orders and Undo

    private func standingOrderProposalCard(_ proposal: StandingOrderProposal) -> some View {
        DesktopCard {
            VStack(alignment: .leading, spacing: 9) {
                Label("Standing Order", systemImage: "bell.badge")
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(DS.Colors.warningText)
                Text(proposal.title)
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(proposal.task)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("May I look into this? Approval starts a read-only plan. Work still needs separate plan approval.")
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

    private var standingOrdersAndUndoCard: some View {
        DesktopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Standing Orders")
                            .font(DS.Fonts.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("\(companionManager.loadedStandingOrders.count) Markdown rules · pre-planning off unless each file opts in")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Button(isCreatingStandingOrder ? "Close" : "New order") {
                        isCreatingStandingOrder.toggle()
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    Button("Open folder") { companionManager.revealStandingOrdersFolder() }
                        .buttonStyle(DSTertiaryButtonStyle())
                }

                if isCreatingStandingOrder {
                    standingOrderComposer
                }

                Divider().overlay(DS.Colors.borderSubtle)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Undo Ledger")
                            .font(DS.Fonts.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(companionManager.latestAgentUndoEntry?.runTitle ?? "No completed agent snapshot")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Undo last agent") { isConfirmingUndo = true }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .disabled(companionManager.latestAgentUndoEntry == nil)
                }

                if !companionManager.agentUndoErrorText.isEmpty {
                    Text(companionManager.agentUndoErrorText)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.destructiveText)
                }
            }
        }
    }

    private var standingOrderComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            HStack {
                Spacer(minLength: 0)
                Button("Save order") {
                    let didCreate = companionManager.createStandingOrder(
                        name: standingOrderName.trimmingCharacters(in: .whitespacesAndNewlines),
                        signalKind: standingOrderSignalKind,
                        contains: standingOrderContains.trimmingCharacters(in: .whitespacesAndNewlines),
                        task: standingOrderProposalTask
                    )
                    guard didCreate else { return }
                    standingOrderName = ""
                    standingOrderContains = ""
                    standingOrderTask = ""
                    isCreatingStandingOrder = false
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(
                    standingOrderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || standingOrderContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || standingOrderProposalTask.isEmpty
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
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
                        Text(run.origin == .sandbox ? "Sandbox" : "Attached")
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
            ? "Tell the agent what to change in its plan"
            : "Message this agent…"
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
        case .agent: return "Agent"
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
                Button("Cancel") { companionManager.cancelAgent(runID: run.id) }
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
