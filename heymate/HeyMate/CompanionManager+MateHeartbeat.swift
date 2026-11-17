//
//  CompanionManager+MateHeartbeat.swift
//  HeyMate
//
//  Runs mate heartbeats on the routine scheduler's tick: picks the one mate
//  that is due and idle, runs one read-only turn in a hidden session (never
//  its visible chat), and files what it proposes in the Inbox. Approve sends
//  the stored prompt as a normal turn in that mate's chat, where approvals
//  and the approval floor apply as usual. The decisions themselves live in
//  MateHeartbeat.swift.
//

import AppKit
import Combine
import EventKit
import Foundation

@MainActor
final class MateHeartbeatStore: ObservableObject {
    static let shared = MateHeartbeatStore()

    @Published private(set) var state = MateHeartbeatState()
    /// The mate whose heartbeat is running now. At most one across mates.
    @Published fileprivate(set) var runningMateID: UUID?
    private let fileURL: URL

    init(fileURL: URL = HeyMateDataDirectory.url.appendingPathComponent("mate-heartbeats.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(MateHeartbeatState.self, from: data) {
            state = decoded
        }
    }

    func mate(_ id: UUID) -> MateHeartbeatMateState { state.mates[id] ?? MateHeartbeatMateState() }

    func update(_ id: UUID, _ change: (inout MateHeartbeatMateState) -> Void) {
        var entry = mate(id)
        change(&entry)
        state.mates[id] = entry
        save()
    }

