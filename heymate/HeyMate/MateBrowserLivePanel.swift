//
//  MateBrowserLivePanel.swift
//  HeyMate
//
//  Shows, in a mate's chat, what that mate's browser is on: page title, URL
//  and a picture refreshed every couple of seconds while the mate is
//  working, with Take over / Hand back beside it. The picture comes from the
//  driver's own window capture (IsolatedBrowserWorkers.liveImage); there is
//  no second browser here. Refresh stops when the panel is collapsed or
//  gone, when the browser goes idle, and during takeover. The panel lives in
//  HeyMate's window, so it follows "Show in screen recordings" with it.
//

import AppKit
import SwiftUI

struct MateBrowserLivePanel: View {
    let mateID: UUID

    @ObservedObject private var browsers = IsolatedBrowserWorkers.shared
    @ObservedObject private var setup = CuaDriverSetup.shared
    @State private var isExpanded: Bool

    init(mateID: UUID) {
        self.mateID = mateID
        _isExpanded = State(initialValue: MateAgentSettingsStore.shared.settings(for: mateID).browserPanelStartsOpen)
    }
    @State private var image: NSImage?

    static let refreshInterval: Duration = .seconds(2)

    private var state: BrowserLiveState? { browsers.live[mateID] }
    private var control: IsolatedBrowserWorkers.Control { browsers.control(for: mateID) }
    private var driverMissing: Bool { !setup.isReady && CuaDriverClient.installedExecutable == nil }

    var body: some View {
        Group {
            if browsers.isPersistent(mateID), driverMissing {
                missingDriverLine
            } else if let state {
                panel(state)
            }
        }
        .task { if driverMissing { await setup.refresh() } }
    }

    private var missingDriverLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").font(DS.Glyph.small).foregroundColor(DS.Colors.textTertiary)
                .accessibilityHidden(true)
            Text(setupMessage)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if setup.phase == .installing {
                ProgressView().controlSize(.mini)
            } else {
                Button("Set up") { Task { await setup.install() } }
                    .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                    .accessibilityLabel("Set up the browser driver")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous).fill(DS.Colors.surface2))
    }

    private var setupMessage: String {
        if case .failed(let reason) = setup.phase { return "Browser setup failed: \(reason)" }
        return "This Mate's browser needs CuaDriver, which isn't installed."
    }

    private func panel(_ state: BrowserLiveState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe").font(DS.Glyph.small).foregroundColor(DS.Colors.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title.isEmpty ? "Mate browser" : state.title)
                        .font(DS.Fonts.control)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(state.url.isEmpty ? "No page yet" : state.url)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                Text(statusText(state))
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                MateBrowserToolbarButton(mateID: mateID)
                Button { MateSettingsRouter.shared.open(mateID: mateID, section: .files) } label: {
                    Image(systemName: "gearshape").font(DS.Glyph.small)
                }
                .dsToolbarIconButtonStyle(size: DS.ControlSize.small)
                .help("Browser settings")
                .accessibilityLabel("Browser settings for this agent")
                Button { isExpanded.toggle() } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(DS.Glyph.small)
                }
                .dsToolbarIconButtonStyle(size: DS.ControlSize.small)
                .help(isExpanded ? "Hide browser view" : "Show browser view")
                .accessibilityLabel(isExpanded ? "Hide browser view" : "Show browser view")
            }
            if isExpanded {
                snapshotArea
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous).fill(DS.Colors.surface2))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        .task(id: refreshKey(state)) { await refreshLoop(state) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mate browser on \(state.title.isEmpty ? state.url : state.title)")
    }

    @ViewBuilder private var snapshotArea: some View {
        if control != .mate {
            Text("You have control of this browser. Its view pauses until Hand back.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
                .accessibilityLabel("Picture of the Mate's browser page")
        } else {
            Text(state?.isWorking == true ? "Waiting for the first picture…" : "The view refreshes while the Mate is browsing.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private func statusText(_ state: BrowserLiveState) -> String {
        switch control {
        case .person: return "You have control"
        case .takingOver: return "Taking over…"
        case .mate: return state.isWorking ? "Working" : "Idle"
        }
    }

    private func refreshKey(_ state: BrowserLiveState) -> String {
        "\(isExpanded)-\(state.isWorking)-\(control)"
    }

    private func refreshLoop(_ state: BrowserLiveState) async {
        guard control == .mate else { image = nil; return }
        guard isExpanded else { return }
        // One picture when idle so the panel is not blank; repeat only while working.
        repeat {
            if let data = await browsers.liveImage(for: mateID), let picture = NSImage(data: data) {
                guard !Task.isCancelled, control == .mate else { return }
                image = picture
            }
            guard state.isWorking else { return }
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
        } while !Task.isCancelled && isExpanded && control == .mate && browsers.live[mateID]?.isWorking == true
    }
}
