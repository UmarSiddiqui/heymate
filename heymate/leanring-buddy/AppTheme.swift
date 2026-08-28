//
//  AppTheme.swift
//  leanring-buddy
//
//  One color the user picks on onboarding (and can change later). Drives
//  the notch outline, cursor, and accent fills. Outline can be switched
//  off without losing the color.
//
//  Notch geometry still comes from NSScreen: safeAreaInsets.top is the
//  camera-housing height; auxiliaryTopLeftArea / auxiliaryTopRightArea
//  bracket the cutout. Apple: content in that inset is obscured — we
//  only draw a rim on the housing, never put controls there.
//

import Foundation
import SwiftUI

enum AppTheme {

    static let defaultHex = "3380FF"

    struct Swatch: Equatable, Identifiable, Hashable {
        let hex: String
        let name: String
        var id: String { hex }
        var color: Color { Color(hex: hex) }
    }

    /// Curated chips that stay readable as a 1.5pt rim on black bezel.
    static let swatches: [Swatch] = [
        Swatch(hex: "3380FF", name: "Signal"),
        Swatch(hex: "8B7CFF", name: "Iris"),
        Swatch(hex: "34D399", name: "Mint"),
        Swatch(hex: "FFB020", name: "Amber"),
        Swatch(hex: "FF6B5A", name: "Coral"),
        Swatch(hex: "FF5C8A", name: "Rose")
    ]

    /// Latest chosen hex so AppKit overlays can read the color without
    /// hopping through CompanionManager. Updated on every setThemeColorHex.
    nonisolated(unsafe) static var currentHex: String = resolvedHex(
        storedRawValue: UserDefaults.standard.string(
            forKey: CompanionManager.themeColorPreferenceKey
        )
    )

    static var color: Color { Color(hex: currentHex) }

    static func resolvedHex(storedRawValue: String?) -> String {
        let normalized = storedRawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard let normalized,
              let match = swatches.first(where: { $0.hex.uppercased() == normalized }) else {
            return defaultHex
        }
        return match.hex
    }

    static func outlineEnabled(storedObject: Any?) -> Bool {
        if storedObject == nil { return true }
        if let flag = storedObject as? Bool { return flag }
        if let number = storedObject as? NSNumber { return number.boolValue }
        return true
    }
}

struct ThemeColorPicker: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(AppTheme.swatches) { swatch in
                    let isSelected = companionManager.themeColorHex.uppercased() == swatch.hex.uppercased()
                    Button(action: { companionManager.setThemeColorHex(swatch.hex) }) {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(
                                        Color.white.opacity(isSelected ? 0.95 : 0.2),
                                        lineWidth: isSelected ? 2 : 0.8
                                    )
                            )
                            .shadow(color: swatch.color.opacity(isSelected ? 0.7 : 0), radius: 5)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(swatch.name)
                    .accessibilityLabel(swatch.name)
                }
            }

            Text("Same color on the notch, cursor, and buttons.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
        }
    }
}

/// Rim on the hardware camera housing. Path is the idle tab's
/// UnevenRoundedRectangle — top square (flush with the bezel), bottom
/// continuous corners (~8pt). Apple's `safeAreaInsets` mark this region
/// as obscured; the rim sits on the housing edge, not in the safe area.
///
/// This must stay a static stroke. A 24 fps `TimelineView` here lived in the
/// same `NSHostingView` as the expanded Home card; on macOS 26 each tick
/// rebuilt Liquid Glass overlay items until the process ballooned past 20 GB
/// and the main thread never left SwiftUI layout.
struct NotchOutlineGlow: View {
    var color: Color
    var cornerRadius: CGFloat = NotchLayoutMath.pillCornerRadius

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
        shape
            .stroke(
                AngularGradient(
                    colors: [
                        color.opacity(0.08),
                        color.opacity(0.95),
                        color.opacity(0.2),
                        color.opacity(0.08)
                    ],
                    center: .center,
                    angle: .degrees(90)
                ),
                lineWidth: NotchLayoutMath.outlineStrokeWidth
            )
            .shadow(color: color.opacity(0.55), radius: 3.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