    func setGlobalEnabled(_ enabled: Bool) {
        state.globalEnabled = enabled
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension CompanionManager: MateHeartbeatTicking {
    private static let heartbeatTurnLimit: Duration = .seconds(150)
    private static let mailBundleID = "com.apple.mail"
    private static let calendarBundleID = "com.apple.iCal"
    private static var heartbeatClients: [UUID: MateAgentServeConversationClient] = [:]
    private static let heartbeatNotifier = AgentUserNotifier()

    var heartbeatStore: MateHeartbeatStore { MateHeartbeatStore.shared }

    // MARK: Settings

    func isHeartbeatEnabled(for mate: Mate) -> Bool {
        MateHeartbeatEligibility.isEnabled(
            globalEnabled: heartbeatStore.state.globalEnabled,
            override: heartbeatStore.mate(mate.id).enabledOverride,
            archived: mate.archived,
            conductsOthers: mate.conductsOthers,
            hasFolder: mate.folderPath != nil,
            hasConnectedApp: !heartbeatConnectedApps(for: mate).isEmpty
        )
    }

    func setHeartbeatEnabled(_ enabled: Bool, mateID: UUID) {
        heartbeatStore.update(mateID) { $0.enabledOverride = enabled }
        mateRoutineScheduler.schedulesChanged()
    }

    func setHeartbeatsEnabledGlobally(_ enabled: Bool) {
        heartbeatStore.setGlobalEnabled(enabled)
        mateRoutineScheduler.schedulesChanged()
    }

    private func heartbeatConnectedApps(for mate: Mate) -> [String] {
        let composio = composioConnections.connectedSlugs.filter {
            isConnectorSelectionEnabled(Self.chatConnectorSelectionID(forComposioSlug: $0), for: mate)
        }
        let mac = ["apple-calendar", "apple-mail"].filter { heartbeatMacAppConnected($0, for: mate) }
        return composio.sorted() + mac
    }

    private func heartbeatMacAppConnected(_ connectorID: String, for mate: Mate) -> Bool {
        connectorStore.connectionState(for: connectorID).isConnected
            && isConnectorSelectionEnabled(Self.chatConnectorSelectionID(forConnectorID: connectorID), for: mate)
    }

    // MARK: Tick

    var wantsHeartbeatTicks: Bool {
        !HeyMateDataDirectory.isUnitTestHost && heartbeatStore.state.globalEnabled
            && mates.contains { isHeartbeatEnabled(for: $0) }
    }

    func heartbeatTick(now: Date, networkUsable: Bool) {
        expireMateProposals(now: now)
        guard heartbeatStore.runningMateID == nil, networkUsable else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let active = idle < MateHeartbeatSchedule.idleLimit
        for mate in mates where isHeartbeatEnabled(for: mate) {
            let entry = heartbeatStore.mate(mate.id)
            let settings = mateAgentSettings.settings(for: mate.id)
            guard MateHeartbeatSchedule.isDue(now: now, lastRunAt: entry.lastRunAt,
                                              backedOff: MateHeartbeatFatigue.isBackedOff(entry.records),
                                              userActive: active, calendar: .current,
                                              quietHours: settings.quietHours,
                                              runsToday: mateAgentSettings.today(for: mate.id).heartbeats,
                                              maxPerDay: settings.limits.effectiveHeartbeatsPerDay),
                  !isMateBusyForHeartbeat(mate.id) else { continue }
            startHeartbeat(for: mate, now: now)
            return
        }
    }

    /// "Check now" in settings. Nil when it started, else why not.
    func runMateHeartbeatNow(mateID: UUID) -> String? {
        guard let mate = mates.first(where: { $0.id == mateID && !$0.archived }) else { return "This agent is archived." }
        if heartbeatStore.runningMateID != nil { return "Another check-in is running. Try again in a minute." }
        if isMateBusyForHeartbeat(mateID) { return "\(mate.name) is busy. Try again when it finishes." }
        startHeartbeat(for: mate, now: Date())
        return nil
    }

    /// Never while that mate has a turn, job or approval in flight.
    func isMateBusyForHeartbeat(_ mateID: UUID) -> Bool {
        if mateInbox.work.contains(where: { $0.mateID == mateID && $0.state == .running }) { return true }
        if isChatTurnBusy, (currentChat.mateID ?? mateDirectory.defaultMateID) == mateID || liveStateOwnerMateID == mateID {
            return true
        }
        if activeRoutineTurn?.mateID == mateID || activeHandoffMateID == mateID { return true }
        return agentRuns.contains { !$0.status.isTerminal && $0.chatOwner?.mateID == mateID }
    }

    // MARK: The turn

    private func startHeartbeat(for mate: Mate, now: Date) {
        heartbeatStore.runningMateID = mate.id
        heartbeatStore.update(mate.id) {
            $0.lastRunAt = now
            $0.runCount += 1
            $0.lastStatus = "Checking in"
        }
        recordMateActivity(.heartbeats, mateID: mate.id)
        var inputs = heartbeatInputs(for: mate, now: now)
        let readsCalendar = heartbeatMacAppConnected("apple-calendar", for: mate)
            && MateHeartbeatContext.allowsSource(bundleID: Self.calendarBundleID, excluded: excludedAppBundleIds)
        // Mail is asked only while it is already open: a question would launch it.
        let readsMail = heartbeatMacAppConnected("apple-mail", for: mate)
            && MateHeartbeatContext.allowsSource(bundleID: Self.mailBundleID, excluded: excludedAppBundleIds)
            && !NSRunningApplication.runningApplications(withBundleIdentifier: Self.mailBundleID).isEmpty
        HeyMateLog.log("💓 Heartbeat for \(mate.name) started")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.heartbeatStore.runningMateID = nil }
            let accounts = await Task.detached(priority: .utility) {
                (readsCalendar ? CompanionManager.todayEventTitles(now: now) : nil, readsMail ? CompanionManager.unreadMailLines() : nil)
            }.value
            inputs.calendarToday = accounts.0
            inputs.unreadMail = accounts.1
            let status: String
            do {
                let reply = try await self.runHeartbeatTurn(for: mate, context: MateHeartbeatContext.render(inputs))
                if let drafts = MateHeartbeatParser.parse(reply) {
                    let filed = self.fileProposals(drafts, for: mate, now: Date())
                    status = filed == 0 ? "Nothing worth proposing" : (filed == 1 ? "Proposed 1 thing" : "Proposed \(filed) things")
                } else {
                    HeyMateLog.log("💓 Heartbeat for \(mate.name) returned malformed output; dropped")
                    status = "Nothing worth proposing"
                }
            } catch {
                HeyMateLog.log("💓 Heartbeat for \(mate.name) failed: \(error.localizedDescription)")
                status = "Couldn't check in: \(MateHeartbeatText.oneLine(error.localizedDescription, limit: 120))"
            }
            self.heartbeatStore.update(mate.id) { $0.lastStatus = status }
            self.mateRoutineScheduler.schedulesChanged()
        }
    }

