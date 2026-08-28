//
//  NotchChatView.swift
//  leanring-buddy
//
//  Chat + history for the notch. Ctrl+command drops a compact chat from the
//  camera housing; typed sends stay on this surface so the transcript is
//  visible. Voice still uses the Talk shortcut.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchSurfaceTransitionModel: ObservableObject {
    @Published private(set) var isPresented = false

    /// Per-frame morph state, driven by the controller's vsync frame
    /// animator (`NotchCompanionController.animateFrame`) — NEVER by a
    /// SwiftUI animation. The display link is the clock; these are plain
    /// published values so the glass radius and the content fade stay in
    /// lockstep with the window's real, growing frame.
    ///
    /// `morphCardness` is 0 at pill shape and 1 at full card shape.
    /// `morphContentOpacity` is the content fade for that same instant.
    /// `morphBezelOpacity` is the solid-black cover that keeps the surface
    /// indistinguishable from the bezel at the pill end of the morph.
    @Published private(set) var morphCardness: CGFloat = 0
    @Published private(set) var morphContentOpacity: CGFloat = 0
    @Published private(set) var morphBezelOpacity: CGFloat = 1

    /// Expand and collapse share the morph math but not the feel: expand
    /// eases out and fades content in late, collapse eases in and fades
    /// content out early. `present`/`dismiss` record which way the clock
    /// is running so `updateMorph` can shape both.
    private var isExpandingMorph = true

    /// Reset to the pill state without any animation, called before the
    /// window starts growing from the pill frame.
    func prepare() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = false
            morphCardness = 0
            morphContentOpacity = 0
            morphBezelOpacity = 1
        }
    }

    func present() {
        isExpandingMorph = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = true
        }
    }

    func dismiss() {
        isExpandingMorph = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = false
        }
    }

    /// One vsync tick from the frame animator. Both values are written
    /// unanimated on purpose — wrapping them in `withAnimation` would hand
    /// SwiftUI a second, competing clock, which is exactly the fight the
    /// old matchedGeometry morph lost.
    func updateMorph(easedProgress: CGFloat, linearProgress: CGFloat) {
        morphCardness = NotchLayoutMath.morphCardness(
            easedProgress: easedProgress,
            isExpanding: isExpandingMorph
        )
        morphContentOpacity = NotchLayoutMath.morphContentOpacity(
            linearProgress: linearProgress,
            isExpanding: isExpandingMorph
        )
        morphBezelOpacity = NotchLayoutMath.morphBezelOpacity(
            linearProgress: linearProgress,
            isExpanding: isExpandingMorph
        )
    }

    func showWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = true
            morphCardness = 1
            morphContentOpacity = 1
            morphBezelOpacity = 0
        }
    }
}

/// Card window is animated to its real, growing frame by the controller
/// (`animateFrame`); this surface always renders at the full destination
/// size and is revealed by that frame growth, like a mask. Three things
/// keep it reading as the notch itself expanding, not a new panel:
///
///   • The bottom corner radius interpolates pill (8pt) → card (18pt) on
///     the animator's clock, so a pill-sized window still has pill-shaped
///     corners at the start of the morph.
///   • A solid bezel-black fill covers the glass at the pill end of the
///     morph — the card's glass is visibly lighter than the pill's solid
///     black, and without this cover the click flashes color before it
///     grows, which reads as a different object.
///   • The content fade is locked to that same clock, so text never pops
///     into a window too small to hold it.
struct NotchLiquidGlassCardModifier: ViewModifier {
    @ObservedObject var transitionModel: NotchSurfaceTransitionModel

    /// Height of the camera housing. Needed to derive the pill's bottom
    /// corner radius — the morph's starting shape.
    var occludedTopInset: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .opacity(transitionModel.morphContentOpacity)
            .background {
                GeometryReader { geometry in
                    ZStack {
                        glassSurface(size: geometry.size, bottomCornerRadius: bottomCornerRadius)
                        cardShape(bottomCornerRadius: bottomCornerRadius)
                            .fill(Color.black)
                            .opacity(transitionModel.morphBezelOpacity)
                            .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
    }

    private var bottomCornerRadius: CGFloat {
        NotchLayoutMath.lerp(
            NotchLayoutMath.pillCornerRadius(forHeight: occludedTopInset),
            NotchLayoutMath.cardCornerRadius,
            transitionModel.morphCardness
        )
    }

    @ViewBuilder
    private func glassSurface(size: CGSize, bottomCornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                glassElement(size: size, bottomCornerRadius: bottomCornerRadius)
            }
        } else {
            fallbackMaterialElement(size: size, bottomCornerRadius: bottomCornerRadius)
        }
    }

