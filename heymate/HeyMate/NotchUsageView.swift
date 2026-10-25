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

/// A thin usage arc around the provider's own logo.
struct NotchUsageRing: View {
    let provider: NotchUsageProvider
    let window: NotchUsageWindow?
    var stale = false
    var size: CGFloat = 28
    var working = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    private var line: CGFloat { size < 20 ? 1.6 : 2.2 }
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: line)
            if let window {
                Circle().trim(from: 0, to: window.fraction)
                    .stroke(provider.tint.opacity(stale ? 0.4 : 1), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            NotchProviderGlyph(provider: provider, size: size * 0.46)
                .opacity(working ? (pulse ? 1 : 0.5) : window == nil ? 0.45 : 0.92)
        }
        .padding(line / 2)
        .frame(width: size, height: size)
        .onAppear { if working && !reduceMotion { pulse = true } }
        .onChange(of: working) { _, value in pulse = value && !reduceMotion }
        .animation(working && !reduceMotion ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil, value: pulse)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.name), \(window.map { "\(Int($0.usedPercent)) percent used" } ?? "usage unavailable")\(stale ? ", stale reading" : "")")
    }
}

struct NotchCompactUsage: View {
    @ObservedObject private var store = NotchUsageStore.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            HStack(spacing: 5) {
                ForEach(store.providers.filter { store.enabled.contains($0) }) { provider in
                    NotchUsageRing(provider: provider, window: store.readings[provider]?.windows.first,
                                   stale: store.status[provider] != nil || store.readings[provider]?.isStale(at: timeline.date) == true,
                                   size: 17)
                }
            }
        }
    }
}

struct NotchUsageView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var store: NotchUsageStore
    @State private var expanded = false
    init(companionManager: CompanionManager, store: NotchUsageStore = .shared) {
        self.companionManager = companionManager
        self.store = store
    }
    private var liveRuns: [AgentRun] { companionManager.agentRuns.filter { !$0.status.isTerminal } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Usage").font(.system(size: 12, weight: .semibold))
                if !liveRuns.isEmpty {
                    Text("\(liveRuns.count) agent\(liveRuns.count == 1 ? "" : "s") active")
                        .font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh usage").foregroundStyle(.secondary)
                Button { companionManager.openDesktopWindow(section: .notch) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("Add or manage usage sources").foregroundStyle(.secondary)
                Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain).help(expanded ? "Show less" : "Show details").foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                if expanded { detail(date: timeline.date) } else { chips(date: timeline.date) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
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
                ForEach(store.providers) { provider in
                    let s = state(provider, date)
                    let window = store.readings[provider]?.windows.first
                    Button {
                        if store.enabled.contains(provider) { withAnimation { expanded = true } }
                        else { store.setEnabled(true, provider: provider) }
                    } label: {
                        HStack(spacing: 7) {
                            NotchUsageRing(provider: provider, window: window, stale: s.stale, size: 26, working: s.working)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(provider.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                Text(!store.enabled.contains(provider) ? "Connect" : window.map { "\(Int($0.usedPercent.rounded()))%" } ?? (store.status[provider] == nil ? "…" : "—"))
                                    .font(.system(size: 10)).monospacedDigit()
                                    .foregroundStyle(s.needsAttention ? .orange : .secondary)
                            }
                        }
                        .padding(.vertical, 5).padding(.horizontal, 9)
                        .background(Capsule().fill(.white.opacity(store.enabled.contains(provider) ? 0.06 : 0.03)))
                        .opacity(store.enabled.contains(provider) ? 1 : 0.6)
                    }
                    .buttonStyle(.plain)
                    .help(store.enabled.contains(provider) ? "Show details" : "Connect \(provider.name)")
                }
            }
        }
    }

    private func detail(date: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.providers.filter { store.enabled.contains($0) }) { provider in
                    providerRow(provider, date: date)
                }
                if store.enabled.isEmpty {
                    Text("Tap a logo to connect it, or + to add your own.").font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
                if !liveRuns.isEmpty {
                    Divider().overlay(.white.opacity(0.08))
                    ForEach(liveRuns.prefix(6)) { run in
                        Button { companionManager.openDesktopWindow(section: .chat) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(run.status.needsUser ? Color.orange : Color.green).frame(width: 6, height: 6)
                                Text(run.title).font(DS.Fonts.caption).lineLimit(1)
                                Spacer()
                                Text(run.status.needsUser ? "Needs you" : run.status == .queued ? "Queued" : "Working")
                                    .font(DS.Fonts.caption).foregroundStyle(run.status.needsUser ? .orange : .secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func providerRow(_ provider: NotchUsageProvider, date: Date) -> some View {
        let reading = store.readings[provider]
        let s = state(provider, date)
        return HStack(alignment: .top, spacing: 10) {
            NotchUsageRing(provider: provider, window: reading?.windows.first, stale: s.stale, size: 28, working: s.working)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.name).font(.system(size: 11, weight: .semibold))
                    if s.needsAttention { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.system(size: 10)) }
                    Spacer(minLength: 0)
                    Button { store.setEnabled(false, provider: provider) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.tertiary).help("Disconnect \(provider.name)")
                }
                if let status = store.status[provider] {
                    Text(status).font(.system(size: 10)).foregroundStyle(.orange)
                    if provider == .claude && status.contains("Keychain") {
                        Button("Allow access…") { store.refresh(provider, interactive: true) }.font(DS.Fonts.caption)
                    }
                } else if reading == nil {
                    Text("Reading usage…").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if s.stale {
                    Text("Stale · refreshing").font(.system(size: 10)).foregroundStyle(.orange)
                }
                ForEach(reading?.windows ?? []) { window in
                    HStack(spacing: 6) {
                        Text(window.title).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(Int(window.usedPercent.rounded()))% used").font(.system(size: 10, weight: .medium)).monospacedDigit()
                        if let reset = window.resetsAt {
                            if reset > date {
                                Text("· resets \(reset, style: .relative)").font(.system(size: 10)).foregroundStyle(.secondary)
                                    .help(reset.formatted(date: .abbreviated, time: .shortened))
                            } else {
                                Text("· reset passed").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
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
