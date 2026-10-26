//
//  NotchExpandedView.swift
//  HeyMate
//
//  The expanded notch card: hovering or clicking the notch tab drops this
//  Home/Agents surface below the camera housing. This is
//  the app's only control surface — permissions, typed input, shortcuts,
//  engine, memory, and privacy all live here. The menu-bar panel is gone.
//

import AVFoundation
import SwiftUI

// MARK: - Tabs

/// Primary surfaces in the expanded card. Apps owns ambient notch tools.
/// Agent jobs have no tab of their own: unfinished ones show on Home, and
/// each belongs to the mate chat that asked for it.
enum NotchExpandedTab: String, CaseIterable, Identifiable {
    case home
    case apps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .apps: return "Usage"
        }
    }

    var iconName: String {
        switch self {
        case .home: return "house"
        case .apps: return "gauge.with.needle"
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
    static let compactControlSize: CGFloat = 24
    static let glyphSize: CGFloat = 13
    static let labelSize: CGFloat = 12
    /// One regular control plus a 4pt margin above and below it.
    static let bottomBarHeight: CGFloat = DS.ControlSize.regular + 12
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
                    .fill(isHovering ? DS.Colors.notchHoverFill : Color.clear)
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
            .buttonStyle(NotchCapsuleControlStyle(isProminent: isProminent))
    }
}

// MARK: - Soft controls

/// Shape of a soft notch control's hover fill.
enum NotchSoftShape {
    case circle
    case capsule
    case rounded
}

/// The notch's one button look: no tile, no outline. The label floats on
/// the bezel black and only a low-opacity white fill appears on hover,
/// press, or while `isActive`, so the card reads as the notch expanded,
/// not a panel of boxes.
struct NotchSoftButtonStyle: ButtonStyle {
    var shape: NotchSoftShape = .capsule
    var isActive = false
    /// Fill used while active instead of the neutral selected white, for a
    /// control whose "on" state is the accent (the deployed buddy).
    var activeFill: Color? = nil
    /// A resting fill for a soft button that must read as pressable before
    /// it is hovered (timer presets). Hover lifts it one step.
    var restFill: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        NotchSoftButtonBody(
            configuration: configuration,
            shape: shape,
            isActive: isActive,
            activeFill: activeFill,
            restFill: restFill
        )
    }
}

private struct NotchSoftButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let shape: NotchSoftShape
    let isActive: Bool
    let activeFill: Color?
    let restFill: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .background(fillShape)
            .contentShape(contentShape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 && isEnabled }
            .pointerCursor(isEnabled: isEnabled)
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: isHovering)
    }

    private var fill: Color {
        if configuration.isPressed { return DS.Colors.notchPressedFill }
        if isActive { return activeFill ?? DS.Colors.notchSelectedFill }
        if let restFill { return isHovering ? DS.Colors.notchSelectedFill : restFill }
        return isHovering ? DS.Colors.notchHoverFill : .clear
    }

    @ViewBuilder
    private var fillShape: some View {
        switch shape {
        case .circle: Circle().fill(fill)
        case .capsule: Capsule(style: .continuous).fill(fill)
        case .rounded:
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous).fill(fill)
        }
    }

    private var contentShape: AnyShape {
        switch shape {
        case .circle: return AnyShape(Circle())
        case .capsule: return AnyShape(Capsule(style: .continuous))
        case .rounded: return AnyShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
    }
}

extension View {
    /// See `NotchSoftButtonStyle`.
    func notchSoftButtonStyle(
        _ shape: NotchSoftShape = .capsule,
        isActive: Bool = false,
        activeFill: Color? = nil,
        restFill: Color? = nil
    ) -> some View {
        buttonStyle(NotchSoftButtonStyle(
            shape: shape,
            isActive: isActive,
            activeFill: activeFill,
            restFill: restFill
        ))
    }

    /// Fades a horizontally scrolling row out at both ends instead of
    /// cutting it hard. Pair with content padded by the same `width`, so at
    /// rest the fade only covers the margin and nothing legible.
    func notchHorizontalEdgeFade(width: CGFloat = DS.Spacing.lg) -> some View {
        mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
            }
        }
    }
}