    @available(macOS 26.0, *)
    private func glassElement(size: CGSize, bottomCornerRadius: CGFloat) -> some View {
        let shape = cardShape(bottomCornerRadius: bottomCornerRadius)
        return ZStack {
            Color.clear
                .glassEffect(.regular, in: shape)

            // Liquid Glass samples whatever is behind the notch. Without a
            // dark scrim, a white window turns the whole control surface gray
            // and destroys the contrast that makes a notch HUD glanceable.
            shape
                .fill(Color.black.opacity(0.72))
                .allowsHitTesting(false)
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func fallbackMaterialElement(size: CGSize, bottomCornerRadius: CGFloat) -> some View {
        let shape = cardShape(bottomCornerRadius: bottomCornerRadius)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(Color.black.opacity(0.76)))
            .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func cardShape(bottomCornerRadius: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomCornerRadius,
            bottomTrailingRadius: bottomCornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }
}

/// Which expanded surface the notch panel is showing. Compact chat is the
/// smaller ctrl+command drop; the full card is the hover/click Home panel.
enum NotchPresentedSurface: Equatable {
    case fullCard
    case compactChat
}

/// Shared root so the expanded panel can morph between the full Home card
/// and the compact chat without swapping NSHostingView types.
struct NotchSurfaceRoot: View {
    let surface: NotchPresentedSurface
    @ObservedObject var companionManager: CompanionManager
    var occludedTopInset: CGFloat = 0
    var layoutSize: CGSize = .zero
    var hardwareNotchWidth: CGFloat = 0
    @ObservedObject var transitionModel: NotchSurfaceTransitionModel
    var onClose: () -> Void

    /// Watched here rather than deeper in the tree so an approval prompt
    /// covers whichever surface happens to be open. A pending action is
    /// the highest-priority thing the notch can show.
    @ObservedObject private var computerUseCoordinator: ComputerUseCoordinator
    /// Same reasoning, for a connector tool call awaiting approval.
    @ObservedObject private var connectorToolCoordinator: ConnectorToolCoordinator
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    init(
        surface: NotchPresentedSurface,
        companionManager: CompanionManager,
        occludedTopInset: CGFloat = 0,
        layoutSize: CGSize = .zero,
        hardwareNotchWidth: CGFloat = 0,
        transitionModel: NotchSurfaceTransitionModel,
        onClose: @escaping () -> Void
    ) {
        self.surface = surface
        self.companionManager = companionManager
        self.occludedTopInset = occludedTopInset
        self.layoutSize = layoutSize
        self.hardwareNotchWidth = hardwareNotchWidth
        self.transitionModel = transitionModel
        self.onClose = onClose
        self.computerUseCoordinator = companionManager.computerUseCoordinator
        self.connectorToolCoordinator = companionManager.connectorToolCoordinator
    }

    var body: some View {
        ZStack {
            surfaceContent
            if let pendingRequest = computerUseCoordinator.pendingRequest {
                approvalOverlay(for: pendingRequest)
            } else if let pendingConnectorRequest = connectorToolCoordinator.pendingRequest {
                connectorApprovalOverlay(for: pendingConnectorRequest)
            }
        }
        .animation(
            accessibilityReduceMotion ? nil : .easeOut(duration: 0.2),
            value: computerUseCoordinator.pendingRequest
        )
        .animation(
            accessibilityReduceMotion ? nil : .easeOut(duration: 0.2),
            value: connectorToolCoordinator.pendingRequest
        )
    }

    @ViewBuilder
    private var surfaceContent: some View {
        switch surface {
        case .fullCard:
            NotchExpandedView(
                companionManager: companionManager,
                occludedTopInset: occludedTopInset,
                layoutSize: layoutSize,
                hardwareNotchWidth: hardwareNotchWidth,
                transitionModel: transitionModel,
                onClose: onClose
            )
        case .compactChat:
            NotchCompactChatCard(
                companionManager: companionManager,
                occludedTopInset: occludedTopInset,
                layoutSize: layoutSize,
                hardwareNotchWidth: hardwareNotchWidth,
                transitionModel: transitionModel,
                onClose: onClose
            )
        }
    }

    private func approvalOverlay(for pendingRequest: ComputerUseRequest) -> some View {
        VStack(spacing: 0) {
            // Push below the camera housing, same contract as every other
            // notch surface.
            Spacer().frame(height: occludedTopInset)
            ComputerUseApprovalCard(
                request: pendingRequest,
                onApprove: { computerUseCoordinator.approvePendingRequest() },
                onDeny: { computerUseCoordinator.denyPendingRequest() }
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .background(Color.black.opacity(0.72))
        .transition(.opacity)
    }

    private func connectorApprovalOverlay(for pendingRequest: ConnectorToolApprovalRequest) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: occludedTopInset)
            ConnectorToolApprovalCard(
                request: pendingRequest,
                onApprove: { connectorToolCoordinator.approvePendingRequest() },
                onDeny: { connectorToolCoordinator.denyPendingRequest() }
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .background(Color.black.opacity(0.72))
        .transition(.opacity)
    }
}

/// Minimal notch expansion: chat transcript + composer, no Home chrome.
struct NotchCompactChatCard: View {
    @ObservedObject var companionManager: CompanionManager
    var occludedTopInset: CGFloat = 0
    var layoutSize: CGSize = .zero
    var hardwareNotchWidth: CGFloat = 0
    @ObservedObject var transitionModel: NotchSurfaceTransitionModel
    var onClose: () -> Void

    var body: some View {
        compactBody
            .frame(
                width: layoutSize.width > 0 ? layoutSize.width : nil,
                height: layoutSize.height > 0 ? layoutSize.height : nil,
                alignment: .top
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .onExitCommand(perform: onClose)
    }

    private var compactBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: occludedTopInset)

            compactHeader
                .padding(.horizontal, 12)
                .padding(.top, 8)

            NotchChatView(
                companionManager: companionManager,
                isCompactLayout: true,
                shouldFocusComposerOnAppear: true
            )
            .frame(maxHeight: .infinity, alignment: .top)
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

    private var compactHeader: some View {
        HStack(spacing: 8) {
            BuddyMark(size: .small, state: companionManager.voiceState, color: companionManager.themeColor)

            Text("chat")
                .font(DS.Fonts.titleCompact)
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

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
            .accessibilityLabel("Collapse chat")
        }
    }

    private var statusDotColor: Color {
        switch companionManager.voiceState {
        case .idle: return DS.Colors.success
        case .listening, .processing, .responding: return DS.Colors.accent
        }
    }
}

struct NotchChatView: View {
    @ObservedObject var companionManager: CompanionManager
    var isCompactLayout: Bool = false
    var shouldFocusComposerOnAppear: Bool = false

    @State private var typedMessageInput = ""
    @State private var isShowingHistory = false
    @FocusState private var isComposerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private let suggestedPrompts = [
        "What’s on my screen?",
        "Summarize my clipboard",
        "Start a 25-minute timer"
    ]

    var body: some View {
        VStack(spacing: 0) {
            chatToolbar
                .padding(.horizontal, isCompactLayout ? 12 : 24)
                .padding(.top, isCompactLayout ? 4 : 18)
                .padding(.bottom, isCompactLayout ? 0 : 10)

            if isShowingHistory {
                historyList
            } else {
                transcript
                composer
                    .padding(.horizontal, isCompactLayout ? 12 : 24)
                    .padding(.top, isCompactLayout ? 6 : 8)
                    .padding(.bottom, isCompactLayout ? 10 : 18)
            }
        }
        .background {
            // Light from the notch: the desktop chat sits under the same
            // soft accent wash the notch card casts, so the two surfaces
            // read as one place. Subtle on purpose — a presence, not a tint.
            if !isCompactLayout {
                RadialGradient(
                    colors: [companionManager.themeColor.opacity(0.07), Color.clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 320
                )
                .ignoresSafeArea()
            }
        }
        .onAppear {
            guard shouldFocusComposerOnAppear else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                isComposerFocused = true
            }
        }
    }

    private var chatToolbar: some View {
        HStack(spacing: 8) {
            Text(isShowingHistory ? "History" : companionManager.currentChat.title)
                .font(isCompactLayout ? DS.Fonts.titleCompact : DS.Fonts.title)
                .foregroundColor(primaryTextColor)
                .lineLimit(1)

            Spacer()

            Button(action: {
                withAnimation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isShowingHistory.toggle()
                }
            }) {
                Image(systemName: isShowingHistory ? "bubble.left.and.bubble.right" : "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(secondaryTextColor)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(controlBackgroundColor))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(isShowingHistory ? "Back to chat" : "Past chats")
            .accessibilityLabel(isShowingHistory ? "Back to chat" : "Past chats")

            Button(action: {
                companionManager.startNewChat()
                isShowingHistory = false
            }) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(secondaryTextColor)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(controlBackgroundColor))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("New chat")
            .accessibilityLabel("New chat")
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if companionManager.currentChat.messages.isEmpty
                        && companionManager.streamingAssistantText.isEmpty {
                        // The hero gets the whole pane, vertically centered,
                        // instead of perching at the top of an empty scroll.
                        emptyState
                            .containerRelativeFrame(.vertical) { height, _ in
                                max(height - 40, 0)
                            }
                    }

                    ForEach(companionManager.currentChat.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if !companionManager.streamingAssistantText.isEmpty {
                        streamingBubble
                            .id("streaming")
                    }
                }
                .frame(maxWidth: isCompactLayout ? .infinity : 640)
                .padding(.horizontal, isCompactLayout ? 16 : 24)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: companionManager.currentChat.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: companionManager.streamingAssistantText) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if !companionManager.streamingAssistantText.isEmpty {
            proxy.scrollTo("streaming", anchor: .bottom)
        } else if let lastID = companionManager.currentChat.messages.last?.id {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            BuddyMark(
                size: isCompactLayout ? .standard : .hero,
                state: companionManager.voiceState,
                color: companionManager.themeColor
            )

            Text(isCompactLayout ? "Ask anything" : "Hey — I'm HeyMate.")
                .font(isCompactLayout ? DS.Fonts.titleCompact : DS.Fonts.pageTitle)
                .tracking(isCompactLayout ? 0 : -0.5)
                .foregroundColor(primaryTextColor)
            Text(isCompactLayout
                 ? "Type below, or hold \(companionManager.talkShortcutOption.displayText) to talk."
                 : "Ask about anything on your screen, or say “agent, build a landing page” and I'll spin up a coding job.")
                .font(DS.Fonts.body)
                .foregroundColor(secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if !isCompactLayout {
                HStack(spacing: 10) {
                    ForEach(suggestedPrompts, id: \.self) { prompt in
                        suggestionTile(prompt)
                    }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// One tappable prompt card: icon above, two-line label below. Icon
    /// picks a glyph by keyword so a prompt edit never needs art direction.
    private func suggestionTile(_ prompt: String) -> some View {
        Button(action: { companionManager.sendTypedMessage(prompt) }) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: suggestionIcon(for: prompt))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
                Text(prompt)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 158, height: 82, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!companionManager.canAcceptTypedAgentTask)
    }

    private func suggestionIcon(for prompt: String) -> String {
        if prompt.contains("screen") { return "desktopcomputer" }
        if prompt.contains("clipboard") { return "doc.on.clipboard" }
        if prompt.contains("timer") { return "timer" }
        return "sparkles"
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack(alignment: .bottom, spacing: 7) {
            if isUser { Spacer(minLength: 36) }
            if !isUser && !isCompactLayout {
                BuddyMark(size: .small, color: companionManager.themeColor)
            }
            Text(message.text)
                .font(DS.Fonts.body)
                .foregroundColor(primaryTextColor)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isUser ? DS.Colors.helpChatUserBubble : assistantBubbleColor)
                )
                .contextMenu {
                    Button("Copy") { copyToPasteboard(message.text) }
                }
            if !isUser { Spacer(minLength: 36) }
        }
    }

    private var streamingBubble: some View {
        HStack(alignment: .bottom, spacing: 7) {
            if !isCompactLayout {
                BuddyMark(size: .small, color: companionManager.themeColor)
            }
            Text(companionManager.streamingAssistantText)
                .font(DS.Fonts.body)
                .foregroundColor(primaryTextColor)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(assistantBubbleColor)
                )
            Spacer(minLength: 36)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TextField("Ask HeyMate…", text: $typedMessageInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.body)
                    .foregroundColor(primaryTextColor)
                    .lineLimit(1...4)
                    .focused($isComposerFocused)
                    .onSubmit(sendTypedMessageFromInput)
                    .padding(.leading, 14)

                Button(action: sendTypedMessageFromInput) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(canSendTypedMessage ? DS.Colors.textOnAccent : DS.Colors.textTertiary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(canSendTypedMessage ? companionManager.themeColor : DS.Colors.surface3)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(!canSendTypedMessage)
                .help("Send")
                .accessibilityLabel("Send message")
                .padding(.trailing, 5)
            }
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(composerBackgroundColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isComposerFocused ? companionManager.themeColor.opacity(0.55) : borderColor, lineWidth: 1)
            )
            .shadow(color: companionManager.themeColor.opacity(isComposerFocused ? 0.16 : 0), radius: 12)

            if !isCompactLayout {
                Text(composerStatusText)
                    .font(DS.Fonts.micro)
                    .foregroundColor(tertiaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .opacity(companionManager.canAcceptTypedAgentTask ? 1 : 0.45)
        .disabled(!companionManager.canAcceptTypedAgentTask)
    }

    private var canSendTypedMessage: Bool {
        !typedMessageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && companionManager.canAcceptTypedAgentTask
    }

    private func sendTypedMessageFromInput() {
        guard canSendTypedMessage else { return }
        // Clear only what was accepted. A refused message stays in the field
        // with the reason underneath it, rather than vanishing on Enter.
        if companionManager.sendTypedMessage(typedMessageInput) {
            typedMessageInput = ""
        }
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            if !companionManager.rememberConversationsEnabled {
                Text("Turn on Remember conversations on Home to keep chats after this session.")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            if companionManager.savedChats.isEmpty {
                Text("No saved chats yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tertiaryTextColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(companionManager.savedChats) { session in
                            historyRow(session)
                        }

                        Button(action: { companionManager.clearAllChats() }) {
                            Text("Clear all chats")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.destructiveText)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func historyRow(_ session: ChatSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: {
                companionManager.openChat(id: session.id)
                isShowingHistory = false
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(DS.Fonts.headline)
                        .foregroundColor(primaryTextColor)
                        .lineLimit(1)
                    Text(session.previewText)
                        .font(DS.Fonts.caption)
                        .foregroundColor(tertiaryTextColor)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: { companionManager.deleteChat(id: session.id) }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(tertiaryTextColor)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Delete \(session.title)")
            .accessibilityLabel("Delete chat \(session.title)")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(session.id == companionManager.currentChat.id ? selectedHistoryBackgroundColor : controlBackgroundColor)
        )
    }

    // The dusk text tokens read correctly on both the black notch glass and
    // the desktop window's warm background, so one value serves both.
    private var primaryTextColor: Color { DS.Colors.textPrimary }

    private var secondaryTextColor: Color { DS.Colors.textSecondary }

    private var tertiaryTextColor: Color { DS.Colors.textTertiary }

    private var controlBackgroundColor: Color {
        isCompactLayout ? DS.Colors.surface3.opacity(0.7) : DS.Colors.surface2
    }

    private var selectedHistoryBackgroundColor: Color {
        isCompactLayout ? DS.Colors.accentSubtle : companionManager.themeColor.opacity(0.14)
    }

    private var assistantBubbleColor: Color {
        isCompactLayout ? DS.Colors.surface2.opacity(0.85) : DS.Colors.surface2
    }

    private var composerBackgroundColor: Color {
        isCompactLayout ? DS.Colors.surface2.opacity(0.85) : DS.Colors.surface1
    }

    private var borderColor: Color {
        isCompactLayout ? Color.white.opacity(0.10) : DS.Colors.borderSubtle
    }

    private var composerStatusText: String {
        guard !companionManager.canAcceptTypedAgentTask else {
            return "Return to send · Hold \(companionManager.talkShortcutOption.displayText) to talk"
        }
        switch companionManager.voiceState {
        case .idle: return "HeyMate is finishing another task"
        case .listening: return "Listening…"
        case .processing: return "Thinking…"
        case .responding: return "Speaking…"
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
