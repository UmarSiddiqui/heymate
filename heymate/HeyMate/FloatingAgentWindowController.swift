import AppKit
import Combine
import SwiftUI

/// Presentation only. Jobs and approvals remain owned by the existing runtime.
@MainActor
final class FloatingAgentWindowController {
    private weak var manager: CompanionManager?
    private var subscriptions = Set<AnyCancellable>()
    private var panels: [NSPanel] = []
    private var yielded = false
    private var collapsed = false
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
        refresh()
    }

    func setYielded(_ value: Bool) { yielded = value; refresh() }

    func stop() {
        subscriptions.removeAll()
        panels.forEach { $0.orderOut(nil); $0.contentView = nil }
        panels.removeAll()
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
        if let reportNotice, !manager.agentRuns.contains(where: { reportNotice.matches($0) }) {
            reportWindow?.close()
            reportWindow = nil
            self.reportNotice = nil
        }
        let runs = FloatingAgentPresentation.activeRuns(manager.agentRuns.filter {
            FloatingAgentPresentation.owner(for: $0, mates: manager.mates) != nil
        }, limit: nil)
        let updates = noticeStore.notices.compactMap { notice -> FloatingAgentNoticeItem? in
            guard let run = manager.agentRuns.first(where: { notice.matches($0) }),
                  let mate = manager.mates.first(where: { $0.id == notice.mateID && !$0.archived }) else { return nil }
            return FloatingAgentNoticeItem(notice: notice, run: run, mateName: mate.name)
        }
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: CompanionAppearancePreference.floatingAgentsKey) == nil
            || defaults.bool(forKey: CompanionAppearancePreference.floatingAgentsKey)
        guard enabled, !yielded, !runs.isEmpty || !updates.isEmpty else {
            panels.forEach { $0.orderOut(nil); $0.contentView = nil }
            panels.removeAll()
            return
        }
        // Reuse panels while progress changes, so updates never steal focus.
        while panels.count > NSScreen.screens.count {
            let panel = panels.removeLast(); panel.orderOut(nil); panel.contentView = nil
        }
        for (index, screen) in NSScreen.screens.enumerated() {
            let panel: NSPanel
            if index < panels.count { panel = panels[index] }
            else {
                panel = Self.makePanel()
                AppPresencePreferences.shared.registerAmbientWindow(panel)
                panels.append(panel)
            }
            let view = FloatingAgentStack(runs: runs, mates: manager.mates, collapsed: collapsed,
                                         onToggle: { [weak self] in
                guard let self else { return }
                self.collapsed.toggle()
                self.refresh()
            }, onHome: { manager.openDesktopWindow(section: .chat) }, onOpen: { run, mate in
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
            }, updates: updates, onReport: { [weak self] in self?.showReport($0) },
               onDismiss: { [weak self] update in
                self?.noticeStore.dismiss(id: update.id)
                self?.refresh()
            })
            let hosting: FloatingAgentHostingView
            if let current = panel.contentView as? FloatingAgentHostingView {
                current.rootView = AnyView(view)
                hosting = current
            } else { hosting = FloatingAgentHostingView(rootView: AnyView(view)) }
            let height = FloatingAgentPresentation.stackHeight(runCount: runs.count + updates.count, collapsed: collapsed)
            let frame = FloatingAgentPresentation.frame(visibleFrame: screen.visibleFrame, height: height)
            hosting.sizingOptions = []
            hosting.frame = CGRect(origin: .zero, size: frame.size)
            panel.contentView = hosting
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
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
        window.contentView = NSHostingView(rootView: FloatingAgentReportView(run: run, mateName: update.mateName))
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

    static func stackHeight(runCount: Int, collapsed: Bool) -> CGFloat {
        collapsed ? 40 : CGFloat(min(max(0, runCount), 3)) * 92 + 48
    }

    static func frame(visibleFrame: CGRect, height: CGFloat) -> CGRect {
        let width = min(312, max(0, visibleFrame.width - 24))
        let height = min(height, max(0, visibleFrame.height - 32))
        return CGRect(x: visibleFrame.maxX - width - 12, y: visibleFrame.maxY - height - 16,
                      width: width, height: height)
    }
}

struct FloatingAgentStack: View {
    @Environment(\.companionSnapshotRendering) private var snapshotRendering
    let runs: [AgentRun]
    let mates: [Mate]
    let collapsed: Bool
    let onToggle: () -> Void
    let onHome: () -> Void
    let onOpen: (AgentRun, Mate) -> Void
    var updates: [FloatingAgentNoticeItem] = []
    var onReport: (FloatingAgentNoticeItem) -> Void = { _ in }
    var onDismiss: (FloatingAgentNoticeItem) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onHome) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .help("Open chats")
                .accessibilityLabel("Open chats")
                Text("\(runs.count) active \(runs.count == 1 ? "job" : "jobs")")
                    .font(DS.Fonts.caption.weight(.medium))
                if !updates.isEmpty {
                    Text("· \(updates.count) \(updates.count == 1 ? "update" : "updates")")
                        .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                }
                if runs.contains(where: { $0.status.needsUser }) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(DS.Colors.warningText)
                        .accessibilityLabel("Work needs your review")
                }
                Spacer(minLength: 0)
                Button(action: onToggle) {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help(collapsed ? "Show agent bubbles" : "Hide agent bubbles")
                .accessibilityLabel(collapsed ? "Show agent bubbles" : "Hide agent bubbles")
            }
            .buttonStyle(.plain)
            .frame(height: 24)
            if !collapsed {
                if snapshotRendering { rows }
                else { ScrollView { rows }.scrollIndicators(.hidden) }
            }
        }
        .padding(8)
        .foregroundStyle(DS.Colors.textPrimary)
        .background(DS.Colors.surface1.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
    }

    private var rows: some View {
        VStack(spacing: 8) {
            ForEach(FloatingAgentPresentation.rows(runs: runs, updates: updates)) { row in
                switch row {
                case .update(let update):
                    FloatingAgentNoticeCard(run: update.run, mateName: update.mateName,
                                            onReport: { onReport(update) }, onDismiss: { onDismiss(update) })
                case .agent(let run):
                    if let mate = FloatingAgentPresentation.owner(for: run, mates: mates) {
                        FloatingAgentCard(run: run, mate: mate) { onOpen(run, mate) }
                    }
                }
            }
        }
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
            .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
