//
//  NotchChatView.swift
//  HeyMate
//
//  Chat + history for the notch. Ctrl+command drops a compact chat from the
//  camera housing; typed sends stay on this surface so the transcript is
//  visible. Voice still uses the Talk shortcut.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
    /// Content blur radius and scale for the same instant — the content
    /// sharpens and grows out from the camera as it fades in.
    @Published private(set) var morphContentBlur: CGFloat = NotchLayoutMath.contentRevealMaxBlur
    @Published private(set) var morphContentScale: CGFloat = NotchLayoutMath.contentRevealMinScale

    /// The size the surface lays out at after the person drags an edge.
    /// Surfaces are built at their open size so the grow animation clips
    /// rather than reflows; a live resize has to reach them through here.
    @Published var resizedLayoutSize: CGSize?

    /// The size a surface built for `layoutSize` should lay out at now.
    func effectiveLayoutSize(_ layoutSize: CGSize, viewport: CGSize) -> CGSize {
        let size = resizedLayoutSize ?? layoutSize
        return CGSize(
            width: size.width > 0 ? size.width : viewport.width,
            height: size.height > 0 ? size.height : viewport.height
        )
    }

    /// Expand and collapse share the morph math but not the feel: expand
    /// eases out and fades content in late, collapse eases in and fades
    /// content out early. `present`/`dismiss` record which way the clock
    /// is running so `updateMorph` can shape both.
    private var isExpandingMorph = true
    private var morphStartCardness: CGFloat = 0
    private var morphStartContentOpacity: CGFloat = 0

    /// Reset to the pill state without any animation, called before the
    /// window starts growing from the pill frame.
    func prepare(preservingMorph: Bool = false) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = false
            resizedLayoutSize = nil
            if preservingMorph { return }
            morphCardness = 0
            morphContentOpacity = 0
            morphBezelOpacity = 1
            morphContentBlur = NotchLayoutMath.contentRevealMaxBlur
            morphContentScale = NotchLayoutMath.contentRevealMinScale
        }
    }

    func present() {
        isExpandingMorph = true
        morphStartCardness = morphCardness
        morphStartContentOpacity = morphContentOpacity
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = true
        }
    }

    func dismiss() {
        isExpandingMorph = false
        morphStartCardness = morphCardness
        morphStartContentOpacity = morphContentOpacity
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
    func updateMorph(easedProgress: CGFloat, linearProgress: CGFloat, followsFrame: Bool = false) {
        morphCardness = followsFrame ? NotchLayoutMath.lerp(
            morphStartCardness, isExpandingMorph ? 1 : 0, min(max(easedProgress, 0), 1)
        ) : NotchLayoutMath.morphCardness(
            linearProgress: linearProgress,
            isExpanding: isExpandingMorph
        )
        let contentOpacity = NotchLayoutMath.morphContentOpacity(
            linearProgress: linearProgress,
            isExpanding: isExpandingMorph
        )
        morphContentOpacity = followsFrame
            ? (isExpandingMorph ? NotchLayoutMath.lerp(morphStartContentOpacity, 1, contentOpacity)
                : morphStartContentOpacity * contentOpacity)
            : contentOpacity
        morphBezelOpacity = NotchLayoutMath.morphBezelOpacity(
            linearProgress: linearProgress,
            isExpanding: isExpandingMorph
        )
        morphContentBlur = NotchLayoutMath.morphContentBlur(contentOpacity: morphContentOpacity)
        morphContentScale = NotchLayoutMath.morphContentScale(contentOpacity: morphContentOpacity)
    }

    func showWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = true
            morphCardness = 1
            morphContentOpacity = 1
            morphBezelOpacity = 0
            morphContentBlur = 0
            morphContentScale = 1
        }
    }
}

/// Content reveal for every expanded surface: scale up from the camera,
/// sharpen from a blur, and fade in, all from the transition model so the
/// text never outruns the growing window. Apply BEFORE `.position` so the
/// top-anchored scale pivots on the content's own top edge.
struct NotchContentRevealModifier: ViewModifier {
    @ObservedObject var transitionModel: NotchSurfaceTransitionModel

    func body(content: Content) -> some View {
        content
            .scaleEffect(transitionModel.morphContentScale, anchor: .top)
            .blur(radius: transitionModel.morphContentBlur)
            .opacity(transitionModel.morphContentOpacity)
    }
}

