//
//  BrandVisuals.swift
//  HeyMate
//
//  Shared image-backed HeyMate identity for desktop and notch surfaces.
//

import SwiftUI

enum BrandAppearance {
    static func iconAssetName(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? "BrandIconDark" : "BrandIconLight"
    }

    static func nebulaAssetName(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? "BrandNebulaDark" : "BrandNebulaLight"
    }

    static func baseColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .black : .white
    }

    static func chromeColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(hex: "#0A0A0A") : .white
    }
}

/// The window backdrop: a flat matte fill — black in dark mode, white in
/// light. Kept as a view (not a bare color) so every page shares one
/// definition and the backdrop can change in one place.
struct CelestialAtmosphere: View {
    var body: some View {
        DS.Colors.background
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The notch card backdrop. Pure black so the expanded card reads as a
/// continuation of the camera housing, not a panel hung beneath it.
struct BrandNebulaSurface: View {
    /// Shared by Home, compact chat, and the connector prompt so switching
    /// between them never changes the backdrop.
    static let notchCard = BrandNebulaSurface()

    var body: some View {
        Color.black
            .accessibilityHidden(true)
    }
}

struct BrandAppIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    let size: CGFloat
    var state: CompanionVoiceState?

    init(size: CGFloat, state: CompanionVoiceState? = nil) {
        self.size = size
        self.state = state
    }

    var body: some View {
        Image(BrandAppearance.iconAssetName(for: colorScheme))
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.7)
            }
            .shadow(color: Color.black.opacity(0.28), radius: size * 0.08, y: size * 0.03)
            .overlay(alignment: .bottomTrailing) {
                if let state {
                    Circle()
                        .fill(dotColor(for: state))
                        .frame(width: size * 0.24, height: size * 0.24)
                        .overlay(Circle().stroke(BrandAppearance.baseColor(for: colorScheme), lineWidth: 2))
                        .shadow(color: dotColor(for: state).opacity(0.7), radius: 3)
                        .offset(x: size * 0.04, y: size * 0.04)
                }
            }
            .accessibilityLabel("HeyMate")
    }

    private func dotColor(for state: CompanionVoiceState) -> Color {
        DS.Colors.voiceStatus(state)
    }
}
