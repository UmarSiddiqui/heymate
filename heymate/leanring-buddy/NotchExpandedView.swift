//
//  NotchExpandedView.swift
//  leanring-buddy
//
//  The expanded notch card: hovering or clicking the notch tab drops this
//  Home/Agents surface below the camera housing (HeyClicky-style). This is
//  the app's only control surface — permissions, typed input, shortcuts,
//  engine, memory, and privacy all live here. The menu-bar panel is gone.
//

import AVFoundation
import SwiftUI

// MARK: - Tabs

/// Primary surfaces in the expanded card. Apps owns ambient notch tools;
/// Agents lists headless jobs.
enum NotchExpandedTab: String, CaseIterable, Identifiable {
    case home
    case apps
    case agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .apps: return "Apps"
        case .agents: return "Agents"
        }
    }

    var iconName: String {
        switch self {
        case .home: return "house"
        case .apps: return "square.grid.2x2"
        case .agents: return "sparkles"
        }
    }
}

// MARK: - Control metrics

/// Sizes from the macOS HIG: 28pt is the default control size, 20pt the
/// floor, and 10pt the smallest legible text. Everything clickable in the
/// notch is built on these so no target drops below the default.
enum NotchControlMetrics {
    /// Icon buttons and capsule buttons.
    static let controlSize: CGFloat = DS.ControlSize.regular
    /// Segmented tabs and the status pill in the 32pt header wing.
    static let compactControlSize: CGFloat = 26
    static let glyphSize: CGFloat = 13
    static let labelSize: CGFloat = 12
    static let bottomBarHeight: CGFloat = 42
}

/// Inline text action ("Clear", "Manage", "Sign in"). Looks like a link,
/// but the whole padded row is clickable — `Button("…").padding()` only
/// registers clicks on the letters, which misses the HIG's 20pt floor.
struct NotchLinkButton: View {
    let title: String
    var systemImage: String? = nil
    var color: Color = DS.Colors.accentText
    var font: Font = DS.Fonts.caption.weight(.semibold)
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(font)
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering ? DS.Colors.surface3.opacity(0.7) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
    }
}

/// Text button with a real 28pt hit target — replaces bare text links,
/// which only register a click on the glyphs themselves.
struct NotchCapsuleButton: View {
    let title: String
    var isProminent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .dsCapsuleButtonStyle(isProminent ? .primary : .secondary)
    }
}

// MARK: - Root

struct NotchExpandedView: View {
    @ObservedObject var companionManager: CompanionManager

    /// Height of the strip hidden behind the camera housing — content is
    /// pushed below it, same contract as `NotchPillView`.
    var occludedTopInset: CGFloat = 0

    /// Full expanded size the card lays out at. The window morphs from the
    /// pill frame up to this size; laying out at the destination size means
    /// AppKit clips the card instead of SwiftUI reflowing it into a stamp.
    var layoutSize: CGSize = .zero

    /// Live hardware cutout width (auxiliary-area formula). Used to draw the
    /// theme rim on the camera housing while the card is expanded.
    var hardwareNotchWidth: CGFloat = 0

    @ObservedObject var transitionModel: NotchSurfaceTransitionModel

    /// Called when the user presses the collapse chevron.
    var onClose: () -> Void

    @State private var selectedTab: NotchExpandedTab = .home
    @State private var isShowingAboutPopover = false

    var body: some View {
        // Background follows live hosting-view bounds. Destination-sized
        // controls stay top-centred underneath and reveal only after the
        // unified silhouette has substantially formed.
        GeometryReader { viewport in
            let contentWidth = layoutSize.width > 0 ? layoutSize.width : viewport.size.width
            let contentHeight = layoutSize.height > 0 ? layoutSize.height : viewport.size.height

            cardBody
                .frame(width: contentWidth, height: contentHeight, alignment: .top)
                .position(x: viewport.size.width / 2, y: contentHeight / 2)
                .opacity(transitionModel.morphContentOpacity)
        }
        .modifier(NotchLiquidGlassCardModifier(
            transitionModel: transitionModel,
            outlineColor: companionManager.themeColor,
            isOutlineEnabled: companionManager.isNotchOutlineEnabled,
            occludedTopInset: occludedTopInset
        ))
        .clipped()
    }