    private func runHeartbeatTurn(for mate: Mate, context: String) async throws -> String {
        if !usesConversationClientOverride { await awaitConnectorActivation() }
        let chatID = heartbeatStore.mate(mate.id).sessionChatID
        let client = Self.heartbeatClients[chatID] ?? MateAgentServeConversationClient(chatID: chatID)
        Self.heartbeatClients[chatID] = client
        client.preferredBrain = resolvedSessionBrain(forMateID: mate.id)
        client.enabledSkillNames = []
        client.connectorScope = nil
        client.workID = UUID()
        client.isWorkContinuation = false
        client.heartbeatReadRoot = .some(mate.folderPath)
        client.streamsReplyLive = false
        client.verifyReply = nil
        client.onOpener = nil
        client.onDrawingText = nil
        client.onProgress = nil
        client.seedMessages = []
        // Nothing in a heartbeat may ask the person anything; any request is declined.
        client.onTurnRequest = { _ in nil }
        let system = MateHeartbeatPrompt.system(mateName: mate.name, job: mate.job, soul: mate.soul)
        let prompt = MateHeartbeatPrompt.turn(context: context)
        let turn = Task { @MainActor in
            try await client.analyzeImageStreaming(images: [], systemPrompt: system, conversationHistory: [],
                                                   userPrompt: prompt, onTextChunk: { _ in })
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: Self.heartbeatTurnLimit)
            turn.cancel()
        }
        defer {
            watchdog.cancel()
            client.onTurnRequest = nil
        }
        let (text, _) = try await turn.value
        if let delivery = client.latestDelivery { try? client.acknowledgeDelivery(delivery.id) }
        return text
    }

    // MARK: Context

    private func heartbeatInputs(for mate: Mate, now: Date) -> MateHeartbeatContext.Inputs {
        let entry = heartbeatStore.mate(mate.id)
        let memory = mate.folderPath.flatMap {
            try? String(contentsOf: URL(fileURLWithPath: $0).appendingPathComponent("AGENTS.md"), encoding: .utf8)
        }
        let work = mateInbox.work.filter { $0.mateID == mate.id }
        let jobs = MateJobs.runs(for: mate, in: agentRuns, owners: mateRunOwners).filter { !$0.status.isTerminal }
        let failedSince = now.addingTimeInterval(-3 * 24 * 3600)
        let unreadSince = now.addingTimeInterval(-2 * 24 * 3600)
        return MateHeartbeatContext.Inputs(
            mateName: mate.name,
            job: mate.job,
            soul: mate.soul,
            memory: memory,
            folderPath: mate.folderPath,
            folder: MateHeartbeatContext.folderEntries(at: mate.folderPath),
            unfinishedJobs: work.filter { $0.state == .running || $0.state == .needsInput }.map(\.title) + jobs.map(\.title),
            failedJobs: work.filter { ($0.state == .failed || $0.state == .stopped) && $0.updatedAt > failedSince }
                .map { [$0.title, $0.result].compactMap { $0 }.joined(separator: ": ") },
            unansweredItems: mateInbox.pendingItems(forMate: mate.id).compactMap { item in
                switch item.kind {
                case .question(let prompt, _, _): prompt
                case .signIn(let site, _, _, _): "Sign in to \(site)"
                case .routineFailed(_, let summary): "Routine failed: \(summary)"
                case .appliedChange, .proposal: nil
                }
            },
            unreadRoutineResults: mate.unreadCount > 0 ? routines.filter {
                $0.mateID == mate.id && ($0.lastRunAt ?? .distantPast) > unreadSince
            }.map { "\($0.task): \($0.lastStatusMessage ?? "finished")" } : [],
            recentResults: work.filter { $0.state == .resultReady && $0.updatedAt > failedSince }
                .sorted { $0.updatedAt > $1.updatedAt }
                .compactMap { item in item.result.map { "\(item.title): \($0)" } },
            recentProposals: entry.records,
            doNotPropose: MateHeartbeatFatigue.suppressedTitles(entry.records, now: now),
            now: now
        )
    }

    /// Today's remaining event titles, nothing else.
    nonisolated private static func todayEventTitles(now: Date) -> [String]? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
        let store = EKEventStore()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .prefix(MateHeartbeatContext.listLimit)
            .map { ($0.isAllDay ? "All day" : formatter.string(from: $0.startDate)) + " · " + ($0.title?.isEmpty == false ? $0.title! : "Untitled") }
    }

    /// Sender and subject of unread messages only. Bodies stay in Mail.
    nonisolated private static func unreadMailLines() -> [String]? {
        guard let output = MacAccountContext.mailRawOutput() else { return nil }
        return MateWakeMail.rows(rawOutput: output).filter(\.unread).prefix(MateHeartbeatContext.listLimit).map(\.summary)
    }

    // MARK: Proposals

    private func fileProposals(_ drafts: [MateHeartbeatParser.Draft], for mate: Mate, now: Date) -> Int {
        let entry = heartbeatStore.mate(mate.id)
        let open = mateInbox.pendingItems(forMate: mate.id)
        let openProposals = open.compactMap(\.proposal).map(\.title)
        let busy = open.compactMap { item -> String? in
            if case .question(let prompt, _, _) = item.kind { return prompt }
            return nil
        } + mateInbox.work.filter { $0.mateID == mate.id && ($0.state == .running || $0.state == .needsInput) }.map(\.title)
            + MateJobs.runs(for: mate, in: agentRuns, owners: mateRunOwners).filter { !$0.status.isTerminal }.map(\.title)
        let kept = MateHeartbeatDedupe.filter(drafts,
            blockedTitles: MateHeartbeatFatigue.suppressedTitles(entry.records, now: now) + openProposals, busyTexts: busy)
        guard !kept.isEmpty else { return 0 }
        for draft in kept {
            let proposal = MateHeartbeatProposal(id: UUID(), title: draft.title, whyNow: draft.whyNow, prompt: draft.prompt,
                needsApproval: draft.needsApproval, createdAt: now, expiresAt: now.addingTimeInterval(MateHeartbeatProposal.lifetime))
            mateInbox.record(MateInboxItem(id: proposal.id, mateID: mate.id, mateName: mate.name, chatID: entry.sessionChatID,
                createdAt: now, resolvedAt: nil, resolutionSummary: nil, kind: .proposal(proposal),
                resumeTaskContext: nil, workID: nil))
            heartbeatStore.update(mate.id) {
                $0.append(MateHeartbeatRecord(id: proposal.id, title: proposal.title, createdAt: now, outcome: .open))
            }
        }
        Self.heartbeatNotifier.notifyProposals(mateID: mate.id, mateName: mate.name, firstTitle: kept[0].title, count: kept.count)
        return kept.count
    }

    /// Approve, Skip or Adjust one proposal. False when it could not be done.
    @discardableResult
    func actOnMateProposal(id: UUID, action: MateHeartbeatAction) -> Bool {
        guard let item = mateInbox.pendingItems.first(where: { $0.id == id }), let proposal = item.proposal,
              mates.contains(where: { $0.id == item.mateID && !$0.archived }) else { return false }
        let outcome: MateHeartbeatRecord.Outcome
        switch action {
        case .approve:
            let chatID = mateChatForInboxAction(mateID: item.mateID)
            guard resumeMateChatInBackground(mateID: item.mateID, chatID: chatID,
                                             userMessage: proposal.prompt, modelPrompt: proposal.prompt) else { return false }
            outcome = .approved
        case .adjust:
            openMate(id: item.mateID)
            let existing = (currentChat.draftText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            updateCurrentDraft(existing.isEmpty ? proposal.prompt : "\(existing)\n\(proposal.prompt)")
            openDesktopWindow(section: .chat)
            outcome = .adjusted
        case .skip:
            outcome = .skipped
        }
        _ = mateInbox.resolve(id: id, summary: action.rawValue.capitalized)
        heartbeatStore.update(item.mateID) { $0.resolve(id, outcome, now: Date()) }
        return true
    }

    /// Proposals live a day. Expired ones leave the Inbox and count toward fatigue.
    func expireMateProposals(now: Date) {
        for item in mateInbox.items where item.resolvedAt == nil {
            guard let proposal = item.proposal, proposal.isExpired(now: now) else { continue }
            _ = mateInbox.resolve(id: item.id, summary: "Expired", now: now)
            heartbeatStore.update(item.mateID) { $0.resolve(item.id, .expired, now: now) }
        }
    }
}
