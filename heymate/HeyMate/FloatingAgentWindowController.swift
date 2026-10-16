import AppKit
import Combine
import SwiftUI

/// Presentation only. Jobs and approvals remain owned by the existing runtime.
@MainActor
final class FloatingAgentWindowController {
    private weak var manager: CompanionManager?
    private var subscriptions = Set<AnyCancellable>()
    private var panels: [String: NSPanel] = [:]
    private var expandedPanelIDs = Set<String>()
    private var yielded = false
    private var lastQuietState: Bool?
    private let noticeStore = FloatingAgentNoticeStore()
    private var reportWindow: NSWindow?
    private var reportNotice: FloatingAgentNotice?

    func start(manager: CompanionManager) {
        stop()
        self.manager = manager
        noticeStore.start(runs: manager.agentRuns)
        manager.$agentRuns.removeDuplicates().sink { [weak self] runs in
            self?.noticeStore.observe(runs: runs)
            // Published emits before assignment. Read the new value on the next turn.
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &subscriptions)
        manager.$mates.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &subscriptions)
        for notification in [UserDefaults.didChangeNotification, NSApplication.didChangeScreenParametersNotification] {
            NotificationCenter.default.publisher(for: notification).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        }
        Timer.publish(every: 5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let quiet = QuietPolicy.shouldSilenceAnnouncements()
                guard quiet != self.lastQuietState else { return }
                self.lastQuietState = quiet
                self.refresh()
            }.store(in: &subscriptions)
        refresh()
    }

    func dismissNotice(id: UUID) {
        noticeStore.dismiss(id: id)
        refresh()
    }

    func setYielded(_ value: Bool) { yielded = value; refresh() }

    func stop() {
        subscriptions.removeAll()
        panels.values.forEach { $0.orderOut(nil); $0.contentView = nil }
        panels.removeAll()
        expandedPanelIDs.removeAll()
        reportWindow?.close()
        reportWindow = nil
        reportNotice = nil
        noticeStore.stop()
        manager = nil
    }

    private static func makePanel() -> NSPanel {
        let panel = FloatingAgentPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        // Every Space, but not over full-screen apps: a movie or a slide
        // deck shouldn't carry job bubbles. The notch still says "needs you".
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        return panel
    }

    #if DEBUG
    /// Native presentation fixture using the same panel and hosting classes as live cards.
    /// No manager, provider, approval or job is started.
    static func previewPanel<Content: View>(content: Content, on screen: NSScreen) -> NSPanel {
        let panel = makePanel()
        panel.title = "HeyMate Floating Card Preview"
        let frame = FloatingAgentPresentation.frame(visibleFrame: screen.visibleFrame, height: 108)
        let hosting = FloatingAgentHostingView(rootView: AnyView(content))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return panel
    }
    #endif

    private func refresh() {
        guard let manager else { return }
        if let reportNotice {
            if let run = manager.agentRuns.first(where: { reportNotice.matches($0) }),
               let mate = manager.mates.first(where: { $0.id == reportNotice.mateID }) {
                reportWindow?.contentView = NSHostingView(rootView: FloatingAgentReportView(run: run, mateName: mate.name, manager: manager))
            } else {
                reportWindow?.close()
                reportWindow = nil
                self.reportNotice = nil
            }
        }
        let runs = FloatingAgentPresentation.activeRuns(manager.agentRuns.filter {
            FloatingAgentPresentation.owner(for: $0, mates: manager.mates) != nil
        }, limit: nil)
        let updates = noticeStore.notices.compactMap { notice -> FloatingAgentNoticeItem? in
            guard let run = manager.agentRuns.first(where: { notice.matches($0) }),
                  let mate = manager.mates.first(where: { $0.id == notice.mateID && !$0.archived }) else { return nil }
            return FloatingAgentNoticeItem(notice: notice, run: run, mateName: mate.name)
        }
        let visibleNotices = updates.map(\.notice)
        if manager.taskNotices != visibleNotices { manager.taskNotices = visibleNotices }
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: CompanionAppearancePreference.floatingAgentsKey) == nil
            || defaults.bool(forKey: CompanionAppearancePreference.floatingAgentsKey)
        guard enabled, !yielded, !QuietPolicy.shouldSilenceAnnouncements(), !runs.isEmpty || !updates.isEmpty else {
            panels.values.forEach { $0.orderOut(nil); $0.contentView = nil }
            panels.removeAll()
            expandedPanelIDs.removeAll()
            return
        }
        // Each bubble owns a compact native panel. No invisible wide stack
        // intercepts the desktop while the pointer is outside a bubble.
        let rows = FloatingAgentPresentation.rows(runs: runs, updates: updates)
        var liveIDs = Set<String>()
        for (screenIndex, screen) in NSScreen.screens.enumerated() {
            let capacity = max(1, Int((screen.visibleFrame.height - 56) / 84))
            for (rowIndex, row) in rows.prefix(capacity).enumerated() {
                let id = "\(screenIndex):\(row.id)"
                liveIDs.insert(id)
                let panel: NSPanel
                if let current = panels[id] { panel = current }
                else {
                    panel = Self.makePanel()
                    AppPresencePreferences.shared.registerAmbientWindow(panel)
                    panels[id] = panel
                }
                let run: AgentRun
                switch row {
                case .agent(let active): run = active
                case .update(let update): run = update.run
                }
                guard let mate = FloatingAgentPresentation.owner(for: run, mates: manager.mates) else { continue }
                let view = FloatingAgentBubble(row: row, mate: mate, onOpen: {
                    let stored = run.chatOwner.flatMap { manager.chatHistoryStore.session(id: $0.chatID) }
                    if let chatID = FloatingAgentPresentation.ownedChatID(
                        for: run, mate: mate, currentChat: manager.currentChat, storedChat: stored,
                        defaultMateID: manager.mateDirectory.defaultMateID
                    ) {
                        manager.openChat(id: chatID)
                    } else if manager.activeMateID != mate.id {
                        manager.openMate(id: mate.id)
                    }
                    manager.openDesktopWindow(section: .chat)
                }, onReport: { [weak self] in self?.showReport($0) }, onDismiss: { [weak self] update in
                    self?.noticeStore.dismiss(id: update.id)
                    self?.refresh()
                }, onExpansion: { [weak self, weak panel] expanded in
                    guard let self, let panel, self.panels[id] === panel else { return }
                    if expanded { self.expandedPanelIDs.insert(id) }
                    else { self.expandedPanelIDs.remove(id) }
                    let frame = FloatingAgentPresentation.bubbleFrame(
                        visibleFrame: screen.visibleFrame, index: rowIndex, expanded: expanded)
                    panel.setFrame(frame, display: true)
                })
                let hosting: FloatingAgentHostingView
                if let current = panel.contentView as? FloatingAgentHostingView {
                    current.rootView = AnyView(view)
                    hosting = current
                } else { hosting = FloatingAgentHostingView(rootView: AnyView(view)) }
                let frame = FloatingAgentPresentation.bubbleFrame(
                    visibleFrame: screen.visibleFrame, index: rowIndex, expanded: expandedPanelIDs.contains(id))
                hosting.sizingOptions = []
                hosting.frame = CGRect(origin: .zero, size: frame.size)
                hosting.autoresizingMask = [.width, .height]
                panel.contentView = hosting
                panel.setFrame(frame, display: true)
                if !panel.isVisible { panel.orderFrontRegardless() }
            }
        }
        for id in Set(panels.keys).subtracting(liveIDs) {
            if let panel = panels.removeValue(forKey: id) { panel.orderOut(nil); panel.contentView = nil }
            expandedPanelIDs.remove(id)
        }
    }

    private func showReport(_ update: FloatingAgentNoticeItem) {
        guard let manager, noticeStore.notices.contains(where: { $0.id == update.id }),
              let run = manager.agentRuns.first(where: { update.notice.matches($0) }) else { return }
        let window = reportWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Task report"
        window.contentMinSize = NSSize(width: 440, height: 320)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FloatingAgentReportView(run: run, mateName: update.mateName, manager: manager))
        if reportWindow == nil {
            window.center()
            AppPresencePreferences.shared.registerAmbientWindow(window)
        }
        reportWindow = window
        reportNotice = update.notice
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// Not generic on purpose: Xcode 26.6's optimizer (Swift 6.3.3) crashes
/// compiling the deinit of a private generic NSHostingView subclass in
/// Release builds.
private final class FloatingAgentHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FloatingAgentPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