    private var cardBody: some View {
        VStack(spacing: 0) {
            notchWingHeader
                .frame(height: max(occludedTopInset, 24))

            VStack(spacing: 0) {
                // Settings and the model picker live in the app window only,
                // so every engine gets the same full-size controls there.
                Group {
                    switch selectedTab {
                    case .home:
                        NotchHomeTab(companionManager: companionManager)
                    case .apps:
                        NotchMicroAppsView(companionManager: companionManager)
                    case .agents:
                        NotchAgentsTab(companionManager: companionManager)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .onChange(of: companionManager.shouldRevealAgentsTab) { _, shouldReveal in
                if shouldReveal {
                    selectedTab = .agents
                    companionManager.shouldRevealAgentsTab = false
                }
            }
            .onChange(of: companionManager.shouldRevealAppsTab) { _, shouldReveal in
                if shouldReveal {
                    selectedTab = .apps
                    companionManager.shouldRevealAppsTab = false
                }
            }
            .onAppear {
                if companionManager.shouldRevealAgentsTab {
                    selectedTab = .agents
                    companionManager.shouldRevealAgentsTab = false
                } else if companionManager.shouldRevealAppsTab {
                    selectedTab = .apps
                    companionManager.shouldRevealAppsTab = false
                }
            }

            bottomActionBar
                .frame(height: NotchControlMetrics.bottomBarHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            BrandNebulaSurface.notchCard
        }
    }

    // MARK: Header

    private var notchWingHeader: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                NotchTabSwitcher(selectedTab: $selectedTab)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.black)
                .frame(width: max(hardwareNotchWidth, 0))
                .accessibilityHidden(true)

            // Status and collapse live on the right wing so the bottom bar
            // only carries tools, and neither wing reads as an empty box.
            // Quit sits against the camera housing, away from Collapse —
            // there is no Dock icon or menu bar to quit from otherwise.
            HStack(spacing: 8) {
                headerIconButton(systemName: "power", help: "Quit HeyMate") {
                    NSApp.terminate(nil)
                }
                Spacer(minLength: 0)
                headerStatusPill
                headerIconButton(systemName: "chevron.up", help: "Collapse", action: onClose)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        // Pure black, same as the camera housing and the card fill — the
        // old chrome tint drew two visible boxes either side of the notch.
        .background(Color.black)
    }

    private var headerStatusPill: some View {
        HStack(spacing: 6) {
            DSStatusDot(color: statusDotColor, size: 7)
            Text(headerStatusText)
                .font(DS.Fonts.control)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(height: NotchControlMetrics.compactControlSize)
        .background(Capsule().fill(DS.Colors.surface2.opacity(0.8)))
        .animation(.easeInOut(duration: 0.2), value: companionManager.voiceState)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(headerStatusText)")
    }

    /// The Home tab's Doors row already puts Window and Settings one tap
    /// away with a ⌘-shortcut. Repeating them here is only useful on the
    /// tabs that don't have a Doors row — Apps and Agents — so this bar
    /// drops them exactly where they'd be
    /// a pure duplicate instead of always carrying six icons.
    private var doorsRowIsVisible: Bool {
        selectedTab == .home
            && companionManager.hasCompletedOnboarding
            && companionManager.allPermissionsGranted
    }

    /// Tools only. Status and collapse moved to the header's right wing.
    private var bottomActionBar: some View {
        HStack(spacing: 8) {
            engineChip

            Spacer(minLength: 0)

            if !doorsRowIsVisible {
                headerIconButton(systemName: "macwindow", help: "Open HeyMate window") {
                    companionManager.openDesktopWindow(section: .chat)
                }
            }

            NotchCursorDock(companionManager: companionManager)

            headerIconButton(systemName: "info.circle", help: "About HeyMate") {
                isShowingAboutPopover.toggle()
            }
            .popover(isPresented: $isShowingAboutPopover, arrowEdge: .bottom) {
                notchAboutPopover
            }

            if !doorsRowIsVisible {
                headerIconButton(systemName: "gearshape", help: "Settings") {
                    companionManager.openDesktopWindow(section: .settings)
                }
            }
        }
        // 16pt matches the content columns and keeps the end controls clear
        // of the card's 24pt bottom corners.
        .padding(.horizontal, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DS.Colors.hairline)
                .frame(height: 0.5)
                .padding(.horizontal, 16)
        }
    }

    /// Names the engine instead of hiding it behind a bare CPU glyph — which
    /// brain answers is the one setting people check most.
    private var engineChip: some View {
        Button(action: {
            companionManager.openDesktopWindow(section: .settings)
        }) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.accentText)
                Text(companionManager.selectedBrain.displayName)
                    .font(DS.Fonts.control)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(DS.Glyph.micro)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: NotchControlMetrics.controlSize)
            .background(Capsule().fill(DS.Colors.surface3.opacity(0.82)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Choose engine, model, and effort in Settings")
    }

    private func headerIconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Glyph.regular)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: NotchControlMetrics.controlSize, height: NotchControlMetrics.controlSize)
                .background(Circle().fill(DS.Colors.surface3.opacity(0.82)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }

    private var statusDotColor: Color {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return DS.Colors.warning
        }
        return DS.Colors.voiceStatus(companionManager.voiceState)
    }

    private var headerStatusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        }
    }

    // MARK: About

    /// Version, what this thing is, and the way out to help. Small on
    /// purpose — anything longer belongs in the window.
    private var notchAboutPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HeyMate")
                .font(DS.Fonts.headline)
            Text("Version \(AppUpdateController.shared.displayedVersion)")
                .font(DS.Fonts.caption)
                .foregroundColor(.secondary)
            Text("A notch companion that can see your screen, talk back, and run coding agents in ~/Projects/heymate.")
                .font(DS.Fonts.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 240, alignment: .leading)

            Divider()

            Button("Check for updates") {
                AppUpdateController.shared.checkForUpdates()
            }
            .buttonStyle(.plain)
            .font(DS.Fonts.caption.weight(.medium))
            .pointerCursor()
            .disabled(!AppUpdateController.shared.canCheckForUpdates)

            ForEach(SupportLinks.destinations) { destination in
                Button(destination.title) { SupportLinks.open(destination) }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.caption)
                    .pointerCursor()
            }

            Divider()

            Button("Quit HeyMate") {
                isShowingAboutPopover = false
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(DS.Fonts.caption.weight(.semibold))
            .foregroundColor(DS.Colors.destructiveText)
            .pointerCursor()
        }
        .padding(14)
    }

}