/// The notch silhouette as a SwiftUI shape: flat top flush with the screen,
/// concave shoulders into the body, rounded bottom. Geometry lives in
/// `NotchLayoutMath.silhouettePath` so it is unit-tested.
struct NotchSilhouetteShape: Shape {
    var shoulderRadius: CGFloat
    var bottomRadius: CGFloat
    var neckWidth: CGFloat = 0
    var neckHeight: CGFloat = 0
    var neckProgress: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulderRadius, bottomRadius) }
        set { shoulderRadius = newValue.first; bottomRadius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let path = neckWidth > 0 && neckHeight > 0
            ? NotchLayoutMath.chatSilhouettePath(size: rect.size, notchWidth: neckWidth,
                neckHeight: neckHeight, cardness: neckProgress, bottomRadius: bottomRadius)
            : NotchLayoutMath.silhouettePath(size: rect.size, shoulderRadius: shoulderRadius,
                bottomRadius: bottomRadius)
        return Path(path).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// Card window is animated to its real, growing frame by the controller
/// (`animateFrame`); this surface always renders at the full destination
/// size and is revealed by that frame growth, like a mask. Three things
/// keep it reading as the notch itself expanding, not a new panel:
///
///   • One silhouette for pill and card. The bottom radius interpolates
///     pill (8pt) → card (24pt) and the concave top shoulders grow 0 → 10pt
///     on the animator's clock, so a pill-sized window is still the pill.
///   • Opaque bezel black, identical to the camera housing, throughout. No
///     glass, scrim, rim or shadow, so there is no edge to read as a box.
///   • The content fade is locked to that same clock, so text never pops
///     into a window too small to hold it.
struct NotchLiquidGlassCardModifier: ViewModifier {
    @ObservedObject var transitionModel: NotchSurfaceTransitionModel
    /// Kept for the outline preference. The card itself draws no rim: a
    /// line around the black is exactly what made it read as a box.
    var outlineColor: Color
    var isOutlineEnabled: Bool

    /// Height of the camera housing. Needed to derive the pill's bottom
    /// corner radius — the morph's starting shape — and whether this
    /// surface hangs from a real housing (and so gets shoulders).
    var occludedTopInset: CGFloat = 0
    var neckWidth: CGFloat = 0
    var neckHeight: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    // Collapsed panel carries transparent padding for its
                    // glow. Start inside that padding so swapping panels
                    // does not turn the outline bounds into a larger black
                    // rectangle on the first morph frame. The inset melts
                    // away with the corner transition as the card forms.
                    let surfaceInset = outlineInset
                    let surfaceWidth = max(geometry.size.width - surfaceInset * 2, 1)
                    let surfaceHeight = max(geometry.size.height - surfaceInset, 1)

                    silhouette
                        .fill(Color.black)
                        .frame(width: surfaceWidth, height: surfaceHeight)
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .top
                    )
                }
            }
            // Content paints full-bleed backgrounds (the bottom bar, the
            // header wing). Clipping to the same silhouette keeps the
            // shoulders and rounded bottom through the morph.
            .clipShape(silhouette.inset(horizontal: outlineInset))
            .overlay {
                silhouette.inset(horizontal: outlineInset)
                    .stroke(LinearGradient(colors: [.white.opacity(0.075), .white.opacity(0.16)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
                    .opacity(transitionModel.morphCardness)
                    .mask {
                        if neckHeight > 0 {
                            // Full chat has no separate title bar. Hide the rim
                            // across its neck and shoulders, then restore it
                            // below the join instead of drawing a bright seam.
                            GeometryReader { proxy in
                                let height = max(proxy.size.height, neckHeight + 24)
                                LinearGradient(stops: [
                                    .init(color: .clear, location: neckHeight / height),
                                    .init(color: .black, location: (neckHeight + 24) / height)
                                ], startPoint: .top, endPoint: .bottom)
                            }
                        } else {
                            Color.white
                        }
                    }
                    .allowsHitTesting(false)
            }
    }

    private var outlineInset: CGFloat {
        isOutlineEnabled
            ? NotchLayoutMath.outlinePad * (1 - transitionModel.morphCardness)
            : 0
    }

    private var silhouette: NotchSilhouetteShape {
        NotchSilhouetteShape(
            shoulderRadius: NotchLayoutMath.shoulderInset(occludedTopInset: occludedTopInset) > 0
                ? NotchLayoutMath.shoulderRadius(cardness: transitionModel.morphCardness)
                : 0,
            bottomRadius: NotchLayoutMath.lerp(
                NotchLayoutMath.pillCornerRadius(forHeight: occludedTopInset),
                NotchLayoutMath.cardCornerRadius,
                transitionModel.morphCardness
            ),
            neckWidth: neckWidth,
            neckHeight: neckHeight,
            neckProgress: transitionModel.morphCardness
        )
    }
}

private extension NotchSilhouetteShape {
    /// Same silhouette, pulled in from the left, right and bottom by
    /// `horizontal` (the top stays flush with the screen).
    func inset(horizontal: CGFloat) -> some Shape {
        NotchInsetSilhouette(base: self, inset: horizontal)
    }
}

private struct NotchInsetSilhouette: Shape {
    let base: NotchSilhouetteShape
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        guard inset > 0 else { return base.path(in: rect) }
        let inner = CGRect(
            x: rect.minX + inset,
            y: rect.minY,
            width: max(rect.width - inset * 2, 0),
            height: max(rect.height - inset, 0)
        )
        return base.path(in: inner)
    }
}