// MARK: - Root

struct NotchExpandedView: View {
    @AppStorage(MateEngine.preferenceKey) private var mateEngine = MateEngine.selected().rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    @ObservedObject private var activityCenter: NotchActivityCenter
    private let permissionGuide: PermissionGuide
    @State private var selectedTab: NotchExpandedTab
    @State private var isShowingAboutPopover = false

    init(
        companionManager: CompanionManager,
        occludedTopInset: CGFloat = 0,
        layoutSize: CGSize = .zero,
        hardwareNotchWidth: CGFloat = 0,
        transitionModel: NotchSurfaceTransitionModel,
        initialTab: NotchExpandedTab = .apps,
        permissionGuide: PermissionGuide = .shared,
        onClose: @escaping () -> Void
    ) {
        self.companionManager = companionManager
        self.occludedTopInset = occludedTopInset
        self.layoutSize = layoutSize
        self.hardwareNotchWidth = hardwareNotchWidth
        self.transitionModel = transitionModel
        self.onClose = onClose
        self.activityCenter = companionManager.notchActivityCenter
        self.permissionGuide = permissionGuide
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        // Background follows live hosting-view bounds. Destination-sized
        // controls stay top-centred underneath and reveal only after the
        // unified silhouette has substantially formed.
        GeometryReader { viewport in
            let size = transitionModel.effectiveLayoutSize(layoutSize, viewport: viewport.size)
            let contentWidth = size.width
            let contentHeight = size.height

            cardBody
                .frame(width: contentWidth, height: contentHeight, alignment: .top)
                .modifier(NotchContentRevealModifier(transitionModel: transitionModel))
                .position(x: viewport.size.width / 2, y: contentHeight / 2)
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
                    if activityCenter.shelfPresentation.isVisible {
                        NotchShelfMouthView(center: activityCenter, shelf: activityCenter.shelfStore)
                    } else {
                        switch selectedTab {
                        case .home: NotchHomeTab(companionManager: companionManager, permissionGuide: permissionGuide)
                        case .apps: NotchUsageView(companionManager: companionManager)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            // Agent work that needs you shows on Home.
            .onChange(of: companionManager.shouldRevealAgentsTab) { _, shouldReveal in
                if shouldReveal {
                    selectedTab = .home
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
                    selectedTab = .home
                    companionManager.shouldRevealAgentsTab = false
                } else if companionManager.shouldRevealAppsTab {
                    selectedTab = .apps
                    companionManager.shouldRevealAppsTab = false
                }
            }

            bottomActionBar
                .frame(height: NotchControlMetrics.bottomBarHeight)
        }
        // The body sits inside the concave shoulders; only the bezel black
        // reaches the window's sides.
        .padding(.horizontal, NotchLayoutMath.shoulderInset(occludedTopInset: occludedTopInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            BrandNebulaSurface.notchCard
        }
    }

    // MARK: Header

    private var notchWingHeader: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                NotchTabSwitcher(selectedTab: Binding(get: { selectedTab }, set: {
                    activityCenter.shelfPresentation = .hidden
                    selectedTab = $0
                }))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.black)
                .frame(width: max(hardwareNotchWidth, 0))
                .accessibilityHidden(true)

            // Status, collapse and quit live on the right wing so the bottom
            // bar only carries tools, and neither wing reads as an empty box.
            // Quit takes the top-right corner — there is no Dock icon or
            // menu bar to quit from otherwise.
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                headerStatusPill
                headerIconButton(systemName: "chevron.up", help: "Collapse", action: onClose)
                headerIconButton(systemName: "power", help: "Quit HeyMate") {
                    NSApp.terminate(nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        // Pure black, same as the camera housing and the card fill — the
        // old chrome tint drew two visible boxes either side of the notch.
        .background(Color.black)
    }

    private var headerStatusPill: some View {
        HStack(spacing: 6) {
            DSStatusDot(color: statusDotColor, size: 5)
            Text(headerStatusText)
                .font(DS.Fonts.control)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: NotchControlMetrics.compactControlSize)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: companionManager.voiceState)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(headerStatusText)")
    }

    /// Every way out of the card in one row: the engine, the three
    /// window pages, the buddy, and About. Status, collapse and quit live
    /// on the header's right wing.
    private var bottomActionBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            engineChip
            doorButtons

            Spacer(minLength: 0)

            NotchCursorDock(companionManager: companionManager)

            headerIconButton(systemName: "info.circle", help: "About HeyMate") {
                isShowingAboutPopover.toggle()
            }
            .disclosureSound(isShowingAboutPopover, .popover)
            .popover(isPresented: $isShowingAboutPopover, arrowEdge: .bottom) {
                notchAboutPopover
            }
        }
        // 16pt matches the content columns and keeps the end controls clear
        // of the card's 24pt bottom corners. No divider above it: the bar
        // is set apart by spacing alone, like the rest of the card.
        .padding(.horizontal, DS.Spacing.lg)
    }