nonisolated enum FloatingAgentPresentation {
    enum Row: Identifiable {
        case agent(AgentRun), update(FloatingAgentNoticeItem)
        var id: String {
            switch self {
            case .agent(let run): return "run:\(run.id)"
            case .update(let update): return "update:\(update.id)"
            }
        }
    }

    static func rows(runs: [AgentRun], updates: [FloatingAgentNoticeItem]) -> [Row] {
        let active = activeRuns(runs, limit: nil)
        return active.filter { $0.status.needsUser }.map(Row.agent)
            + updates.map(Row.update)
            + active.filter { !$0.status.needsUser }.map(Row.agent)
    }
    static func statusLabel(_ status: AgentRunStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .planning: return "Planning"
        case .awaitingPlanApproval: return "Review plan"
        case .waitingForApproval: return "Needs you"
        case .running: return "Working"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }

    static func owner(for run: AgentRun, mates: [Mate]) -> Mate? {
        if let owner = run.chatOwner {
            return mates.first { $0.id == owner.mateID }
        }
        return mates.first { mate in
            guard let folder = mate.folderPath else { return false }
            return URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.path
                == run.workspaceURL.standardizedFileURL.path
        }
    }

    static func activeRuns(_ runs: [AgentRun], limit: Int? = 3) -> [AgentRun] {
        let sorted = runs.filter { !$0.status.isTerminal }.sorted {
            if $0.status.needsUser != $1.status.needsUser { return $0.status.needsUser }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return limit.map { Array(sorted.prefix(max(0, $0))) } ?? sorted
    }

    static func ownedChatID(for run: AgentRun, mate: Mate, currentChat: ChatSession,
                            storedChat: ChatSession?, defaultMateID: UUID) -> UUID? {
        guard let owner = run.chatOwner, owner.mateID == mate.id else { return nil }
        guard let chat = currentChat.id == owner.chatID ? currentChat : storedChat,
              chat.id == owner.chatID, (chat.mateID ?? defaultMateID) == mate.id else { return nil }
        return chat.id
    }

    /// Expansion keeps the avatar center fixed so the pointer never loses it.
    static func bubbleFrame(visibleFrame: CGRect, index: Int, expanded: Bool) -> CGRect {
        let width = min(expanded ? 324.0 : 56.0, max(0, visibleFrame.width - 24))
        let height = expanded ? 108.0 : 56.0
        let centerY = visibleFrame.maxY - 70 - CGFloat(index) * 84
        return CGRect(x: visibleFrame.maxX - width - 12, y: centerY - height / 2,
                      width: width, height: height)
    }

    static func stackHeight(runCount: Int) -> CGFloat {
        max(0, CGFloat(min(max(0, runCount), 3)) * 116 - 8)
    }

    static func frame(visibleFrame: CGRect, height: CGFloat) -> CGRect {
        let width = min(312, max(0, visibleFrame.width - 24))
        let height = min(height, max(0, visibleFrame.height - 32))
        return CGRect(x: visibleFrame.maxX - width - 12, y: visibleFrame.maxY - height - 16,
                      width: width, height: height)
    }
}

struct FloatingAgentStack: View {
    let runs: [AgentRun]
    let mates: [Mate]
    let onOpen: (AgentRun, Mate) -> Void
    var updates: [FloatingAgentNoticeItem] = []
    var onReport: (FloatingAgentNoticeItem) -> Void = { _ in }
    var onDismiss: (FloatingAgentNoticeItem) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(FloatingAgentPresentation.rows(runs: runs, updates: updates)) { row in
                let run = run(for: row)
                if let mate = FloatingAgentPresentation.owner(for: run, mates: mates) {
                    FloatingAgentBubble(row: row, mate: mate, onOpen: { onOpen(run, mate) },
                                        onReport: onReport, onDismiss: onDismiss)
                        .frame(height: 108)
                }
            }
        }
    }

    private func run(for row: FloatingAgentPresentation.Row) -> AgentRun {
        switch row {
        case .agent(let run): return run
        case .update(let update): return update.run
        }
    }
}

