import AppKit
import SwiftUI

extension NotchUsageProvider {
    var tint: Color {
        switch self { case .codex: return Color(red: 0.57, green: 0.85, blue: 0.72)
        case .claude: return Color(red: 0.89, green: 0.65, blue: 0.49)
        case .cursor: return Color(red: 0.65, green: 0.72, blue: 0.96) }
    }
}

struct NotchUsageRing: View {
    let provider: NotchUsageProvider
    let window: NotchUsageWindow?
    var stale = false
    var compact = false
    var working = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: compact ? 2 : 4)
            if let window {
                Circle().trim(from: 0, to: window.fraction)
                    .stroke(provider.tint.opacity(stale ? 0.35 : 1), style: StrokeStyle(lineWidth: compact ? 2 : 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if compact {
                Circle().fill(provider.tint.opacity(working ? (pulse ? 1 : 0.35) : 0.6))
                    .frame(width: 4, height: 4)
            } else {
                VStack(spacing: 1) {
                    Text(window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—")
                        .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(window == nil ? "no reading" : "used").font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: compact ? 17 : 64, height: compact ? 17 : 64)
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
                ForEach(NotchUsageProvider.allCases.filter { store.enabled.contains($0) }) { provider in
                    NotchUsageRing(provider: provider, window: store.readings[provider]?.windows.first,
                                   stale: store.status[provider] != nil || store.readings[provider]?.isStale(at: timeline.date) == true,
                                   compact: true)
                }
            }
        }
    }
}

struct NotchUsageView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var store: NotchUsageStore
    init(companionManager: CompanionManager, store: NotchUsageStore = .shared) {
        self.companionManager = companionManager
        self.store = store
    }
    private var liveRuns: [AgentRun] { companionManager.agentRuns.filter { !$0.status.isTerminal } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Room to keep building").font(.system(size: 18, weight: .semibold))
                        Text("Your coding limits, at a glance.").font(DS.Fonts.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh usage")
                    Button("Manage") { companionManager.openDesktopWindow(section: .notch) }
                        .dsCapsuleButtonStyle(.quiet)
                }
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(NotchUsageProvider.allCases) { provider in
                            providerCard(provider, date: timeline.date)
                        }
                    }
                }
                Divider().overlay(.white.opacity(0.08))
                HStack {
                    Text("HEYMATE AGENTS").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    Text(liveRuns.isEmpty ? "All quiet" : "\(liveRuns.count) active").font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
                if liveRuns.isEmpty {
                    Text("Running tasks and approval requests appear here.")
                        .font(DS.Fonts.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(liveRuns.prefix(6)) { run in
                        Button { companionManager.openDesktopWindow(section: .chat) } label: {
                            HStack(spacing: 10) {
                                Circle().fill(run.status.needsUser ? Color.orange : Color.green).frame(width: 6, height: 6)
                                Text(run.title).font(DS.Fonts.caption).lineLimit(1)
                                Spacer()
                                Text(run.status.needsUser ? "Needs you" : run.status == .queued ? "Queued" : "Working")
                                    .font(DS.Fonts.caption).foregroundStyle(run.status.needsUser ? .orange : .secondary)
                                Text(run.executor.displayName).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
    }

    private func providerCard(_ provider: NotchUsageProvider, date: Date) -> some View {
        let enabled = store.enabled.contains(provider)
        let reading = store.readings[provider]
        let stale = store.status[provider] != nil || reading?.isStale(at: date) == true
        let providerRuns = liveRuns.filter { (provider == .codex && $0.executor == .codex) || (provider == .claude && $0.executor == .claudeCode) }
        let needsAttention = providerRuns.contains { $0.status.needsUser }
        let working = providerRuns.contains { $0.status == .running || $0.status == .planning }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(provider.name).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if needsAttention {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("Agent needs your approval")
                } else if working { Circle().fill(.green).frame(width: 5, height: 5) }
            }
            NotchUsageRing(provider: provider, window: reading?.windows.first, stale: stale, working: working)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
            if !enabled {
                Button("Connect") { store.setEnabled(true, provider: provider) }
                    .dsCapsuleButtonStyle(.secondary)
                    .help("Read usage using your existing \(provider.name) sign-in. Credentials stay on this Mac.")
            } else {
                if let status = store.status[provider] {
                    Text(status).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if provider == .claude && status.contains("Keychain") {
                        Button("Allow access…") { store.refresh(provider, interactive: true) }.font(DS.Fonts.caption)
                    }
                } else if stale {
                    Text("Stale · refreshing").font(.system(size: 10)).foregroundStyle(.orange)
                } else if reading == nil {
                    Text("Reading usage…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ForEach(reading?.windows ?? []) { window in
                    HStack(alignment: .top, spacing: 4) {
                        Text(window.title).font(.system(size: 10))
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(window.usedPercent.rounded()))% used").font(.system(size: 10, weight: .medium)).monospacedDigit()
                            if let reset = window.resetsAt {
                                if reset > date {
                                    Text("Resets \(reset, style: .relative)").font(.system(size: 9)).foregroundStyle(.secondary)
                                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                                } else {
                                    Text("Reset passed · awaiting update").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(provider.tint.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.07)))
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
