import AppKit
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
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
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
            header
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                if let selectedProvider { providerDetails(selectedProvider, date: timeline.date) }
                else { chips(date: timeline.date) }
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
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).fixedSize()
                .accessibilityIdentifier("usage-back")
                Text(selectedProvider.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            } else {
                Text("Usage").font(.system(size: 12, weight: .semibold))
            }
            if !visibleRuns.isEmpty {
                Button { companionManager.openDesktopWindow(section: .chat) } label: {
                    Text(visibleRuns.contains { $0.status.needsUser } ? "Needs you" : "\(visibleRuns.count) active")
                        .font(.system(size: 10))
                        .foregroundStyle(visibleRuns.contains { $0.status.needsUser } ? .orange : .secondary)
                }.buttonStyle(.plain).help("Open HeyMate agent work")
            }
            let external = (selectedProvider.map { store.sessions[$0] ?? [] } ?? store.sessions.values.flatMap { $0 }).filter { $0.state != .idle }
            if !external.isEmpty {
                Text(external.contains { $0.state == .waiting } ? "External · needs you" : external.contains { $0.state == .busy } ? "External · \(external.filter { $0.state == .busy }.count) active" : "External · complete")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
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

    private func chips(date: Date) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.overviewProviders) { provider in
                    let s = state(provider, date)
                    let window = store.headline(provider)
                    Button {
                        withAnimation(CNNotchMotion.respectingReduceMotion(CNNotchMotion.contents, systemReduceMotion || store.reducesMotion)) { selectedProvider = provider }
                    } label: {
                        HStack(spacing: 7) {
                            ring(provider, window: window, stale: s.stale, size: 28, working: s.working)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(!store.enabled.contains(provider) ? "Connect" : window?.headline(remaining: store.showsRemaining) ?? (store.refreshing.contains(provider) ? "Reading…" : "Unavailable"))
                                    .font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(s.needsAttention ? .orange : .secondary)
                            }
                        }
                        .padding(.vertical, 5).padding(.horizontal, 9)
                        .background(Capsule().fill(.white.opacity(store.enabled.contains(provider) ? 0.06 : 0.03)))
                        .opacity(store.enabled.contains(provider) ? 1 : 0.65)
                    }
                    .buttonStyle(.plain)
                    .help("Show \(provider.name) usage and reset times")
                    .accessibilityIdentifier("usage-provider-\(provider.rawValue)")
                }
            }
        }
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
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                } else {
                    if let status = store.status[provider] {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(status).font(.system(size: 10)).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            if provider == .claude && status.contains("Keychain") {
                                Button("Allow access…") { store.refresh(provider, interactive: true) }
                                    .buttonStyle(.plain).font(.system(size: 11))
                            }
                        }.frame(width: 140, alignment: .leading)
                    } else if reading == nil {
                        Text(store.refreshing.contains(provider) ? "Reading usage…" : "Usage unavailable")
                            .font(DS.Fonts.caption).foregroundStyle(.secondary)
                    } else if s.stale {
                        Text("Stale reading").font(DS.Fonts.caption).foregroundStyle(.orange)
                    }
                    ForEach(store.sessions[provider] ?? []) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name).font(.system(size: 11, weight: .medium))
                            Text(session.waitingFor ?? session.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(session.state.label).font(.system(size: 10)).foregroundStyle(session.state == .waiting ? .orange : .secondary)
                        }.lineLimit(1).frame(maxWidth: 160)
                    }
                    ForEach(reading?.runtimeDetails ?? [], id: \.self) { detail in
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 180)
                    }
                    ForEach(reading?.windows ?? []) { window in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.title).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(window.detail(remaining: store.showsRemaining))
                                .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            if let reset = window.resetsAt {
                                if reset > date {
                                    Text("Resets \(reset, style: .relative)").font(.system(size: 10)).foregroundStyle(.secondary)
                                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                                } else {
                                    Text("Reset passed").font(.system(size: 10)).foregroundStyle(.secondary)
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

nonisolated enum NotchShelfPresentation: Equatable {
    case hidden, hungry, eating, stored
    var isVisible: Bool { self != .hidden }
}

/// Only constructed for a file drag/drop. Ordinary hover and clicks never open it.
struct NotchShelfMouthView: View {
    @ObservedObject var center: NotchActivityCenter
    @ObservedObject var shelf: NotchShelfStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clearConfirmation = false
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 65) {
                eye
                eye
            }.padding(.top, 8)
            ZStack {
                RoundedRectangle(cornerRadius: center.shelfPresentation == .eating ? 20 : 48)
                    .fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 48).strokeBorder(.white.opacity(0.15), lineWidth: 2))
                if center.shelfPresentation == .hungry {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc.fill").font(.system(size: 24)).foregroundStyle(.white.opacity(0.85))
                        Text("Feed me a file").font(.system(size: 13, weight: .medium))
                    }
                } else if center.shelfPresentation == .eating {
                    Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundStyle(.green)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(shelf.items) { item in
                                VStack(spacing: 4) {
                                    Image(nsImage: item.thumbnail ?? NSWorkspace.shared.icon(forFile: item.fileURL.path))
                                        .resizable().scaledToFit().frame(width: 38, height: 38)
                                    Text(item.displayName).font(.system(size: 10)).lineLimit(1).frame(width: 72)
                                }
                                .onTapGesture { shelf.open(itemID: item.id) }
                                .onDrag { NSItemProvider(object: item.fileURL as NSURL) }
                                .contextMenu {
                                    Button("Reveal in Finder") { shelf.reveal(itemID: item.id) }
                                    Button("Remove from shelf") { shelf.remove(itemID: item.id) }
                                }
                                .help("Drag out, click to open, or right-click for more")
                            }
                        }.padding(.horizontal, 22)
                    }
                }
            }
            .frame(height: center.shelfPresentation == .eating ? 38 : 100)
            .frame(maxWidth: center.shelfPresentation == .hungry ? 260 : center.shelfPresentation == .eating ? 160 : .infinity)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.65), value: center.shelfPresentation)
            Text(center.shelfPresentation == .hungry ? "Drop to keep it here. Your original stays put." : "Saved on the shelf. Drag files back out whenever you need them.")
                .font(DS.Fonts.caption).foregroundStyle(.secondary)
            if !shelf.items.isEmpty {
                HStack {
                    Text("\(shelf.items.count) files").font(DS.Fonts.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("AirDrop") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: shelf.items.map(\.fileURL)) }
                        .dsCapsuleButtonStyle(.quiet)
                    Button("Clear shelf") { clearConfirmation = true }.dsCapsuleButtonStyle(.quiet)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32).padding(.top, 12)
        .confirmationDialog("Clear the shelf? Original files will not be deleted.", isPresented: $clearConfirmation) {
            Button("Clear shelf") { shelf.removeAll() }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityLabel(center.shelfPresentation == .hungry ? "Mate mouth open. Drop files to add to shelf." : "File shelf")
    }
    private var eye: some View {
        Capsule().fill(.white).frame(width: 12, height: center.shelfPresentation == .eating ? 4 : 19)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: center.shelfPresentation)
    }
}