/// Opaque black behind an overlay that covers a whole surface (approval
/// prompts), in the card's silhouette, so it never paints the transparent
/// strips beside the shoulders.
struct NotchSurfaceBackdrop: View {
    var occludedTopInset: CGFloat

    var body: some View {
        NotchSilhouetteShape(
            shoulderRadius: NotchLayoutMath.shoulderInset(occludedTopInset: occludedTopInset),
            bottomRadius: NotchLayoutMath.cardCornerRadius
        )
        .fill(Color.black)
    }
}

/// Which expanded surface the notch panel is showing. Compact chat is the
/// smaller ctrl+command drop; the full card is the hover/click Home panel.
enum NotchPresentedSurface: Equatable {
    case fullCard
    case compactChat
    /// The whole chat, rail and all, grown out of the notch. This is where
    /// "open chat" lands instead of a separate window.
    case fullChat
    case connectorSuggestion
}

/// Shared root so the expanded panel can morph between the full Home card
/// and the compact chat without swapping NSHostingView types.
struct NotchSurfaceRoot: View {
    let surface: NotchPresentedSurface
    @ObservedObject var companionManager: CompanionManager
    var occludedTopInset: CGFloat = 0
    var layoutSize: CGSize = .zero
    var hardwareNotchWidth: CGFloat = 0
    var fullChatSection: DesktopSection = .chat
    @ObservedObject var transitionModel: NotchSurfaceTransitionModel
    var onClose: () -> Void
    var onResizeBegan: () -> Void
    var onResizeChanged: (NotchHomeEdge, CGSize) -> Void
    var onResizeEnded: (Bool) -> Void

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
        fullChatSection: DesktopSection = .chat,
        transitionModel: NotchSurfaceTransitionModel,
        onClose: @escaping () -> Void,
        onResizeBegan: @escaping () -> Void = {},
        onResizeChanged: @escaping (NotchHomeEdge, CGSize) -> Void = { _, _ in },
        onResizeEnded: @escaping (Bool) -> Void = { _ in }
    ) {
        self.surface = surface
        self.companionManager = companionManager
        self.occludedTopInset = occludedTopInset
        self.layoutSize = layoutSize
        self.hardwareNotchWidth = hardwareNotchWidth
        self.fullChatSection = fullChatSection
        self.transitionModel = transitionModel
        self.onClose = onClose
        self.onResizeBegan = onResizeBegan
        self.onResizeChanged = onResizeChanged
        self.onResizeEnded = onResizeEnded
        self.computerUseCoordinator = companionManager.computerUseCoordinator
        self.connectorToolCoordinator = companionManager.connectorToolCoordinator
    }

    var body: some View {
        ZStack {
            // The display-link morph already drives the surface and reveal.
            // A second cue transform moved the whole silhouette off its neck.
            surfaceContent
            if surface != .connectorSuggestion {
                NotchHomeResizeChrome(
                    onBegan: onResizeBegan,
                    onChanged: onResizeChanged,
                    onEnded: onResizeEnded
                )
                // Straddle the body's edge, not the transparent strip the
                // shoulders need beside it.
                .padding(.horizontal, surface == .fullChat ? 0 : max(NotchLayoutMath.shoulderInset(occludedTopInset: occludedTopInset) - 4, 0))
            }
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
        case .compactChat, .fullChat:
            NotchCompactChatCard(
                companionManager: companionManager,
                occludedTopInset: occludedTopInset,
                layoutSize: layoutSize,
                hardwareNotchWidth: hardwareNotchWidth,
                transitionModel: transitionModel,
                isFullChat: surface == .fullChat,
                fullChatSection: fullChatSection,
                onClose: onClose
            )
        case .connectorSuggestion:
            NotchConnectorSuggestionCard(
                companionManager: companionManager,
                occludedTopInset: occludedTopInset,
                layoutSize: layoutSize,
                transitionModel: transitionModel
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
                offersConversationGrant: computerUseCoordinator.conversationID != nil,
                onDeny: { computerUseCoordinator.denyPendingRequest() },
                onGrant: { scope in
                    computerUseCoordinator.approvePendingRequest(scope: scope)
                }
            )
            .padding(.horizontal, 14 + NotchLayoutMath.shoulderInset(occludedTopInset: occludedTopInset))
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .background(NotchSurfaceBackdrop(occludedTopInset: occludedTopInset))
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
            .padding(.horizontal, 14 + NotchLayoutMath.shoulderInset(occludedTopInset: occludedTopInset))
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .background(NotchSurfaceBackdrop(occludedTopInset: occludedTopInset))
        .transition(.opacity)
    }
}

