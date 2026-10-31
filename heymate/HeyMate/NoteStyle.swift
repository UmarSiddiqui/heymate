//
//  NoteStyle.swift
//  HeyMate
//
//  Card content colors and fonts for the notes canvas. These color the paper
//  cards and marks only; app chrome stays on DS tokens.
//
//  Fonts: HeyClicky names Patrick Hand (cards) and Barlow (library cards),
//  both OFL. They are not bundled in this build, so each falls back to a
//  system face (see `NoteFont`). If they are installed on the Mac they are used.
//

import AppKit
import SwiftUI

enum NoteStyle {
    /// Ink: marks and arrows drawn on paper.
    static let ink = Color(hex: "#3380FF")
    static let inkGlow = Color(hex: "#3380FF").opacity(0.35)

    static let stocks: [String: Color] = [
        "butter": Color(hex: "#FFE27A"),
        "mint": Color(hex: "#BFEFCF"),
        "peach": Color(hex: "#FFD0BC"),
        "lilac": Color(hex: "#D9D1FB"),
        "sky": Color(hex: "#CFE6FF"),
        "white": Color(hex: "#FAF5EA"),
        "news": Color(hex: "#F3EEE4"),
    ]
    static func stock(_ name: String) -> Color { stocks[name] ?? stocks["white"]! }
    /// Text on every paper stock is dark; the stocks are all light.
    static let onPaper = Color(hex: "#1F1D1A")
    static let onPaperMuted = Color(hex: "#6B665C")
}

enum NoteFont {
    /// Patrick Hand when installed, else Noteworthy (ships with macOS), else system rounded.
    static func hand(_ size: CGFloat) -> Font {
        for name in ["Patrick Hand", "Noteworthy"] where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, design: .rounded)
    }
    /// Barlow when installed, else system with tight tracking.
    static func library(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if NSFont(name: "Barlow", size: size) != nil { return .custom("Barlow", size: size).weight(weight) }
        return .system(size: size, weight: weight)
    }
}