/// Avatar stays mounted while details appear to its left. The delayed exit
/// lets the pointer cross into report/dismiss actions without hover flicker.
struct FloatingAgentBubble: View {
    let row: FloatingAgentPresentation.Row
    let mate: Mate
    let onOpen: () -> Void
    let onReport: (FloatingAgentNoticeItem) -> Void
    let onDismiss: (FloatingAgentNoticeItem) -> Void
    var onExpansion: (Bool) -> Void = { _ in }
    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?
    @Environment(\.companionSnapshotRendering) private var snapshotRendering

    private var run: AgentRun {
        switch row {
        case .agent(let run): return run
        case .update(let update): return update.run
        }
    }
    private var tint: Color {
        run.status.needsUser || run.status == .failed ? DS.Colors.warningText : DS.Colors.accent
    }
    private var label: String {
        switch row {
        case .agent: return FloatingAgentPresentation.statusLabel(run.status)
        case .update: return ChatTaskPresentation.noticeTitle(run.status)
        }
    }
    private func open() {
        if case .update(let update) = row { onReport(update) }
        else { onOpen() }
    }

    var body: some View {
        HStack(spacing: 12) {
            if expanded || snapshotRendering {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(label).font(DS.Fonts.caption.weight(.semibold)).foregroundStyle(tint)
                        Spacer(minLength: 0)
                        if case .update(let update) = row {
                            Button { onDismiss(update) } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                                    .frame(width: 24, height: 24).contentShape(Rectangle())
                            }.accessibilityLabel("Dismiss update for \(run.title)")
                        }
                    }
                    Text(run.title).font(DS.Fonts.body.weight(.medium)).lineLimit(1)
                    Button(action: open) {
                        Text(run.status.isTerminal ? "Open task report" :
                             run.status.needsUser ? "Open to review and approve" : "Open mate chat")
                            .font(DS.Fonts.caption).lineLimit(1)
                    }.buttonStyle(NotchCapsuleControlStyle(height: 24))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: open) {
                MateFaceView(mate: mate, size: 36, expression: .agent(run))
                    .frame(width: 40, height: 40)
                    .background(Color.black, in: Circle())
                    .overlay(Circle().stroke(tint, lineWidth: 2))
                    .overlay { CueProp(kind: .ring, subject: run.id.uuidString) }
                    .cueMotion(.jobDone, .surprised, subject: run.id.uuidString, anchor: .bottom)
                    .overlay(alignment: .bottomTrailing) {
                        if run.status.needsUser || run.status.isTerminal {
                            Image(systemName: run.status.needsUser ? "hand.raised.fill" :
                                  run.status == .failed ? "exclamationmark" : run.status == .cancelled ? "stop.fill" : "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(DS.Colors.surface1)
                                .frame(width: 18, height: 18).background(tint, in: Circle())
                        }
                    }
            }
            .help("\(mate.name): \(label). \(run.title)")
            .accessibilityLabel("\(mate.name), \(label), \(run.title)")
        }
        .padding(.leading, expanded || snapshotRendering ? 16 : 8)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(DS.Colors.textPrimary)
        .background {
            if expanded || snapshotRendering {
                RoundedRectangle(cornerRadius: 22).fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(tint.opacity(0.35), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { inside in
            collapseTask?.cancel()
            if inside {
                expanded = true
                onExpansion(true)
            } else {
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(160))
                    guard !Task.isCancelled else { return }
                    expanded = false
                    onExpansion(false)
                }
            }
        }
        .onDisappear { collapseTask?.cancel() }
        .cueMotion(.surprised, part: .prop, subject: run.id.uuidString)
    }
}


