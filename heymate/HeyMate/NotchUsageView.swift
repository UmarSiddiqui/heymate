import SwiftUI

extension NotchUsageProvider {
    var tint: Color {
        switch self {
        case .codex: return Color(red: 0.57, green: 0.85, blue: 0.72)
        case .claude: return Color(red: 0.89, green: 0.65, blue: 0.49)
        case .cursor: return Color(red: 0.65, green: 0.72, blue: 0.96)
        default:
            // A stable hue per custom source, so two of them never look alike.
            let hue = Double(rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
            return Color(hue: hue, saturation: 0.38, brightness: 0.95)
        }
    }
}

/// CodeNotch's provider ring, adapted through a narrow HeyMate host boundary.
struct NotchUsageRing: View {
    let provider: NotchUsageProvider
    let window: NotchUsageWindow?
    var stale = false
    var size: CGFloat = 28
    var working = false
    var activity: CNActivitySummary? = nil
    var refreshing = false
    var weeklyWindow: NotchUsageWindow? = nil
    var remaining = false
    var reducesMotion = false
    var blocked = false
    private var summary: CNActivitySummary? {
        activity ?? (working ? CNActivitySummary(sessions: [.init(id: "managed", name: provider.name, detail: "HeyMate", state: .busy, waitingFor: nil, since: .distantPast)]) : nil)
    }
    var body: some View {
        CNProviderRing(provider: provider, usedFraction: window?.fraction,
                       weeklyFraction: weeklyWindow?.fraction, showsRemaining: remaining,
                       isStale: stale, activity: summary, isRefreshing: refreshing, reduceMotion: reducesMotion, isBlocked: blocked)
            .scaleEffect(size / 44).frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider.name), \(window?.detail(remaining: remaining) ?? "usage unavailable")\(stale ? ", stale reading" : "")\(summary.map { ", \($0.label)" } ?? "")")
    }
}