/// Passive browser-context prompt. Opens itself without taking focus and
/// keeps all decisions on one compact surface.
struct NotchConnectorSuggestionCard: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var suggestionMonitor: ContextualConnectorSuggestionMonitor
    @ObservedObject private var connections: ComposioConnectionsRuntime
    var occludedTopInset: CGFloat = 0
    var layoutSize: CGSize = .zero
    @ObservedObject var transitionModel: NotchSurfaceTransitionModel

    init(
        companionManager: CompanionManager,
        occludedTopInset: CGFloat,
        layoutSize: CGSize,
        transitionModel: NotchSurfaceTransitionModel
    ) {
        self.companionManager = companionManager
        self.suggestionMonitor = companionManager.contextualConnectorSuggestionMonitor
        self.connections = companionManager.composioConnections
        self.occludedTopInset = occludedTopInset
        self.layoutSize = layoutSize
        self.transitionModel = transitionModel
    }

    var body: some View {
        GeometryReader { viewport in
            let size = transitionModel.effectiveLayoutSize(layoutSize, viewport: viewport.size)
            let contentWidth = size.width
            let contentHeight = size.height

            suggestionBody
                .padding(.horizontal, NotchLayoutMath.shoulderInset(occludedTopInset: occludedTopInset))
                .frame(width: contentWidth, height: contentHeight, alignment: .top)
                .background {
                    BrandNebulaSurface.notchCard
                }
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

    @ViewBuilder
    private var suggestionBody: some View {
        if let suggestion = suggestionMonitor.suggestion,
           !connections.state(for: suggestion.toolkitSlug).isConnected {
            VStack(spacing: 8) {
                Spacer(minLength: occludedTopInset)

                HStack(spacing: 12) {
                    connectorIdentity(for: suggestion)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect \(suggestion.toolkitName) to HeyMate")
                            .font(DS.Fonts.body.weight(.semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text("Use HeyMate with this \(suggestion.toolkitName) page")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        actionButton("No", systemName: "xmark", isPrimary: false) {
                            suggestionMonitor.declinePermanently(suggestion)
                        }
                        actionButton("Not now", systemName: "clock", isPrimary: false) {
                            suggestionMonitor.snooze(suggestion)
                        }
                        actionButton("Connect", systemName: "link", isPrimary: true) {
                            connect(suggestion)
                        }
                    }
                }
                .frame(height: 38)

                HStack(spacing: 6) {
                    Text("Use HeyMate to")
                        .font(DS.Fonts.sectionLabel)
                        .foregroundColor(DS.Colors.textTertiary)

                    ForEach(suggestion.capabilities, id: \.self) { capability in
                        capabilityChip(capability)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 22)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Connect \(suggestion.toolkitName) to HeyMate")
        }
    }

    private func connectorIdentity(for suggestion: ContextualConnectorSuggestion) -> some View {
        HStack(spacing: 5) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .stroke(DS.Colors.borderStrong.opacity(0.6), lineWidth: 0.5)
                }

            Image(systemName: "arrow.left.arrow.right")
                .font(DS.Glyph.micro)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 10)

            toolkitIcon(for: suggestion)
        }
        .padding(.trailing, 2)
    }

    private func capabilityChip(_ capability: String) -> some View {
        Text(capability)
            .font(DS.Fonts.keycap)
            .foregroundColor(DS.Colors.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(DS.Colors.surface3.opacity(0.68)))
    }

    private func toolkitIcon(for suggestion: ContextualConnectorSuggestion) -> some View {
        ComposioToolkitLogoView(toolkit: suggestion.toolkit, compactSize: 32)
    }

    private func actionButton(
        _ title: String,
        systemName: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(DS.Glyph.micro)
                Text(title)
            }
        }
        .buttonStyle(NotchCapsuleControlStyle(isProminent: isPrimary))
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

/// Chat grown out of the notch. Compact is transcript + composer; full is
/// the same chat the desktop window used to hold, rail included.
struct NotchCompactChatCard: View {
    @ObservedObject var companionManager: CompanionManager
    var occludedTopInset: CGFloat = 0
    var layoutSize: CGSize = .zero
    var hardwareNotchWidth: CGFloat = 0
    @ObservedObject var transitionModel: NotchSurfaceTransitionModel
    var isFullChat = false
    var fullChatSection: DesktopSection = .chat
    var onClose: () -> Void

    private var neckHeight: CGFloat {
        occludedTopInset + (isFullChat && occludedTopInset > 0 ? NotchLayoutMath.chatNeckExtension : 0)
    }

    var body: some View {
        GeometryReader { viewport in
            let size = transitionModel.effectiveLayoutSize(layoutSize, viewport: viewport.size)
            let contentWidth = size.width
            let contentHeight = size.height

            compactBody
                .environment(\.workspaceGradientHeight, isFullChat ? contentHeight : 0)
                .padding(.horizontal, isFullChat ? 0 : NotchLayoutMath.shoulderInset(occludedTopInset: occludedTopInset))
                .frame(width: contentWidth, height: contentHeight, alignment: .top)
                .modifier(NotchContentRevealModifier(transitionModel: transitionModel))
                .position(x: viewport.size.width / 2, y: contentHeight / 2)
        }
        .coordinateSpace(name: WorkspaceBackground.coordinateSpace)
        .modifier(NotchLiquidGlassCardModifier(
            transitionModel: transitionModel,
            outlineColor: companionManager.themeColor,
            isOutlineEnabled: companionManager.isNotchOutlineEnabled,
            occludedTopInset: occludedTopInset,
            neckWidth: isFullChat && occludedTopInset > 0 ? hardwareNotchWidth : 0,
            neckHeight: isFullChat ? neckHeight : 0
        ))
        .clipped()
        .onExitCommand(perform: onClose)
    }

    private var compactBody: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: neckHeight)

            Group {
                if isFullChat {
                    // The whole workspace: chat, Integrations, Settings.
                    DesktopRootView(
                        companionManager: companionManager,
                        initialSection: fullChatSection,
                        onClose: onClose,
                        onDetach: { section in
                            companionManager.detachDesktopWindow(section: section)
                        }
                    )
                } else {
                    MateHomeView(
                        companionManager: companionManager,
                        isCompactLayout: true,
                        onOpenSection: { section in
                            companionManager.openDesktopWindow(section: section)
                        },
                        onClose: onClose,
                        shouldFocusComposerOnAppear: true
                    )
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if isFullChat {
                WorkspaceBackground()
            } else {
                BrandNebulaSurface.notchCard
            }
        }
    }

}