    /// Window, Integrations and Settings as one grouped icon row. They used
    /// to be three tall tiles; the names live in the tooltips and the
    /// ⌘1–⌘3 shortcuts still work.
    private var doorButtons: some View {
        HStack(spacing: 2) {
            Button {
                companionManager.openDesktopWindow(section: .chat)
            } label: {
                Label("Open chat", systemImage: "bubble.left.and.bubble.right")
            }
            .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.regular)
            .keyboardShortcut("1", modifiers: .command)
            .help("Open chats, mates, and the character editor")
            .accessibilityLabel("Open chat and characters")
            doorButton(title: "Integrations", systemName: "puzzlepiece.extension", detail: "apps every agent can use", key: "2") {
                companionManager.openDesktopWindow(section: .connectors)
            }
            doorButton(title: "Settings", systemName: "gearshape", detail: "engine, voice, shortcuts, appearance", key: "3") {
                companionManager.openDesktopWindow(section: .settings)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.035)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.075), lineWidth: 0.5))
    }

    private func doorButton(
        title: String,
        systemName: String,
        detail: String,
        key: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Glyph.regular)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(
                    width: NotchControlMetrics.controlSize,
                    height: NotchControlMetrics.controlSize
                )
        }
        .notchSoftButtonStyle(.circle)
        .keyboardShortcut(key, modifiers: .command)
        .help("\(title): \(detail) (⌘\(key.character))")
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    /// Names the engine instead of hiding it behind a bare CPU glyph — which
    /// brain answers is the one setting people check most.
    private var engineChip: some View {
        Button(action: {
            companionManager.openDesktopWindow(section: .settings)
            DesktopSection.openSettings(tab: DesktopSettingsTab.agents.rawValue)
        }) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.accentText)
                Text(mateEngine == MateEngine.hermes.rawValue ? "Hermes" : companionManager.selectedBrain.displayName)
                    .font(DS.Fonts.control)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(DS.Glyph.micro)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: NotchControlMetrics.controlSize)
            .background(Capsule().fill(Color.white.opacity(0.035)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.075), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(NotchDoorButtonStyle())
        .pointerCursor()
        .help(mateEngine == MateEngine.hermes.rawValue ? "Hermes model access and skills" : "Choose engine, model, and effort in Settings")
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
                .contentShape(Circle())
        }
        .buttonStyle(NotchDoorButtonStyle())
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }

    private var statusDotColor: Color {
        if !companionManager.hasCompletedOnboarding {
            return DS.Colors.warning
        }
        return DS.Colors.voiceStatus(companionManager.voiceState)
    }

    private var headerStatusText: String {
        if !companionManager.hasCompletedOnboarding {
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

struct NotchTabSwitcher: View {
    @Binding var selectedTab: NotchExpandedTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs(showsIcons: true)
            tabs(showsIcons: false)
        }
    }

    private func tabs(showsIcons: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(NotchExpandedTab.allCases) { tab in
                tabButton(for: tab, showsIcon: showsIcons)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.035)))
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Both names stay visible. Narrow wings drop icons, never tab labels.
    private func tabButton(for tab: NotchExpandedTab, showsIcon: Bool) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { selectedTab = tab }
        }) {
            HStack(spacing: 5) {
                if showsIcon {
                    Image(systemName: tab.iconName).font(DS.Glyph.regular)
                }
                Text(tab.title)
                    .font(showsIcon ? DS.Fonts.control : .system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, showsIcon ? 8 : 4)
            .frame(minWidth: 36, minHeight: NotchControlMetrics.compactControlSize)
            .foregroundColor(isSelected ? Color(hex: "#12223B") : DS.Colors.textSecondary)
            .background {
                if isSelected { DSGlassSurface(cornerRadius: 12) }
            }
            .contentShape(Capsule())
        }
        .notchSoftButtonStyle(.capsule, isActive: isSelected)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("notch-tab-\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Home Tab

private struct NotchHomeTab: View {
    @ObservedObject var companionManager: CompanionManager
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var typedMessageInput = ""
    @FocusState private var isComposerFocused: Bool
    @ObservedObject var permissionGuide: PermissionGuide

    private var needsSetup: Bool {
        !companionManager.hasCompletedOnboarding
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
                        setupCopySection
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                        // Setup itself happens in the welcome tour window;
                        // the notch only points back to it.
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Finish the welcome tour")
                                .font(DS.Fonts.headline)
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Permissions, your AI, and a quick hello. A few minutes, and you can skip any time.")
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Continue the tour") { companionManager.openWelcomeTour() }
                                .buttonStyle(NotchCapsuleControlStyle())
                            // Optional: HeyMate works with the Mac voice
                            // straight away, so this is an offer, not a step.
                            if OnDeviceVoiceModelStore.shared.isSupportedOnThisMac {
                                VStack(alignment: .leading, spacing: 8) {
                                    NotchSectionHeader(title: "Voice")
                                    OnDeviceVoiceDownloadRow(
                                        companionManager: companionManager,
                                        isCompact: true
                                    )
                                }
                                .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: viewport.size.height, alignment: .top)
                }
            } else {
                // Composer on the left, agents on the right. The composer
                // comes first so it never scrolls out of sight; notes and
                // jobs that need you stack under it. Doors live in the
                // bottom bar.
                // The ask box grows to the column's full height when
                // nothing is stacked under it, so the left half is never a
                // short field over empty black; with notes or jobs below it
                // shrinks back to one line and the column scrolls.
                let columnHeight = max(viewport.size.height - DS.Spacing.sm * 2, 0)
                HStack(alignment: .top, spacing: DS.Spacing.lg) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            if !shortcutsAreOff {
                                NotchStatusCard(companionManager: companionManager)
                            }
                            typedMessageInputRow
                            missingPermissionNote
                            NotchSubscriptionSignInBanner(signIn: companionManager.subscriptionSignIn)
                            ContextualConnectorSuggestionBanner(companionManager: companionManager)
                            unfinishedAgentCards
                        }
                        .frame(minHeight: columnHeight, alignment: .top)
                    }
                    .frame(width: (viewport.size.width - DS.Spacing.lg * 3) / 2)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            NotchMatesPeek(companionManager: companionManager, limit: 2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.sm)
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
            }
        }
        .onAppear { permissionGuide.startWatching() }
        .onDisappear { permissionGuide.stopWatching() }
    }

    // MARK: Missing permissions

    /// Core permissions that are off, the ones that kill shortcuts first.
    private var missingPermissions: [HeyMatePermission] {
        let off = HeyMatePermission.core.filter { !permissionGuide.isGranted($0) }
        return off.filter(\.breaksShortcuts) + off.filter { !$0.breaksShortcuts }
    }

    /// The talk hint says "hold ctrl + option", which is a lie while the
    /// permission behind shortcuts is off, so the note replaces it.
    private var shortcutsAreOff: Bool {
        missingPermissions.first?.breaksShortcuts == true
    }

    /// One compact route to the complete permission checklist. The warning
    /// must fit below the composer even in the minimum-height notch card.
    @ViewBuilder
    private var missingPermissionNote: some View {
        if let first = missingPermissions.first {
            Button {
                UserDefaults.standard.set(DesktopSettingsTab.permissions.rawValue,
                                          forKey: DesktopSettingsTab.storageKey)
                companionManager.openDesktopWindow(section: .settings)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: first.systemImage).foregroundStyle(DS.Colors.warningText)
                    ViewThatFits(in: .horizontal) {
                        Text(first.breaksShortcuts ? "Keyboard shortcuts are off" : first.offText)
                        Text(first.breaksShortcuts ? "Enable shortcuts" : "Permissions needed")
                    }
                    .font(DS.Fonts.caption.weight(.semibold))
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large).fill(DS.Colors.notchWellFill))
            }
            .buttonStyle(.plain)
            .help(permissionNoteHelp(for: first))
            .accessibilityLabel("\(first.breaksShortcuts ? "Keyboard shortcuts are off" : first.offText). Open permission settings")
        }
    }

    private func permissionNoteHelp(for permission: HeyMatePermission) -> String {
        var lines: [String] = []
        if permission.breaksShortcuts {
            lines.append("HeyMate needs \(permission.title) to hear ⌃⌥ and your other shortcuts.")
        }
        if let hint = permission.settingsHint { lines.append(hint) }
        return lines.joined(separator: " ")
    }

    // MARK: Setup

    @ViewBuilder
    private var setupCopySection: some View {
        if companionManager.hasCompletedOnboarding {
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
                // Written out in light once per launch as the notch opens.
                HeyMateHelloTrace()
                    .frame(width: 70, height: 50, alignment: .leading)
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

    // MARK: Typed input

    private var typedMessageInputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            typedMessageComposerRow
            commandBarFeedbackRow
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// A soft well, not a capsule with a rim: the text sits top-left, the
    /// send button bottom-right, and the box fills whatever height the
    /// column gives it.
    private var typedMessageComposerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask HeyMate…", text: $typedMessageInput, axis: .vertical)
                .textFieldStyle(.plain)
                .font(isComposerHero ? DS.Fonts.headline : DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .padding(.leading, 12)
                .padding(.top, 5)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .focused($isComposerFocused)
                .onSubmit(sendTypedMessageFromInput)

            Button(action: sendTypedMessageFromInput) {
                Image(systemName: "arrow.up")
                    .font(DS.Glyph.regular.weight(.bold))
                    .foregroundColor(canSendTypedMessage ? Color(hex: "#12223B") : DS.Colors.textTertiary)
                    .frame(width: 28, height: 28)
                    .background {
                        if canSendTypedMessage {
                            DSGlassSurface(cornerRadius: 14)
                        } else {
                            Circle().fill(DS.Colors.surface3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!canSendTypedMessage)
            .help("Send — starts a coding agent in ~/Projects/heymate")
            .padding(.trailing, 5)
        }
        .padding(.vertical, DS.Spacing.xs + 1)
        .frame(minHeight: 38, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.hero, style: .continuous)
                .fill(isComposerFocused ? DS.Colors.notchSelectedFill : DS.Colors.notchWellFill)
        )
        // Focus is the one state that earns a line: a faint accent edge,
        // no glow, so the box never reads as a bordered panel at rest.
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.hero, style: .continuous)
                .stroke(isComposerFocused ? DS.Colors.accent.opacity(0.45) : .clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.hero, style: .continuous))
        .onTapGesture { isComposerFocused = true }
        .animation(.easeOut(duration: DS.Animation.fast), value: isComposerFocused)
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
        guard companionManager.sendTypedMessage(messageText, asHeyMateTalk: true) else { return }
        typedMessageInput = ""

        // A slash command's answer (the /help listing, "no such command", the
        // memory-clear confirmation) renders right here, so collapsing the
        // card would throw it away before it could be read.
        if case .message = CommandBarParser.parse(messageText) {
            // Agent jobs need the Agents tab visible. Talk dismisses so the
            // overlay can point at the screen.
            if !AgentInvocation.isAgentRequest(messageText) {
                NotificationCenter.default.post(name: .heyMateDismissPanel, object: nil)
            }
        }
    }

    // MARK: Recent agent

    /// Jobs still running or waiting on you, as full cards: this is where a
    /// plan gets read and approved from the notch, so a job that needs you
    /// comes first.
    @ViewBuilder
    private var unfinishedAgentCards: some View {
        let unfinished = companionManager.agentRuns
            .filter { !$0.status.isTerminal }
            .sorted { first, second in
                if first.status.needsUser != second.status.needsUser { return first.status.needsUser }
                return first.createdAt > second.createdAt
            }
        if !unfinished.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                DSSectionLabel(title: unfinished.contains(where: \.status.needsUser) ? "Needs you" : "Working")
                ForEach(unfinished) { run in
                    AgentRunCard(
                        run: run,
                        onCancel: { companionManager.cancelAgent(runID: run.id) },
                        onApprove: { companionManager.resolvePresentedApproval(run: run, approve: true) },
                        onDeny: { companionManager.resolvePresentedApproval(run: run, approve: false) },
                        onApprovePlan: { companionManager.approveAgentPlan(runID: run.id) },
                        onDismissPlan: { companionManager.dismissAgentPlan(runID: run.id) },
                        onOpenFolder: { companionManager.revealAgentFolder(runID: run.id) }
                    )
                    .id(run.id)
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .cueExit(.jobClosed, reduceMotion: accessibilityReduceMotion)
                    ))
                }
            }
            .animation(.cueExit(.jobClosed, reduceMotion: accessibilityReduceMotion), value: unfinished.map(\.id))
        }
    }

}