@MainActor
struct NotchCompactUsage: View {
    @ObservedObject private var store: NotchUsageStore
    init(store: NotchUsageStore? = nil) { self.store = store ?? .shared }
    private var providers: [NotchUsageProvider] { store.idleProviders }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            HStack(spacing: NotchLayoutMath.compactUsageSpacing) {
                ForEach(providers.prefix(NotchLayoutMath.compactUsageLimit)) { provider in
                    NotchUsageRing(provider: provider, window: store.headline(provider),
                                   stale: store.status[provider] != nil || store.readings[provider]?.isStale(at: timeline.date) == true,
                                   size: NotchLayoutMath.compactUsageRingSize,
                                   activity: CNActivitySummary(sessions: store.sessions[provider] ?? []),
                                   refreshing: store.refreshing.contains(provider),
                                   weeklyWindow: store.weeklyWindow(provider), remaining: store.showsRemaining,
                                   reducesMotion: store.reducesMotion, blocked: store.isBlocked(provider))
                }
                if providers.count > NotchLayoutMath.compactUsageLimit {
                    Text("+\(providers.count - NotchLayoutMath.compactUsageLimit)")
                        .font(DS.Fonts.micro).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: NotchLayoutMath.compactUsageOverflowWidth)
                        .accessibilityLabel("\(providers.count - NotchLayoutMath.compactUsageLimit) more providers in Usage")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct NotchUsageView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var store: NotchUsageStore
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var selectedProvider: NotchUsageProvider?

    init(companionManager: CompanionManager, store: NotchUsageStore? = nil,
         initialProvider: NotchUsageProvider? = nil) {
        self.companionManager = companionManager
        self.store = store ?? .shared
        _selectedProvider = State(initialValue: initialProvider)
    }

    private var liveRuns: [AgentRun] { companionManager.agentRuns.filter { !$0.status.isTerminal } }
    private var visibleRuns: [AgentRun] {
        guard let selectedProvider else { return liveRuns }
        return liveRuns.filter {
            (selectedProvider == .codex && $0.executor == .codex)
                || (selectedProvider == .claude && $0.executor == .claudeCode)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The overview is one line: readings, then refresh and add at
            // its end. A provider's details get the header row above them.
            if selectedProvider == nil {
                HStack(spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in chips(date: timeline.date) }
                    header.fixedSize()
                }
            } else {
                header
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    if let selectedProvider { providerDetails(selectedProvider, date: timeline.date) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .onChange(of: store.providers) { _, providers in
            if let selectedProvider, !providers.contains(selectedProvider) { self.selectedProvider = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let selectedProvider {
                Button {
                    withAnimation(CNNotchMotion.respectingReduceMotion(CNNotchMotion.contents, systemReduceMotion || store.reducesMotion)) { self.selectedProvider = nil }
                } label: {
                    Label("All providers", systemImage: "chevron.left")
                        .font(DS.Fonts.caption.weight(.medium))
                }
                .buttonStyle(.plain).fixedSize()
                .accessibilityIdentifier("usage-back")
                Text(selectedProvider.name).font(DS.Fonts.control).lineLimit(1)
            }
            // The tab already says Usage; the overview needs no title.
            if !visibleRuns.isEmpty {
                Button { companionManager.openDesktopWindow(section: .chat) } label: {
                    Text(visibleRuns.contains { $0.status.needsUser } ? "Needs you" : "\(visibleRuns.count) active")
                        .font(DS.Fonts.micro)
                        .foregroundStyle(visibleRuns.contains { $0.status.needsUser } ? DS.Colors.warningText : .secondary)
                }.buttonStyle(.plain).help("Open HeyMate agent work")
            }
            let external = (selectedProvider.map { store.sessions[$0] ?? [] } ?? store.sessions.values.flatMap { $0 }).filter { $0.state != .idle }
            if !external.isEmpty {
                Text(external.contains { $0.state == .waiting } ? "External · needs you" : external.contains { $0.state == .busy } ? "External · \(external.filter { $0.state == .busy }.count) active" : "External · complete")
                    .font(DS.Fonts.micro).foregroundStyle(.secondary).lineLimit(1)
                    .help("Observed in coding tools. Select a provider ring for session details.")
            }
            Spacer(minLength: 0)
            Button {
                if let selectedProvider { store.refresh(selectedProvider) } else { store.refresh() }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(selectedProvider.map { "Refresh \($0.name) usage" } ?? "Refresh usage")
                .accessibilityLabel("Refresh usage")
            Button { companionManager.openDesktopWindow(section: .notch) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).help("Add or manage usage sources").foregroundStyle(.secondary)
                .accessibilityLabel("Manage usage sources")
        }
    }

    private func ring(_ provider: NotchUsageProvider, window: NotchUsageWindow?, stale: Bool, size: CGFloat, working: Bool) -> some View {
        let managed = liveRuns.filter { (provider == .codex && $0.executor == .codex) || (provider == .claude && $0.executor == .claudeCode) }.map { run in
            CNAgentSession(id: "heymate.\(run.id)", name: "HeyMate", detail: "Managed agent work",
                           state: run.status.needsUser ? .waiting : .busy, waitingFor: run.status.needsUser ? "Needs you in HeyMate" : nil, since: .distantPast)
        }
        return NotchUsageRing(provider: provider, window: window, stale: stale, size: size, working: working,
                       activity: CNActivitySummary(sessions: (store.sessions[provider] ?? []) + managed),
                       refreshing: store.refreshing.contains(provider), weeklyWindow: store.weeklyWindow(provider),
                       remaining: store.showsRemaining, reducesMotion: store.reducesMotion, blocked: store.isBlocked(provider))
    }

    private func state(_ provider: NotchUsageProvider, _ date: Date) -> (stale: Bool, working: Bool, needsAttention: Bool) {
        let reading = store.readings[provider]
        let runs = liveRuns.filter { (provider == .codex && $0.executor == .codex) || (provider == .claude && $0.executor == .claudeCode) }
        return (store.status[provider] != nil || reading?.isStale(at: date) == true,
                runs.contains { $0.status == .running || $0.status == .planning },
                runs.contains { $0.status.needsUser })
    }

    /// Glanceable: only connected providers, each with its reading and when
    /// it resets. Connecting more lives behind "+".
    private func chips(date: Date) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if store.displayedProviders.isEmpty {
                    Button { companionManager.openDesktopWindow(section: .notch) } label: {
                        Label("Connect a coding tool to see its usage", systemImage: "plus.circle")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
                ForEach(store.displayedProviders) { provider in
                    let s = state(provider, date)
                    let window = store.headline(provider)
                    Button {
                        withAnimation(CNNotchMotion.respectingReduceMotion(CNNotchMotion.contents, systemReduceMotion || store.reducesMotion)) { selectedProvider = provider }
                    } label: {
                        HStack(spacing: 7) {
                            ring(provider, window: window, stale: s.stale, size: 28, working: s.working)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.name).font(DS.Fonts.caption.weight(.medium)).lineLimit(1)
                                Text(chipSubtitle(provider, window: window, date: date))
                                    .font(DS.Fonts.caption).monospacedDigit()
                                    .foregroundStyle(s.needsAttention ? DS.Colors.warningText : .secondary)
                            }
                        }
                        .padding(.vertical, 5).padding(.horizontal, 9)
                        .background(Capsule().fill(DS.Colors.notchWellFill))
                    }
                    .buttonStyle(.plain)
                    .help("Show \(provider.name) usage and reset times")
                    .accessibilityIdentifier("usage-provider-\(provider.rawValue)")
                }
            }
        }
    }

    private func chipSubtitle(_ provider: NotchUsageProvider, window: NotchUsageWindow?, date: Date) -> String {
        guard let window else { return store.refreshing.contains(provider) ? "Reading…" : "Unavailable" }
        let reading = window.headline(remaining: store.showsRemaining)
        guard let reset = window.resetsAt, reset > date else { return reading }
        return "\(reading) · \(Self.shortDuration(until: reset, from: date))"
    }

    /// "45m", "3h", "2d": short enough to sit beside a percentage.
    static func shortDuration(until end: Date, from start: Date) -> String {
        let minutes = max(Int(end.timeIntervalSince(start) / 60), 1)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours)h" : "\(hours / 24)d"
    }

    /// A single provider's windows share one horizontal strip. Additional
    /// windows scroll sideways; the notch never grows a second provider list.
    private func providerDetails(_ provider: NotchUsageProvider, date: Date) -> some View {
        let reading = store.readings[provider]
        let s = state(provider, date)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 16) {
                ring(provider, window: store.headline(provider), stale: s.stale, size: 30, working: s.working)
                if !store.enabled.contains(provider) {
                    Button("Connect \(provider.name)") { store.setEnabled(true, provider: provider) }
                        .buttonStyle(.plain).font(DS.Fonts.control)
                } else {
                    if let status = store.status[provider] {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(status).font(DS.Fonts.micro).foregroundStyle(DS.Colors.warningText)
                                .fixedSize(horizontal: false, vertical: true)
                            if provider == .claude && status.contains("Keychain") {
                                Button("Allow access…") { store.refresh(provider, interactive: true) }
                                    .buttonStyle(.plain).font(DS.Fonts.caption)
                            }
                        }.frame(width: 140, alignment: .leading)
                    } else if reading == nil {
                        Text(store.refreshing.contains(provider) ? "Reading usage…" : "Usage unavailable")
                            .font(DS.Fonts.caption).foregroundStyle(.secondary)
                    } else if s.stale {
                        Text("Stale reading").font(DS.Fonts.caption).foregroundStyle(DS.Colors.warningText)
                    }
                    ForEach(store.sessions[provider] ?? []) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name).font(DS.Fonts.caption.weight(.medium))
                            Text(session.waitingFor ?? session.detail).font(DS.Fonts.micro).foregroundStyle(.secondary)
                            Text(session.state.label).font(DS.Fonts.micro).foregroundStyle(session.state == .waiting ? DS.Colors.warningText : .secondary)
                        }.lineLimit(1).frame(maxWidth: 160)
                    }
                    ForEach(reading?.runtimeDetails ?? [], id: \.self) { detail in
                        Text(detail).font(DS.Fonts.micro).foregroundStyle(.secondary).frame(width: 180)
                    }
                    ForEach(reading?.windows ?? []) { window in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.title).font(DS.Fonts.micro).foregroundStyle(.secondary)
                            Text(window.detail(remaining: store.showsRemaining))
                                .font(DS.Fonts.title).monospacedDigit()
                            if let reset = window.resetsAt {
                                if reset > date {
                                    Text("Resets \(reset, style: .relative)").font(DS.Fonts.micro).foregroundStyle(.secondary)
                                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                                } else {
                                    Text("Reset passed").font(DS.Fonts.micro).foregroundStyle(.secondary)
                                }
                            }
                        }.fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("usage-details-\(provider.rawValue)")
    }
}