struct NotchChatView: View {
    @ObservedObject var companionManager: CompanionManager
    var isCompactLayout: Bool = false
    var shouldFocusComposerOnAppear: Bool = false
    var onOpenSection: ((DesktopSection) -> Void)? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        MateHomeView(
            companionManager: companionManager,
            isCompactLayout: isCompactLayout,
            onOpenSection: onOpenSection ?? { section in
                companionManager.openDesktopWindow(section: section)
            },
            onClose: onClose,
            shouldFocusComposerOnAppear: shouldFocusComposerOnAppear
        )
    }
}

/// Next-action chips and artifact paths under a finished mate reply.
/// The notch chat and the desktop chat share this row.
struct HarnessFollowUpRow: View {
    let actions: [String]
    let artifactPaths: [String]
    let onAction: (String) -> Void
    let onOpenArtifact: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !actions.isEmpty {
                HStack(alignment: .center, spacing: 6) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Button(action) { onAction(action) }
                            .buttonStyle(.plain)
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule(style: .continuous).fill(DS.Colors.surface2))
                            .pointerCursor()
                    }
                }
            }
            ForEach(Array(artifactPaths.enumerated()), id: \.offset) { _, path in
                MateArtifactCard(
                    path: path,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    isDirectory: (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false,
                    onOpen: { onOpenArtifact(path) }
                )
                .frame(width: 160)
            }
        }
    }
}