// MARK: - Tab Switcher

private struct NotchTabSwitcher: View {
    @Binding var selectedTab: NotchExpandedTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NotchExpandedTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.Colors.surface2.opacity(0.7)))
    }

    /// The selected tab carries its name so the header says where you are;
    /// the others stay icon-only to fit the wing beside the camera housing.
    private func tabButton(for tab: NotchExpandedTab) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: {
            withAnimation(DS.Animation.controlSpring) { selectedTab = tab }
        }) {
            HStack(spacing: 5) {
                Image(systemName: tab.iconName)
                    .font(DS.Glyph.regular)
                if isSelected {
                    Text(tab.title)
                        .font(DS.Fonts.control)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, isSelected ? 12 : 0)
            .frame(minWidth: 32, minHeight: NotchControlMetrics.compactControlSize)
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .background(
                Capsule().fill(isSelected ? DS.Colors.accent.opacity(0.22) : Color.clear)
            )
            .overlay(
                Capsule().stroke(
                    isSelected ? DS.Colors.accent.opacity(0.45) : Color.white.opacity(0.001),
                    lineWidth: 0.8
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(tab.title)
        .accessibilityLabel(tab.title)
    }
}

// MARK: - Home Tab

private struct NotchHomeTab: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var typedMessageInput = ""
    @FocusState private var isComposerFocused: Bool

    private var needsSetup: Bool {
        !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted
    }

    /// Idle with no agent running: the status card has gone quiet, so the
    /// composer is the only thing left to look at and should read that way.
    private var isComposerHero: Bool {
        !companionManager.isForegroundAgentActive && companionManager.voiceState == .idle
    }

    var body: some View {
        GeometryReader { viewport in
            if needsSetup {
                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            setupCopySection
                            startButton
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        VStack(alignment: .leading, spacing: 10) {
                            if !companionManager.allPermissionsGranted {
                                permissionsSection
                            } else if !companionManager.hasCompletedOnboarding {
                                // Permissions done: which subscription runs
                                // HeyMate, installed and signed in from here,
                                // so the first question does not fail.
                                NotchSubscriptionChoiceSection(
                                    companionManager: companionManager,
                                    signIn: companionManager.subscriptionSignIn
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: viewport.size.height, alignment: .top)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 9) {
                            NotchStatusCard(companionManager: companionManager)
                            NotchSubscriptionSignInBanner(signIn: companionManager.subscriptionSignIn)
                            typedMessageInputRow
                            ContextualConnectorSuggestionBanner(companionManager: companionManager)
                            recentAgentRow
                        }
                    }
                    .frame(width: (viewport.size.width - 12) * 0.48)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            NotchTrayStrip(
                                activityCenter: companionManager.notchActivityCenter,
                                onOpenDesktop: { section in
                                    companionManager.openDesktopWindow(section: section)
                                }
                            )
                            doorsRow
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
            }
        }
    }

    // MARK: Setup

    @ViewBuilder
    private var setupCopySection: some View {
        if companionManager.allPermissionsGranted {
            Text("Permissions are done. Pick the AI you already pay for, then hit Start to meet HeyMate.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
        } else if companionManager.hasCompletedOnboarding {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Some permissions were revoked. Grant the missing ones below to keep using HeyMate.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    BrandAppIcon(size: 38)
                    Text("Hi, I'm HeyMate.")
                        .font(DS.Fonts.title)
                        .foregroundColor(DS.Colors.textPrimary)
                }
                Text("A small companion that lives next to your cursor and helps you as you use your Mac.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing runs in the background. HeyMate only takes a screenshot when you press the hotkey, and screenshots are never stored.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.destructiveText.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Pick a color")
                        .font(DS.Fonts.sectionLabel)
                        .foregroundColor(DS.Colors.textSecondary)
                    ThemeColorPicker(companionManager: companionManager)
                }
                .padding(.top, 4)
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchSectionHeader(title: "Permissions")

            if !companionManager.hasAccessibilityPermission || !companionManager.hasScreenRecordingPermission {
                NotchAppDropTile(
                    missingAccessibility: !companionManager.hasAccessibilityPermission,
                    missingScreenRecording: !companionManager.hasScreenRecordingPermission
                )
            }

            NotchPermissionRow(
                label: "Microphone",
                iconName: "mic",
                isGranted: companionManager.hasMicrophonePermission,
                grantAction: requestMicrophonePermission
            )
            NotchPermissionRow(
                label: "Accessibility",
                iconName: "hand.raised",
                isGranted: companionManager.hasAccessibilityPermission,
                subtitle: companionManager.hasAccessibilityPermission
                    ? nil
                    : "Drag HeyMate.app into the list if it isn't there",
                grantAction: { WindowPositionManager.requestAccessibilityPermission() }
            )
            NotchPermissionRow(
                label: "Screen Recording",
                iconName: "rectangle.dashed.badge.record",
                isGranted: companionManager.hasScreenRecordingPermission,
                subtitle: companionManager.hasScreenRecordingPermission
                    ? "Only takes a screenshot when you use the hotkey"
                    : "Grant once — signed builds keep this after rebuilds",
                grantAction: { WindowPositionManager.requestScreenRecordingPermission() }
            )

            Button("Why these permissions?") {
                if let url = URL(string: SupportLinks.permissionsPageURLString) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(DS.Fonts.caption)
            .foregroundColor(.secondary)
            .pointerCursor()
        }
    }

    private func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            NotchOnboardingStartButton(
                companionManager: companionManager,
                signIn: companionManager.subscriptionSignIn
            )
        }
    }

    // MARK: Typed input

    private var typedMessageInputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            typedMessageComposerRow
            commandBarFeedbackRow
        }
    }

    private var typedMessageComposerRow: some View {
        HStack(spacing: 8) {
            TextField("Ask HeyMate…", text: $typedMessageInput, axis: .vertical)
                .textFieldStyle(.plain)
                .font(isComposerHero ? DS.Fonts.headline : DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .padding(.leading, 14)
                .focused($isComposerFocused)
                .onSubmit(sendTypedMessageFromInput)

            Button(action: sendTypedMessageFromInput) {
                Image(systemName: "arrow.up")
                    .font(DS.Glyph.regular.weight(.bold))
                    .foregroundColor(canSendTypedMessage ? DS.Colors.textOnAccent : DS.Colors.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(canSendTypedMessage ? DS.Colors.accent : DS.Colors.surface3)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!canSendTypedMessage)
            .help("Send — starts a coding agent in ~/Projects/heymate")
            .padding(.trailing, 5)
        }
        .padding(.vertical, isComposerHero ? 9 : 5)
        .background(
            Capsule(style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.85))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    isComposerHero && isComposerFocused ? DS.Colors.accent.opacity(0.65) : DS.Colors.borderSubtle,
                    lineWidth: isComposerHero && isComposerFocused ? 1.3 : 0.5
                )
        )
        .shadow(
            color: isComposerHero ? DS.Colors.accentGlow.opacity(0.22) : .clear,
            radius: 14, y: 4
        )
        .opacity(companionManager.canAcceptTypedAgentTask ? 1 : 0.45)
        .disabled(!companionManager.canAcceptTypedAgentTask)
    }

    /// Command results and the /memory clear confirmation. Rendered under the
    /// input rather than spoken, because a command is a UI action and reading
    /// "no such command" aloud would be absurd.
    @ViewBuilder
    private var commandBarFeedbackRow: some View {
        if let notice = companionManager.openCodeTrainingNotice {
            VStack(alignment: .leading, spacing: 6) {
                Text(notice.detail)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Don't send") { companionManager.cancelOpenCodeTrainingSend() }
                        .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                    Button("Send anyway") { companionManager.confirmOpenCodeTrainingSend() }
                        .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                }
            }
        } else if companionManager.pendingMemoryClearConfirmation {
            HStack(spacing: 8) {
                Text("Delete everything HeyMate remembers?")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 8)
                Button("Cancel") { companionManager.cancelPendingMemoryClear() }
                    .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                Button("Delete") { companionManager.confirmPendingMemoryClear() }
                    .dsCapsuleButtonStyle(.destructive, height: DS.ControlSize.small)
            }
        } else if let commandBarFeedback = companionManager.commandBarFeedback {
            Text(commandBarFeedback)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canSendTypedMessage: Bool {
        !typedMessageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && companionManager.canAcceptTypedAgentTask
    }

    private func sendTypedMessageFromInput() {
        guard canSendTypedMessage else { return }
        let messageText = typedMessageInput
        // A refused message keeps the text and the card: the reason renders
        // in the feedback row right below the field.
        guard companionManager.sendTypedMessage(messageText) else { return }
        typedMessageInput = ""

        // A slash command's answer (the /help listing, "no such command", the
        // memory-clear confirmation) renders right here, so collapsing the
        // card would throw it away before it could be read.
        if case .message = CommandBarParser.parse(messageText) {
            // Agent jobs need the Agents tab visible. Talk dismisses so the
            // overlay can point at the screen.
            if !AgentInvocation.isAgentRequest(messageText) {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }
        }
    }

    // MARK: Doors

    /// The four ways out of Home. Everything that used to be an inline
    /// section here — shortcuts, skills, connectors, memory, privacy — is
    /// a list or a form, which is exactly what a shallow notch card hanging
    /// off a camera housing is worst at. Those live in the window now;
    /// this row is the door.
    private var doorsRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            DSSectionLabel(title: "Jump to")

            // 2×2 so each door has room for a one-line "what's behind it"
            // and the column fills the card instead of floating at the top.
            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    NotchDoorTile(
                        title: "Agents",
                        subtitle: agentsDoorSubtitle,
                        systemName: "sparkles",
                        key: "1",
                        help: "See running and finished agent jobs (⌘1)"
                    ) {
                        companionManager.shouldRevealAgentsTab = true
                    }
                    NotchDoorTile(
                        title: "Window",
                        subtitle: "Chat and history",
                        systemName: "macwindow",
                        key: "2",
                        help: "Open the full HeyMate window (⌘2)"
                    ) {
                        companionManager.openDesktopWindow(section: .chat)
                    }
                }
                HStack(spacing: 7) {
                    NotchDoorTile(
                        title: "Skills",
                        subtitle: "How it answers",
                        systemName: "wand.and.stars",
                        key: "3",
                        help: "Markdown files that shape how HeyMate answers (⌘3)"
                    ) {
                        companionManager.openDesktopWindow(section: .skills)
                    }
                    NotchDoorTile(
                        title: "Settings",
                        subtitle: "Engine, voice, keys",
                        systemName: "gearshape",
                        key: "4",
                        help: "Engine, model, voice, shortcuts, and appearance (⌘4)"
                    ) {
                        companionManager.openDesktopWindow(section: .settings)
                    }
                }
            }
        }
    }

    /// Live count beats a static description on the one door whose
    /// contents change while you watch.
    private var agentsDoorSubtitle: String {
        let runs = companionManager.agentRuns
        let awaitingCount = runs.filter {
            $0.status == .awaitingPlanApproval || $0.status == .waitingForApproval
        }.count
        if awaitingCount > 0 { return "\(awaitingCount) need\(awaitingCount == 1 ? "s" : "") you" }
        let activeCount = runs.filter { !$0.status.isTerminal }.count
        if activeCount > 0 { return "\(activeCount) running" }
        if runs.isEmpty { return "None yet" }
        // A failed run is not "finished" from the user's side; say so.
        let failedCount = runs.filter { $0.status == .failed }.count
        let doneCount = runs.count - failedCount
        switch (doneCount, failedCount) {
        case (_, 0): return "\(doneCount) done"
        case (0, _): return "\(failedCount) failed"
        default: return "\(doneCount) done · \(failedCount) failed"
        }
    }

    // MARK: Recent agent

    /// Idle Home would otherwise end at the composer. The latest agent run
    /// is the thing people most often come back to check, so it takes the
    /// space — one tap jumps to its card on the Agents tab.
    @ViewBuilder
    private var recentAgentRow: some View {
        if isComposerHero {
            VStack(alignment: .leading, spacing: 6) {
                DSSectionLabel(title: "Last agent")
                if let latestRun = companionManager.agentRuns.max(by: { $0.createdAt < $1.createdAt }) {
                    NotchRecentAgentRow(run: latestRun) {
                        companionManager.shouldRevealAgentsTab = true
                    }
                } else {
                    // First run: say what the composer does rather than
                    // leaving the column to trail off into nebula.
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(DS.Glyph.small)
                            .foregroundColor(DS.Colors.textTertiary)
                        Text("None yet. Type a task above and press ↩ to start one.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .strokeBorder(DS.Colors.borderSubtle, style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    )
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct NotchRecentAgentRow: View {
    let run: AgentRun
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                DSStatusDot(color: DS.Colors.agentStatus(run.status))
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.title)
                        .font(DS.Fonts.control)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(DS.Glyph.small)
                    .foregroundColor(isHovering ? DS.Colors.textSecondary : DS.Colors.textTertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .dsSurface(.row, isHighlighted: isHovering)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .help("Open on the Agents tab")
    }

    private var detail: String {
        let when = RelativeDateTimeFormatter().localizedString(for: run.createdAt, relativeTo: Date())
        return "\(statusWord) · \(when)"
    }

    private var statusWord: String {
        switch run.status {
        case .queued: return "Queued"
        case .planning: return "Planning"
        case .awaitingPlanApproval: return "Plan ready"
        case .running: return "Running"
        case .waitingForApproval: return "Needs approval"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// One door tile. A struct (not a function) so each tile can carry its own
/// hover state — the icon stays neutral until the pointer is actually on
/// it, so the row doesn't compete with the composer for accent weight.
private struct NotchDoorTile: View {
    let title: String
    let subtitle: String
    let systemName: String
    let key: KeyEquivalent
    let shortcutLabel: String
    let help: String
    let action: () -> Void

    init(
        title: String,
        subtitle: String,
        systemName: String,
        key: KeyEquivalent,
        help: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemName = systemName
        self.key = key
        self.shortcutLabel = "⌘\(key.character)".uppercased()
        self.help = help
        self.action = action
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isHovering ? DS.Colors.accent.opacity(0.22) : DS.Colors.surface3.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: systemName)
                            .font(DS.Glyph.large)
                            .foregroundColor(isHovering ? DS.Colors.accentText : DS.Colors.textSecondary)
                    )

                // Shortcut rides the title line so the subtitle gets the
                // tile's full width instead of truncating beside a key cap.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(DS.Fonts.control)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(shortcutLabel)
                            .font(DS.Fonts.keycap)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Text(subtitle)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsSurface(.row, isHighlighted: isHovering)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
        .keyboardShortcut(key, modifiers: .command)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

private struct ContextualConnectorSuggestionBanner: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var suggestionMonitor: ContextualConnectorSuggestionMonitor
    @ObservedObject private var connections: ComposioConnectionsRuntime

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.suggestionMonitor = companionManager.contextualConnectorSuggestionMonitor
        self.connections = companionManager.composioConnections
    }

    @ViewBuilder
    var body: some View {
        if let suggestion = suggestionMonitor.suggestion,
           !connections.state(for: suggestion.toolkitSlug).isConnected {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(Color(red: 0.92, green: 0.12, blue: 0.14))
                        .frame(width: 30, height: 30)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(DS.Glyph.small)
                                .foregroundColor(.white)
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connect \(suggestion.toolkitName) to HeyMate")
                            .font(DS.Fonts.titleCompact)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Available for current \(suggestion.hostname) page")
                            .font(DS.Fonts.micro)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer()
                }

                HStack(spacing: 5) {
                    ForEach(suggestion.capabilities, id: \.self) { capability in
                        Text(capability)
                            .font(DS.Fonts.micro)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.Colors.surface3.opacity(0.6)))
                    }
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button("No") { suggestionMonitor.declinePermanently(suggestion) }
                        .dsCapsuleButtonStyle(.quiet)
                    Button("Not now") { suggestionMonitor.snooze(suggestion) }
                        .dsCapsuleButtonStyle(.secondary)
                    Button("Connect") { connect(suggestion) }
                        .dsCapsuleButtonStyle(.primary)
                }
            }
            .padding(10)
            .dsSurface(.tinted(DS.Colors.accent))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Connect \(suggestion.toolkitName) to HeyMate")
        }
    }

    private func connect(_ suggestion: ContextualConnectorSuggestion) {
        guard connections.isConfigured else {
            companionManager.openDesktopWindow(section: .settings)
            return
        }
        Task {
            await connections.connect(suggestion.toolkit)
            if connections.state(for: suggestion.toolkitSlug).isConnected {
                suggestionMonitor.declinePermanently(suggestion)
            }
        }
    }
}

// MARK: - Agents Tab

private struct NotchAgentsTab: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var sandboxPromptText = ""
    @State private var attachedPromptText = ""
    @State private var attachedFolderURL: URL?
    @State private var isShowingAttachedPrompt = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if let proposal = companionManager.standingOrderProposal {
                        standingOrderProposalCard(proposal)
                    }
                    composeCard
                    if isShowingAttachedPrompt {
                        attachedPromptCard
                    }
                    if !companionManager.agentRevealErrorText.isEmpty {
                        Text(companionManager.agentRevealErrorText)
                            .font(DS.Fonts.caption.weight(.medium))
                            .foregroundColor(DS.Colors.warningText)
                    }
                }
            }
            .frame(width: 310)

            // The list is only a few rows tall, and a plan card is taller than
            // that, so a run that starts waiting on the user brings its
            // Approve / Deny row into view instead of leaving it below the fold.
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    agentList
                }
                .onChange(of: runIDAwaitingUser) { _, runID in
                    guard let runID else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(runID, anchor: .bottom)
                    }
                }
                .onAppear {
                    guard let runID = runIDAwaitingUser else { return }
                    scrollProxy.scrollTo(runID, anchor: .bottom)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func standingOrderProposalCard(_ proposal: StandingOrderProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Standing order", systemImage: "bell.badge.fill")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.warningText)
            Text(proposal.title)
                .font(DS.Fonts.headline)
                .foregroundColor(DS.Colors.textPrimary)
            Text(proposal.task)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("May I look? Planning is read-only; doing still needs approval.")
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textTertiary)
            HStack(spacing: 8) {
                NotchCapsuleButton(title: "Plan it", isProminent: true) {
                    companionManager.approveStandingOrderProposal()
                }
                NotchCapsuleButton(title: "Dismiss") {
                    companionManager.dismissStandingOrderProposal()
                }
            }
        }
        .padding(12)
        .dsSurface(.tinted(DS.Colors.warning))
    }

    private var composeCard: some View {
        // The engine is named on the bottom bar's chip, so this card is just
        // the prompt field and the folder option.
        VStack(alignment: .leading, spacing: 10) {
            DSSectionLabel(title: "New agent")

            HStack(spacing: 8) {
                TextField("What should the agent build?", text: $sandboxPromptText)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.leading, 12)
                    .onSubmit(startSandbox)

                Button(action: startSandbox) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(DS.Colors.accent)
                        .frame(width: NotchControlMetrics.controlSize, height: NotchControlMetrics.controlSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(sandboxPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Start agent")
                .accessibilityLabel("Start agent")
                .padding(.trailing, 4)
            }
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(DS.Colors.surface3.opacity(0.55))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )

            Button(action: pickAttachedFolder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(DS.Glyph.small)
                    Text("Run in folder…")
                        .font(DS.Fonts.body)
                    Spacer()
                }
                .foregroundColor(DS.Colors.textSecondary)
                .frame(minHeight: NotchControlMetrics.controlSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(12)
        .dsSurface(.card)
    }

    private var attachedPromptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(attachedFolderURL?.lastPathComponent ?? "Folder")
                .font(DS.Fonts.headline)
                .foregroundColor(DS.Colors.textPrimary)
            Text(attachedFolderURL?.path ?? "")
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(2)
            HStack(spacing: 8) {
                TextField("What should it do here?", text: $attachedPromptText)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .onSubmit(startAttached)
                NotchCapsuleButton(title: "Run", isProminent: true, action: startAttached)
            }
        }
        .padding(12)
        .dsSurface(.card)
    }

    /// The newest run blocked on a plan or tool approval.
    private var runIDAwaitingUser: UUID? {
        companionManager.agentRuns
            .filter { $0.status == .awaitingPlanApproval || $0.status == .waitingForApproval }
            .max { $0.createdAt < $1.createdAt }?
            .id
    }

    @ViewBuilder
    private var agentList: some View {
        let sections = AgentRunDayGrouping.sections(from: companionManager.agentRuns)
        if sections.isEmpty {
            VStack(spacing: 10) {
                BuddyMark(size: .standard, color: DS.Colors.accent)
                    .padding(.top, 20)
                Text("No agents yet")
                    .font(DS.Fonts.titleCompact)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Say “HeyMate agent, …” or start one here.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
        } else {
            ForEach(sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 8) {
                    // Day-group titles are stored uppercase for the tests that pin them;
                    // the label displays them title-cased.
                    DSSectionLabel(title: section.title.capitalized)
                    ForEach(section.runs) { run in
                        AgentRunCard(
                            run: run,
                            onCancel: { companionManager.cancelAgent(runID: run.id) },
                            onApprove: { companionManager.approveAgent(runID: run.id) },
                            onDeny: { companionManager.denyAgent(runID: run.id) },
                            onApprovePlan: { companionManager.approveAgentPlan(runID: run.id) },
                            onDismissPlan: { companionManager.dismissAgentPlan(runID: run.id) },
                            onOpenFolder: { companionManager.revealAgentFolder(runID: run.id) }
                        )
                        .id(run.id)
                    }
                }
            }
        }
    }

    private func startSandbox() {
        let prompt = sandboxPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        companionManager.startSandboxAgent(prompt: prompt)
        sandboxPromptText = ""
    }

    private func pickAttachedFolder() {
        guard let folderURL = companionManager.pickExistingAgentFolder() else { return }
        attachedFolderURL = folderURL
        isShowingAttachedPrompt = true
        attachedPromptText = ""
    }

    private func startAttached() {
        let prompt = attachedPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folderURL = attachedFolderURL, !prompt.isEmpty else { return }
        companionManager.startAttachedAgent(
            prompt: prompt,
            workspaceURL: folderURL
        )
        attachedPromptText = ""
        isShowingAttachedPrompt = false
        attachedFolderURL = nil
    }
}

