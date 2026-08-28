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

/// The two surfaces of the expanded card. Agents lists live headless jobs.
enum NotchExpandedTab: String, CaseIterable, Identifiable {
    case home
    case agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .agents: return "Agents"
        }
    }

    var iconName: String {
        switch self {
        case .home: return "house"
        case .agents: return "sparkles"
        }
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
    @State private var isShowingSettings = false
    @State private var isShowingAboutPopover = false
    @State private var isModelPickerOpen = false

    var body: some View {
        // Lay out at the destination card size and let AppKit clip during the
        // pill→card morph. A GeometryReader that both measured and set frame
        // fought the hosting view on every outline-glow tick.
        cardBody
            .frame(
                width: layoutSize.width > 0 ? layoutSize.width : nil,
                height: layoutSize.height > 0 ? layoutSize.height : nil,
                alignment: .top
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
    }

    private var cardBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: occludedTopInset)

            headerRow
                .padding(.horizontal, 16)
                .padding(.top, 10)

            VStack(spacing: 0) {
                if isShowingSettings {
                    AISettingsView(companionManager: companionManager)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if isModelPickerOpen {
                    NotchModelPickerPanel(companionManager: companionManager)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    NotchTabSwitcher(selectedTab: $selectedTab)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)

                    Group {
                        switch selectedTab {
                        case .home:
                            NotchHomeTab(
                                companionManager: companionManager,
                                isModelPickerOpen: $isModelPickerOpen
                            )
                        case .agents:
                            NotchAgentsTab(companionManager: companionManager)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }

                footerRow
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
            }
            .animation(.easeInOut(duration: 0.2), value: isShowingSettings)
            .animation(.easeInOut(duration: 0.2), value: isModelPickerOpen)
            .onChange(of: companionManager.shouldRevealAgentsTab) { _, shouldReveal in
                if shouldReveal {
                    selectedTab = .agents
                    companionManager.shouldRevealAgentsTab = false
                }
            }
            .onAppear {
                if companionManager.shouldRevealAgentsTab {
                    selectedTab = .agents
                    companionManager.shouldRevealAgentsTab = false
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(NotchLiquidGlassCardModifier(transitionModel: transitionModel, occludedTopInset: occludedTopInset))
        .overlay(alignment: .top) {
            if companionManager.isNotchOutlineEnabled, occludedTopInset >= 20, hardwareNotchWidth > 0 {
                NotchOutlineGlow(
                    color: companionManager.themeColor,
                    cornerRadius: NotchLayoutMath.pillCornerRadius(forHeight: occludedTopInset)
                )
                    .frame(width: hardwareNotchWidth, height: occludedTopInset)
            }
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            if isShowingSettings {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isShowingSettings = false
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(DS.Colors.surface3))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Back")
            } else {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)
                    .animation(.easeInOut(duration: 0.2), value: companionManager.voiceState)
            }

            Text(isShowingSettings ? "Models" : "heymate")
                .font(DS.Fonts.titleCompact)
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            Text(isShowingSettings ? "Brain & audio" : headerStatusText)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)

            Button(action: onClose) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(DS.Colors.surface3))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Collapse")
        }
    }

    private var statusDotColor: Color {
        switch companionManager.voiceState {
        case .idle: return DS.Colors.success
        case .listening: return DS.Colors.warning
        case .processing, .responding: return DS.Colors.overlayCursorBlue
        }
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

    // MARK: Footer

    /// Version, what this thing is, and the way out to help. Small on
    /// purpose — anything longer belongs in the window.
    private var notchAboutPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HeyMate")
                .font(.system(size: 13, weight: .semibold))
            Text("Version \(AppUpdateController.shared.displayedVersion)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("A notch companion that can see your screen, talk back, and run coding agents in ~/Projects/heymate.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 240, alignment: .leading)

            Divider()

            Button("Check for updates") {
                AppUpdateController.shared.checkForUpdates()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .pointerCursor()
            .disabled(!AppUpdateController.shared.canCheckForUpdates)

            ForEach(SupportLinks.destinations) { destination in
                Button(destination.title) { SupportLinks.open(destination) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .pointerCursor()
            }
        }
        .padding(14)
    }

    private var footerRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isShowingSettings = false
                        isModelPickerOpen = true
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10, weight: .medium))
                        Text(companionManager.activeEngineDisplayName)
                            .font(DS.Fonts.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.surface3.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Choose engine and model")

                Spacer()

                // Hand off to the full app. The notch is for glanceable work;
                // anything that needs a list, a catalog, or a long transcript
                // belongs in a real window.
                footerIconButton(systemName: "macwindow", help: "Open the HeyMate window") {
                    companionManager.openDesktopWindow(section: .chat)
                }

                footerIconButton(
                    systemName: "gearshape",
                    help: isShowingSettings ? "Back to Home" : "Models",
                    isActive: isShowingSettings
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isShowingSettings.toggle()
                    }
                }

                if !isShowingSettings {
                    NotchCursorDock(companionManager: companionManager)
                }

                footerIconButton(systemName: "info.circle", help: "About HeyMate") {
                    isShowingAboutPopover.toggle()
                }
                .accessibilityLabel("About HeyMate")
                .popover(isPresented: $isShowingAboutPopover, arrowEdge: .bottom) {
                    notchAboutPopover
                }

                footerIconButton(systemName: "power", help: "Quit HeyMate") {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// The footer's small round utility buttons, all one temperature.
    private func footerIconButton(
        systemName: String,
        help: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(isActive ? DS.Colors.surface4 : DS.Colors.surface3.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }
}

// MARK: - Tab Switcher

private struct NotchTabSwitcher: View {
    @Binding var selectedTab: NotchExpandedTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NotchExpandedTab.allCases) { tab in
                tabButton(for: tab)
            }
            Spacer()
        }
    }

    private func tabButton(for tab: NotchExpandedTab) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: {
            withAnimation(DS.Animation.controlSpring) { selectedTab = tab }
        }) {
            HStack(spacing: 5) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 10, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected ? DS.Colors.accentSubtle : Color.clear)
            )
            .overlay(
                Capsule().stroke(
                    isSelected ? DS.Colors.accent.opacity(0.35) : Color.white.opacity(0.001),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Home Tab

private struct NotchHomeTab: View {
    @ObservedObject var companionManager: CompanionManager
    @Binding var isModelPickerOpen: Bool

    @State private var typedMessageInput = ""

    private var needsSetup: Bool {
        !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted
    }

    var body: some View {
        // The card is a fixed height and the Home content is short, so the
        // zones are spaced out across the pane instead of stacking at the
        // top and leaving a dead void above the footer. The GeometryReader
        // only measures the viewport to set a min-height — the content
        // still scrolls when it genuinely overflows.
        GeometryReader { viewport in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if needsSetup {
                        setupCopySection
                        if !companionManager.allPermissionsGranted {
                            permissionsSection
                        }
                        startButton
                    } else {
                        // The buddy's face card, in the order you'd want it:
                        // the buddy and its state, the way to talk to it, what
                        // is happening right now, and the doors out to the
                        // window. Configuration (shortcuts, skills, connectors)
                        // lives behind those doors in the HeyMate window — a
                        // card hanging off the camera is the wrong place to
                        // browse a settings list.
                        NotchStatusCard(companionManager: companionManager)
                        typedMessageInputRow
                        ContextualConnectorSuggestionBanner(companionManager: companionManager)
                        Spacer(minLength: 2)
                        NotchTrayStrip(
                            activityCenter: companionManager.notchActivityCenter,
                            onOpenDesktop: { section in
                                companionManager.openDesktopWindow(section: section)
                            }
                        )
                        Spacer(minLength: 2)
                        doorsRow
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(minHeight: viewport.size.height - 20, alignment: .top)
            }
        }
    }

    // MARK: Setup

    @ViewBuilder
    private var setupCopySection: some View {
        if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet HeyMate.")
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
                    BuddyMark(size: .standard, color: companionManager.themeColor)
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
                    NotchToggleRow(label: "Notch outline", isOn: $companionManager.isNotchOutlineEnabled)
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
            Button(action: { companionManager.triggerOnboarding() }) {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
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
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .padding(.leading, 14)
                .onSubmit(sendTypedMessageFromInput)

            Button(action: sendTypedMessageFromInput) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
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
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.85))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .opacity(companionManager.canAcceptTypedAgentTask ? 1 : 0.45)
        .disabled(!companionManager.canAcceptTypedAgentTask)
    }

    /// Command results and the /memory clear confirmation. Rendered under the
    /// input rather than spoken, because a command is a UI action and reading
    /// "no such command" aloud would be absurd.
    @ViewBuilder
    private var commandBarFeedbackRow: some View {
        if companionManager.pendingMemoryClearConfirmation {
            HStack(spacing: 8) {
                Text("Delete everything HeyMate remembers?")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 8)
                Button("Cancel") { companionManager.cancelPendingMemoryClear() }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                Button("Delete") { companionManager.confirmPendingMemoryClear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.destructiveText)
                    .pointerCursor()
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
    /// a list or a form, which is exactly what a 420-point card hanging
    /// off a camera housing is worst at. Those live in the window now;
    /// this row is the door.
    private var doorsRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            DSSectionLabel(title: "Doors")

            HStack(spacing: 7) {
                doorTile(
                    title: "Agents",
                    systemName: "sparkles",
                    help: "See running and finished agent jobs"
                ) {
                    companionManager.shouldRevealAgentsTab = true
                }
                doorTile(
                    title: "Window",
                    systemName: "macwindow",
                    help: "Open the full HeyMate window"
                ) {
                    companionManager.openDesktopWindow(section: .chat)
                }
                doorTile(
                    title: "Skills",
                    systemName: "wand.and.stars",
                    help: "Markdown files that shape how HeyMate answers"
                ) {
                    companionManager.openDesktopWindow(section: .skills)
                }
                doorTile(
                    title: "Settings",
                    systemName: "gearshape",
                    help: "Engine, model, voice, shortcuts, and appearance"
                ) {
                    companionManager.openDesktopWindow(section: .settings)
                }
            }
        }
    }

    private func doorTile(
        title: String,
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.92, green: 0.12, blue: 0.14))
                        .frame(width: 30, height: 30)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
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
                    suggestionButton("No", color: DS.Colors.textTertiary) {
                        suggestionMonitor.declinePermanently(suggestion)
                    }
                    suggestionButton("Not now", color: DS.Colors.textSecondary) {
                        suggestionMonitor.snooze(suggestion)
                    }
                    suggestionButton("Connect", color: DS.Colors.accent) {
                        connect(suggestion)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DS.Colors.accent.opacity(0.24), lineWidth: 0.7)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Connect \(suggestion.toolkitName) to HeyMate")
        }
    }

    private func suggestionButton(
        _ title: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(title == "Connect" ? DS.Colors.textOnAccent : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(title == "Connect" ? color : color.opacity(0.12)))
            .pointerCursor()
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                if let proposal = companionManager.standingOrderProposal {
                    standingOrderProposalCard(proposal)
                }
                composeCard
                if isShowingAttachedPrompt {
                    attachedPromptCard
                }
                if !companionManager.agentRevealErrorText.isEmpty {
                    Text(companionManager.agentRevealErrorText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.warning)
                }
                agentList
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    private func standingOrderProposalCard(_ proposal: StandingOrderProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Standing Order", systemImage: "bell.badge.fill")
                .font(.system(size: 10, weight: .bold, design: .rounded))
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
            HStack(spacing: 10) {
                Button("Plan it") { companionManager.approveStandingOrderProposal() }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.accentText)
                    .pointerCursor()
                Button("Dismiss") { companionManager.dismissStandingOrderProposal() }
                    .font(DS.Fonts.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DS.Colors.warning.opacity(0.30), lineWidth: 1)
        )
    }

    private var composeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Runs with \(companionManager.selectedBrain.displayName). Change that in Settings → Brain.")
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textTertiary)

            HStack(spacing: 8) {
            TextField("What should the agent build?", text: $sandboxPromptText)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .onSubmit(startSandbox)

                Button(action: startSandbox) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(sandboxPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button(action: pickAttachedFolder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                    Text("Run in folder…")
                        .font(DS.Fonts.caption)
                    Spacer()
                }
                .foregroundColor(DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.72))
        )
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
                Button("Run", action: startAttached)
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.accentText)
                    .pointerCursor()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.72))
        )
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
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(DS.Colors.surface3.opacity(0.6))
                    )
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: statusColor.opacity(0.5), radius: 3)
                Text(statusLabel)
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(statusColor)
                if !run.status.isTerminal && run.status != .awaitingPlanApproval {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedLabel(at: context.date))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
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
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(DS.Colors.surface3.opacity(0.5))
                    )
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [projectColor.opacity(0.16), DS.Colors.surface2.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(projectColor.opacity(0.24), lineWidth: 0.7)
        )
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
        switch run.status {
        case .queued: return DS.Colors.textTertiary
        case .running, .planning: return DS.Colors.accentText
        case .awaitingPlanApproval, .waitingForApproval: return DS.Colors.warningText
        case .succeeded: return DS.Colors.success
        case .failed: return DS.Colors.warningText
        case .cancelled: return DS.Colors.textTertiary
        }
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
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(isProminent ? DS.Colors.textOnAccent : DS.Colors.textPrimary.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isProminent ? DS.Colors.accent : DS.Colors.surface3)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Buddy Hero (status card)

/// The buddy's home on the Home tab: its mark, what it is doing right now,
/// and the mic waveform while it listens. Sits on a soft wash of the theme
/// color — the one tinted surface on the card, so the eye starts here.
private struct NotchStatusCard: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(spacing: 12) {
            BuddyMark(
                size: .standard,
                state: companionManager.voiceState,
                color: companionManager.themeColor
            )

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
                            .font(.system(size: 7, weight: .bold))
                        Text("Stop")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .keyboardShortcut(.escape, modifiers: [])
                .help("Stop listening (Escape)")
                .accessibilityLabel("Stop listening")
                .accessibilityHint("Press Escape")
            }
        }
        .padding(12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.9))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
                .font(.system(size: 12, weight: .medium))
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
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: grantAction) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.Colors.accent))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    if let secondaryTitle, let secondaryAction {
                        Button(action: secondaryAction) {
                            Text(secondaryTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().stroke(DS.Colors.borderStrong, lineWidth: 0.8)
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
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
