//
//  NotchHomeSize.swift
//  leanring-buddy
//
//  The sheet under the notch. It opens compact, drag edges resize it evenly
//  around the camera, and a double-click puts the standard size back.
//

import CoreGraphics
import Foundation
import SwiftUI

enum NotchHomeEdge: Equatable {
    case left
    case right
    case bottom
    case bottomLeft
    case bottomRight
}

struct NotchHomeSize: Equatable {
    var width: CGFloat
    var heightBelowHousing: CGFloat

    /// Wide, shallow card. Matches the notch layout's expanded surface.
    static let standard = NotchHomeSize(
        width: NotchLayoutMath.expandedWidth,
        heightBelowHousing: NotchLayoutMath.expandedHeight
    )
    /// The automatic size from the taller home. A saved copy of this exact
    /// size is put back to `standard`. A size the user dragged to is kept.
    static let retiredAutomaticDefault = NotchHomeSize(width: 480, heightBelowHousing: 360)
    static let minimum = NotchHomeSize(width: 360, heightBelowHousing: 220)
    static let maximum = NotchHomeSize(width: 1100, heightBelowHousing: 820)

    static let storageKey = "notchHomeSize"

    func clamped() -> NotchHomeSize {
        NotchHomeSize(
            width: min(max(width, Self.minimum.width), Self.maximum.width),
            heightBelowHousing: min(
                max(heightBelowHousing, Self.minimum.heightBelowHousing),
                Self.maximum.heightBelowHousing
            )
        )
    }

    func applying(edge: NotchHomeEdge, translation: CGSize) -> NotchHomeSize {
        var next = self
        switch edge {
        case .left:
            next.width += -translation.width * 2
        case .right:
            next.width += translation.width * 2
        case .bottom:
            next.heightBelowHousing += translation.height
        case .bottomLeft:
            next.width += -translation.width * 2
            next.heightBelowHousing += translation.height
        case .bottomRight:
            next.width += translation.width * 2
            next.heightBelowHousing += translation.height
        }
        return next.clamped()
    }

    static func stored(userDefaults: UserDefaults = .standard) -> NotchHomeSize {
        guard let raw = userDefaults.string(forKey: storageKey) else { return standard }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return standard }
        let decoded = NotchHomeSize(width: parts[0], heightBelowHousing: parts[1]).clamped()
        guard decoded != retiredAutomaticDefault else {
            standard.save(userDefaults: userDefaults)
            return standard
        }
        return decoded
    }

    func save(userDefaults: UserDefaults = .standard) {
        let size = clamped()
        userDefaults.set("\(size.width),\(size.heightBelowHousing)", forKey: Self.storageKey)
    }
}

/// Drag the left, right, or bottom edge. A double-click restores the standard size.
struct NotchHomeResizeChrome: View {
    var onBegan: () -> Void
    var onChanged: (NotchHomeEdge, CGSize) -> Void
    var onEnded: (Bool) -> Void

    @State private var dragIsArmed = false

    var body: some View {
        ZStack {
            VStack {
                Spacer().allowsHitTesting(false)
                hitStrip(edge: .bottom, width: nil, height: 8)
            }
            HStack {
                hitStrip(edge: .left, width: 8, height: nil)
                Spacer().allowsHitTesting(false)
                hitStrip(edge: .right, width: 8, height: nil)
            }
            VStack {
                Spacer().allowsHitTesting(false)
                HStack {
                    hitStrip(edge: .bottomLeft, width: 16, height: 16)
                    Spacer().allowsHitTesting(false)
                    hitStrip(edge: .bottomRight, width: 16, height: 16)
                }
            }
        }
    }

    private func hitStrip(edge: NotchHomeEdge, width: CGFloat?, height: CGFloat?) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(resizeGesture(edge))
            .onTapGesture(count: 2) { onEnded(true) }
    }

    private func resizeGesture(_ edge: NotchHomeEdge) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !dragIsArmed {
                    dragIsArmed = true
                    onBegan()
                }
                onChanged(edge, value.translation)
            }
            .onEnded { _ in
                dragIsArmed = false
                onEnded(false)
            }
    }
}