struct FloatingAgentCard: View {
    let run: AgentRun
    let mate: Mate?
    let onOpen: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionSnapshotRendering) private var snapshotRendering
    @State private var appeared = false
    @State private var hovering = false

    /// Working cards breathe a little; hovering holds them still to click.
    private var bobs: Bool { run.status == .running && !hovering && !reduceMotion && !snapshotRendering }
    private var shown: Bool { appeared || snapshotRendering }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !bobs)) { context in
            card.offset(y: bobs ? FloatingAgentMotion.bob(at: context.date.timeIntervalSinceReferenceDate) : 0)
        }
        .offset(x: shown || reduceMotion ? 0 : FloatingAgentMotion.settleDistance)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.16) : FloatingAgentMotion.settle) { appeared = true }
        }
        .onHover { hovering = $0 }
    }

    private var card: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                if let mate {
                    MateFaceView(mate: mate, size: 38, expression: .agent(run))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(FloatingAgentPresentation.statusLabel(run.status))
                            .font(DS.Fonts.caption.weight(.semibold))
                            .foregroundStyle(run.status.needsUser ? DS.Colors.warningText : DS.Colors.textSecondary)
                        Spacer(minLength: 2)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    Text(run.title).font(DS.Fonts.body.weight(.medium)).lineLimit(1)
                    Text(run.status.needsUser ? "Open to review and approve" : "Open mate chat")
                        .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary).lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(run.status.needsUser ? DS.Colors.warning.opacity(0.6) : DS.Colors.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(FloatingCardPressStyle())
        .accessibilityLabel("\(run.title), \(FloatingAgentPresentation.statusLabel(run.status)). Open mate chat")
    }
}

nonisolated enum FloatingAgentMotion {
    /// A new card slides in from the screen edge and settles.
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let settleDistance: CGFloat = 28
    /// 1.2 pt up and down every 2.5 s.
    static func bob(at time: TimeInterval) -> CGFloat {
        CGFloat(sin(time * 2 * .pi / 2.5) * 1.2)
    }
}

/// A quick press-in and release, so a click feels landed.
private struct FloatingCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(.easeOut(duration: configuration.isPressed ? 0.14 : 0.16), value: configuration.isPressed)
    }
}
