//
//  NotchCaptionCard.swift
//  HeyMate
//
//  HeyMate's words, spoken out of the notch. The housing grows downward
//  with the reply instead of a caption floating over whatever app is
//  open. It opens without taking focus; a click makes it key so the text
//  can be selected, and the copy button takes the whole reply.
//

import AppKit
import SwiftUI

struct NotchCaptionCard: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject var companionManager: CompanionManager
    var occludedTopInset: CGFloat = 0
    var layoutSize: CGSize = .zero
    @ObservedObject var transitionModel: NotchSurfaceTransitionModel
    var onClose: () -> Void

    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    private static let textAnchor = "caption-text"

    var body: some View {
        GeometryReader { viewport in
            let size = transitionModel.effectiveLayoutSize(layoutSize, viewport: viewport.size)

            captionBody
                .padding(.horizontal, NotchLayoutMath.shoulderInset(occludedTopInset: occludedTopInset))
                .frame(width: size.width, height: size.height, alignment: .top)
                .background {
                    BrandNebulaSurface.notchCard
                }
                .modifier(NotchContentRevealModifier(transitionModel: transitionModel))
                .position(x: viewport.size.width / 2, y: size.height / 2)
        }
        .modifier(NotchLiquidGlassCardModifier(
            transitionModel: transitionModel,
            outlineColor: companionManager.themeColor,
            isOutlineEnabled: companionManager.isNotchOutlineEnabled,
            occludedTopInset: occludedTopInset
        ))
        .clipped()
        .onDisappear { copyResetTask?.cancel() }
    }

    private var captionBody: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: occludedTopInset)

            HStack(alignment: .top, spacing: NotchLayoutMath.captionColumnSpacing) {
                voiceGlyph
                    .frame(width: NotchLayoutMath.captionGlyphWidth, height: NotchLayoutMath.captionLineHeight)

                VStack(alignment: .leading, spacing: 0) {
                    if let progress = companionManager.cursorCaptionProgress {
                        Text(progress)
                            .font(DS.Fonts.caption.weight(.medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(height: NotchLayoutMath.captionProgressHeight, alignment: .top)
                    }
                    captionText
                }
                .frame(width: NotchLayoutMath.captionTextWidth, alignment: .leading)

                controls
                    .frame(width: NotchLayoutMath.captionControlsWidth, alignment: .trailing)
            }
            .padding(.horizontal, NotchLayoutMath.captionHorizontalPadding)
            .padding(.top, NotchLayoutMath.captionTopPadding)
            .padding(.bottom, NotchLayoutMath.captionBottomPadding)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("HeyMate says")
    }

    /// Scrolls to the newest words once the reply outgrows the card.
    private var captionText: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(companionManager.cursorCaptionText)
                    .font(DS.Fonts.reading)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(NotchLayoutMath.captionLineSpacing)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(Self.textAnchor)
            }
            .onChange(of: companionManager.cursorCaptionText) { _, _ in
                proxy.scrollTo(Self.textAnchor, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var voiceGlyph: some View {
        // The caption replaces the compact panel, so it must carry the same
        // voice feedback while the compact panel is hidden.
        switch companionManager.voiceState {
        case .listening:
            NotchLiveWaveform(
                audioPowerLevel: companionManager.currentAudioPowerLevel,
                themeColor: companionManager.themeColor
            )
        case .responding:
            if companionManager.isSilentModeEnabled {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(companionManager.themeColor)
            } else {
                NotchSpeakingWaveform(reduceMotion: accessibilityReduceMotion)
            }
        case .processing:
            NotchBrandMark()
        case .idle:
            Circle()
                .fill(companionManager.themeColor)
                .frame(width: 6, height: 6)
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button(action: copyCaption) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(DS.Glyph.small)
                    .foregroundColor(didCopy ? DS.Colors.success : DS.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(NotchSoftButtonStyle(shape: .circle))
            .help("Copy")
            .accessibilityLabel(didCopy ? "Copied" : "Copy reply")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(NotchSoftButtonStyle(shape: .circle))
            .help("Hide")
            .accessibilityLabel("Hide reply")
        }
    }

    private func copyCaption() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(companionManager.cursorCaptionText, forType: .string)
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}