private struct AgentRunCard: View {
    let run: AgentRun
    let onCancel: () -> Void
    let onApprove: () -> Void
    let onDeny: () -> Void
    let onApprovePlan: () -> Void
    let onDismissPlan: () -> Void
    let onOpenFolder: () -> Void

    var body: some View {
        let projectColor = Color(
            hue: AgentFilament.stableHue(forFolderSlug: run.workspaceURL.lastPathComponent),
            saturation: 0.64,
            brightness: 0.92
        )

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.title)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                Spacer()
                Text(run.executor.displayName)
                    .font(DS.Fonts.keycap)
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(DS.Colors.surface3.opacity(0.6))
                    )
            }

            HStack(spacing: 6) {
                DSStatusDot(color: statusColor)
                Text(statusLabel)
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(statusColor)
                if !run.status.isTerminal && run.status != .awaitingPlanApproval {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedLabel(at: context.date))
                            .font(DS.Fonts.numeric)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }

            Text(subtitle)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(3)

            // A plan hanging off the camera housing gets a preview and a
            // decision, not the full text — "Ask for changes" lives in the
            // window, where there is room to type.
            if run.status == .awaitingPlanApproval, !run.planText.isEmpty {
                Text(run.planText)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textPrimary.opacity(0.85))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsSurface(.inset)
            }

            HStack(spacing: 8) {
                switch run.status {
                case .running, .queued, .planning:
                    cardButton("Cancel", action: onCancel)
                case .awaitingPlanApproval:
                    cardButton("Approve plan", isProminent: true, action: onApprovePlan)
                    cardButton("Dismiss", action: onDismissPlan)
                case .waitingForApproval:
                    cardButton("Approve", isProminent: true, action: onApprove)
                    cardButton("Deny", action: onDeny)
                case .succeeded, .failed, .cancelled:
                    cardButton("Open folder", action: onOpenFolder)
                }
                Spacer()
            }
        }
        .padding(12)
        // The project's own hue washes in from the corner so runs in the
        // same folder read as siblings; the card itself is the standard one.
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [projectColor.opacity(0.14), .clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
        )
        .dsSurface(.card)
    }

    private var statusLabel: String {
        switch run.status {
        case .queued: return "Queued"
        case .planning: return "Planning"
        case .awaitingPlanApproval: return "Read the plan"
        case .running: return "Running"
        case .waitingForApproval: return "Needs approval"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        DS.Colors.agentStatus(run.status)
    }

    private var subtitle: String {
        if run.status == .failed, !run.error.isEmpty { return run.error }
        if !run.latestAction.isEmpty { return run.latestAction }
        if !run.summary.isEmpty { return run.summary }
        return run.prompt
    }

    private func elapsedLabel(at now: Date) -> String {
        let start = run.startedAt ?? run.createdAt
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    private func cardButton(_ title: String, isProminent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .dsCapsuleButtonStyle(isProminent ? .primary : .secondary)
    }
}

// MARK: - Buddy Hero (status card)

/// The buddy's home on the Home tab: its mark, what it is doing right now,
/// and the mic waveform while it listens. Sits on a soft wash of the theme
/// color — the one tinted surface on the card, so the eye starts here.
private struct NotchStatusCard: View {
    @ObservedObject var companionManager: CompanionManager

    /// Idle and no agent running: nothing is happening, so the card that
    /// would normally announce "Ready when you are" with a glow and a
    /// 38pt mark shrinks to one quiet line. That frees the weight in this
    /// column for the composer below it, which is the thing idle actually
    /// wants you to look at.
    private var isQuiet: Bool {
        !companionManager.isForegroundAgentActive && companionManager.voiceState == .idle
    }

    var body: some View {
        if isQuiet {
            quietRow
        } else {
            activeCard
        }
    }

    private var quietRow: some View {
        // Readiness already shows in the header pill, so this line is just
        // the talk hint — a mic glyph instead of a second green dot.
        HStack(spacing: 7) {
            Image(systemName: "mic.fill")
                .font(DS.Glyph.micro)
                .foregroundColor(DS.Colors.accentText)
            Text(statusSubtitle)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var activeCard: some View {
        HStack(spacing: 12) {
            BrandAppIcon(size: 38, state: companionManager.voiceState)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(DS.Fonts.titleCompact)
                    .foregroundColor(DS.Colors.textPrimary)

                if companionManager.voiceState == .listening {
                    NotchWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                        .frame(height: 14)
                } else {
                    Text(statusSubtitle)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if companionManager.voiceState == .listening {
                Button(action: { companionManager.finishVoiceInputFromNotch() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(DS.Glyph.micro)
                        Text("Stop")
                    }
                }
                .dsCapsuleButtonStyle(.primary)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Stop listening (Escape)")
                .accessibilityLabel("Stop listening")
                .accessibilityHint("Press Escape")
            }
        }
        .padding(12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.9))
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [DS.Colors.accent.opacity(0.28), Color.clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 190
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.22), lineWidth: 0.7)
        )
    }

    private var statusTitle: String {
        if companionManager.isForegroundAgentActive {
            return "Agent running"
        }
        switch companionManager.voiceState {
        case .idle: return "Ready when you are"
        case .listening: return "Listening…"
        case .processing: return "Thinking…"
        case .responding: return "Responding…"
        }
    }

    private var statusSubtitle: String {
        if companionManager.isForegroundAgentActive {
            return companionManager.agentRuns.first(where: { !$0.status.isTerminal })?.latestAction
                ?? "Working in a project folder."
        }
        switch companionManager.voiceState {
        case .idle:
            return "Hold \(companionManager.talkShortcutOption.displayText) and ask about anything on your screen."
        case .listening:
            return "Speak freely — release keys or press Escape to stop."
        case .processing:
            return "Reading the screen and your question."
        case .responding:
            return "Answering out loud."
        }
    }
}

// MARK: - Shared controls

private struct NotchToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary.opacity(0.85))
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
        }
    }
}


