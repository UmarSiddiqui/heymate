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
            morphContentBlur = NotchLayoutMath.contentRevealMaxBlur
            morphContentScale = NotchLayoutMath.contentRevealMinScale
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
            linearProgress: linearProgress,
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

/// Card window is animated to its real, growing frame by the controller
/// (`animateFrame`); this surface always renders at the full destination
/// size and is revealed by that frame growth, like a mask. Three things
/// keep it reading as the notch itself expanding, not a new panel:
///
///   • The bottom corner radius interpolates pill (8pt) → card (18pt) on
///     the animator's clock, so a pill-sized window still has pill-shaped
///     corners at the start of the morph.
///   • Pitch-black fill matches camera housing throughout the morph.
///   • The content fade is locked to that same clock, so text never pops
///     into a window too small to hold it.
struct NotchLiquidGlassCardModifier: ViewModifier {
    @ObservedObject var transitionModel: NotchSurfaceTransitionModel
    var outlineColor: Color
    var isOutlineEnabled: Bool

    /// Height of the camera housing. Needed to derive the pill's bottom
    /// corner radius — the morph's starting shape.
    var occludedTopInset: CGFloat = 0

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
                    let surfaceInset = isOutlineEnabled
                        ? NotchLayoutMath.outlinePad * (1 - transitionModel.morphCardness)
                        : 0
                    let surfaceWidth = max(geometry.size.width - surfaceInset * 2, 1)
                    let surfaceHeight = max(geometry.size.height - surfaceInset, 1)

                    cardShape(bottomCornerRadius: bottomCornerRadius)
                        .fill(Color.black)
                        .frame(width: surfaceWidth, height: surfaceHeight)
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .top
                    )
                }
            }
            // Content paints full-bleed backgrounds (the nebula, the bottom
            // bar), which squared off the card's corners. Clipping to the
            // same silhouette keeps the rounded bottom through the morph.
            .clipShape(cardShape(bottomCornerRadius: bottomCornerRadius))
    }

    private var bottomCornerRadius: CGFloat {
        NotchLayoutMath.lerp(
            NotchLayoutMath.pillCornerRadius(forHeight: occludedTopInset),
            NotchLayoutMath.cardCornerRadius,
            transitionModel.morphCardness
        )
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
            surfaceContent
            if surface != .connectorSuggestion {
                NotchHomeResizeChrome(
                    onBegan: onResizeBegan,
                    onChanged: onResizeChanged,
                    onEnded: onResizeEnded
                )
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
        case .compactChat:
            NotchCompactChatCard(
                companionManager: companionManager,
                occludedTopInset: occludedTopInset,
                layoutSize: layoutSize,
                hardwareNotchWidth: hardwareNotchWidth,
                transitionModel: transitionModel,
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

/// Passive browser-context prompt. Opens itself without taking focus and
/// keeps all decisions on one compact HeyClicky-style surface.
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
            let contentWidth = layoutSize.width > 0 ? layoutSize.width : viewport.size.width
            let contentHeight = layoutSize.height > 0 ? layoutSize.height : viewport.size.height

            suggestionBody
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
                            .font(DS.Fonts.title)
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
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
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
        .dsCapsuleButtonStyle(isPrimary ? .primary : .secondary)
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

/// Minimal notch expansion: chat transcript + composer, no Home chrome.
struct NotchCompactChatCard: View {
    @ObservedObject var companionManager: CompanionManager
    var occludedTopInset: CGFloat = 0
    var layoutSize: CGSize = .zero
    var hardwareNotchWidth: CGFloat = 0
    @ObservedObject var transitionModel: NotchSurfaceTransitionModel
    var onClose: () -> Void

    var body: some View {
        GeometryReader { viewport in
            let contentWidth = layoutSize.width > 0 ? layoutSize.width : viewport.size.width
            let contentHeight = layoutSize.height > 0 ? layoutSize.height : viewport.size.height

            compactBody
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
        .onExitCommand(perform: onClose)
    }

    private var compactBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: occludedTopInset)

            MateHomeView(
                companionManager: companionManager,
                isCompactLayout: true,
                onOpenSection: { section in
                    companionManager.openDesktopWindow(section: section)
                },
                onClose: onClose,
                shouldFocusComposerOnAppear: true
            )
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            BrandNebulaSurface.notchCard
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