/// A borderless icon in the grouped door row. Lights up on hover and
/// press only, so the row reads as one quiet capsule at rest.
private struct NotchDoorButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NotchDoorButtonLabel(configuration: configuration)
    }
}

/// A view, not the style itself, so it can hold its own hover state.
private struct NotchDoorButtonLabel: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundColor(isHovering ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .background(
                Capsule().fill(
                    configuration.isPressed ? Color.white.opacity(0.13)
                        : isHovering ? Color.white.opacity(0.065) : Color.clear
                )
            )
            .brightness(configuration.isPressed ? -0.03 : 0)
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
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
                    ComposioToolkitLogoView(toolkit: suggestion.toolkit, compactSize: 30)

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
                        .buttonStyle(NotchCapsuleControlStyle())
                }
            }
            .padding(10)
            .dsSurface(.card)
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

// MARK: - Agent job card

private struct AgentRunCard: View {
    let run: AgentRun
    var canFollowUp: Bool = false
    var onFollowUp: ((String) -> Bool)? = nil
    let onCancel: () -> Void
    let onApprove: () -> Void
    let onDeny: () -> Void
    let onApprovePlan: () -> Void
    let onDismissPlan: () -> Void
    let onOpenFolder: () -> Void
    @State private var followUpText = ""

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
                            .fill(DS.Colors.notchWellFill)
                    )
            }

            HStack(spacing: 6) {
                DSStatusDot(color: statusColor)
                    .cueMotion(.jobNeedsYou, subject: cueSubject)
                    .background(needsYouHalo)
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

            if run.status == .waitingForApproval { AgentApprovalDetails(run: run) }

            HStack(spacing: 8) {
                switch run.status {
                case .running, .queued, .planning:
                    cardButton("Cancel", action: onCancel)
                case .awaitingPlanApproval:
                    cardButton("Approve plan", isProminent: true, action: onApprovePlan)
                    cardButton("Dismiss", action: onDismissPlan)
                case .waitingForApproval:
                    cardButton("Approve", isProminent: true, action: onApprove)
                        .cueMotion(.permissionAsk, part: .prop, subject: cueSubject)
                    cardButton("Deny", action: onDeny)
                case .succeeded, .failed, .cancelled:
                    cardButton("Open folder", action: onOpenFolder)
                }
                Spacer()
            }

            if canFollowUp {
                HStack(spacing: 8) {
                    TextField("Follow up in this thread", text: $followUpText)
                        .textFieldStyle(.plain)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                        .onSubmit(sendFollowUp)
                    cardButton("Send", isProminent: true, action: sendFollowUp)
                        .disabled(followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .accessibilityLabel("Follow up with this agent")
            }
        }
        .padding(12)
        .background(Color.black, in: RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
        .dsSurface(.card)
        .overlay { CueShimmer(subject: cueSubject).clipShape(cardShape) }
        .cueGlow(.permissionAsk, subject: cueSubject, cornerRadius: DS.CornerRadius.extraLarge)
        .overlay(alignment: .topTrailing) {
            CueProp(kind: .tapback, subject: cueSubject)
                .offset(x: 6, y: -6)
        }
        .cueMotion(.jobStarted, subject: cueSubject)
    }

    private var cueSubject: String { run.id.uuidString }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
    }

    /// The dot stays lit while the job waits on you; the needs-you cue's
    /// two pulses end on this.
    @ViewBuilder
    private var needsYouHalo: some View {
        if run.status.needsUser {
            Circle()
                .fill(statusColor.opacity(0.35))
                .frame(width: 12, height: 12)
                .blur(radius: 2)
                .cueGlowOpacity(.jobNeedsYou, subject: cueSubject)
        }
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
        // A plan whose approval could not start keeps its status, so the
        // error is the only sign the click landed.
        if run.status == .failed || run.status == .awaitingPlanApproval, !run.error.isEmpty { return run.error }
        if !run.latestAction.isEmpty { return run.latestAction }
        if !run.summary.isEmpty { return run.summary }
        return run.prompt
    }

    private func sendFollowUp() {
        let text = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if onFollowUp?(text) == true {
            followUpText = ""
        }
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
            .buttonStyle(NotchCapsuleControlStyle(isProminent: isProminent))
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
        HStack(spacing: DS.Spacing.sm + 2) {
            BrandAppIcon(size: DS.ControlSize.large, state: companionManager.voiceState)
                .cueMotion(.responseReady, .question, .surprised, anchor: .bottom)
                .overlay(alignment: .top) {
                    CueProp(kind: .questionMark)
                        .offset(y: -12)
                }

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
                        .lineLimit(1)
                        .help(statusSubtitle)
                        .cueMotion(.responseReady, part: .prop)
                }
            }

            Spacer(minLength: 0)

            if companionManager.voiceState == .listening {
                Button(action: { companionManager.finishVoiceInputFromNotch() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(DS.Glyph.micro)
                        Text("Stop")
                    }
                }
                .buttonStyle(NotchCapsuleControlStyle())
                .keyboardShortcut(.escape, modifiers: [])
                .help("Stop listening (Escape)")
                .accessibilityLabel("Stop listening")
                .accessibilityHint("Press Escape")
            }
        }
        .padding(DS.Spacing.sm + 2)
        .background(Color.black, in: RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.22), lineWidth: 0.7)
        )
    }

    private var statusTitle: String {
        if companionManager.isForegroundAgentActive {
            return "An agent is working"
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
            ForEach(Array(Self.barWeights.enumerated()), id: \.offset) { barIndex, weight in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 3, height: barHeight(forWeight: weight))
                    .cueMotion(.listenStart, part: .item(barIndex))
            }
        }
        .animation(.easeOut(duration: 0.09), value: audioPowerLevel)
    }

    private func barHeight(forWeight weight: CGFloat) -> CGFloat {
        let reactive = min(max(audioPowerLevel - 0.01, 0), 1) * 12
        return 4 + reactive * weight
    }
}


/// Compact primary controls share the chat composer's icy-blue glass.
struct NotchCapsuleControlStyle: ButtonStyle {
    var isProminent = true
    var height: CGFloat = DS.ControlSize.regular
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.control.weight(.semibold))
            .foregroundStyle(isProminent ? Color(hex: "#12223B") : DS.Colors.textSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .background {
                if isProminent {
                    DSGlassSurface(cornerRadius: height / 2, isPressed: configuration.isPressed)
                } else {
                    Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.7))
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