private struct NotchPermissionRow: View {
    let label: String
    let iconName: String
    let isGranted: Bool
    var subtitle: String? = nil
    let grantAction: () -> Void
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: iconName)
                .font(DS.Glyph.regular)
                .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warningText)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    DSStatusDot(color: DS.Colors.success)
                    Text("Granted")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button("Grant", action: grantAction)
                        .dsCapsuleButtonStyle(.primary)

                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .dsCapsuleButtonStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}


// MARK: - Section Header

/// Kept under the old name so every notch surface shares the friendly
/// sentence-case label — see `DSSectionLabel` for the style itself.
struct NotchSectionHeader: View {
    let title: String

    var body: some View {
        DSSectionLabel(title: title)
    }
}

// MARK: - Waveform

/// Five-bar reactive meter for the status card (larger sibling of the idle
/// pill's compact waveform). Heights follow mic power only — a 24 fps
/// `TimelineView` here would re-layout the whole Home card while listening.
private struct NotchWaveformView: View {
    let audioPowerLevel: CGFloat

    private static let barWeights: [CGFloat] = [0.45, 0.8, 1.0, 0.75, 0.4]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(Self.barWeights.enumerated()), id: \.offset) { _, weight in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 3, height: barHeight(forWeight: weight))
            }
        }
        .animation(.easeOut(duration: 0.09), value: audioPowerLevel)
    }

    private func barHeight(forWeight weight: CGFloat) -> CGFloat {
        let reactive = min(max(audioPowerLevel - 0.01, 0), 1) * 12
        return 4 + reactive * weight
    }
}
