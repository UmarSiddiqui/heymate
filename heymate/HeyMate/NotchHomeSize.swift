//
//  NotchHomeSize.swift
//  HeyMate
//
//  The sheet under the notch. It opens compact, drag edges resize it evenly
//  around the camera, and a double-click puts the standard size back.
//

import CoreGraphics
import Foundation
import AppKit
import SwiftUI

enum NotchHomeEdge: Equatable {
    case left
    case right
    case bottom
    case bottomLeft
    case bottomRight
}

extension NotchHomeEdge {
    /// The resize cursor shown over this edge, so the handle can be found.
    var cursor: NSCursor {
        switch self {
        case .left, .right: return .resizeLeftRight
        case .bottom: return .resizeUpDown
        case .bottomLeft, .bottomRight:
            if #available(macOS 15.0, *) {
                return .frameResize(position: self == .bottomLeft ? .bottomLeft : .bottomRight, directions: .all)
            }
            return .crosshair
        }
    }
}

struct NotchHomeSize: Equatable {
    var width: CGFloat
    var heightBelowHousing: CGFloat

    /// Wide, shallow card. Matches the notch layout's expanded surface.
    static let standard = NotchHomeSize(
        width: NotchLayoutMath.expandedWidth,
        heightBelowHousing: NotchLayoutMath.expandedHeight
    )
    /// Earlier automatic sizes: the tall home (480×360) and the roomier
    /// card with door tiles (680×250). A saved copy of one of these exact
    /// sizes is put back to `standard`. A size the user dragged to is kept.
    static let retiredAutomaticDefaults: [NotchHomeSize] = [
        NotchHomeSize(width: 480, heightBelowHousing: 360),
        NotchHomeSize(width: 680, heightBelowHousing: 250)
    ]
    static let minimum = NotchHomeSize(width: 440, heightBelowHousing: 140)

    /// The ctrl+command chat hangs at Home's size, but never smaller than
    /// this: it holds a message list and a composer, which the compact
    /// Home no longer has room for.
    static let compactChatMinimum = NotchHomeSize(width: 680, heightBelowHousing: 250)
    static let maximum = NotchHomeSize(width: 1100, heightBelowHousing: 820)

    static let storageKey = "notchHomeSize"

    /// The full chat that opens from the notch in place of a separate chat
    /// window. Bigger than Home, with its own remembered size.
    enum Chat {
        static let standard = NotchHomeSize(width: 860, heightBelowHousing: 560)
        static let minimum = NotchHomeSize(width: 520, heightBelowHousing: 340)
        static let maximum = NotchHomeSize(width: 1800, heightBelowHousing: 1200)
        static let storageKey = "notchChatSize"
    }

    /// Each side at least as big as `floor`'s.
    func atLeast(_ floor: NotchHomeSize) -> NotchHomeSize {
        NotchHomeSize(
            width: max(width, floor.width),
            heightBelowHousing: max(heightBelowHousing, floor.heightBelowHousing)
        )
    }

    func clamped(minimum: NotchHomeSize = Self.minimum, maximum: NotchHomeSize = Self.maximum) -> NotchHomeSize {
        NotchHomeSize(
            width: min(max(width, minimum.width), maximum.width),
            heightBelowHousing: min(
                max(heightBelowHousing, minimum.heightBelowHousing),
                maximum.heightBelowHousing
            )
        )
    }

    /// Full chat sizes are clamped to the chat bounds, not Home's.
    func clampedForChat() -> NotchHomeSize {
        clamped(minimum: Chat.minimum, maximum: Chat.maximum)
    }

    func applying(edge: NotchHomeEdge, translation: CGSize) -> NotchHomeSize {
        unclampedApplying(edge: edge, translation: translation).clamped()
    }

    func unclampedApplying(edge: NotchHomeEdge, translation: CGSize) -> NotchHomeSize {
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
        return next
    }

    static func stored(userDefaults: UserDefaults = .standard) -> NotchHomeSize {
        guard let raw = userDefaults.string(forKey: storageKey) else { return standard }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return standard }
        let decoded = NotchHomeSize(width: parts[0], heightBelowHousing: parts[1]).clamped()
        guard !retiredAutomaticDefaults.contains(decoded) else {
            standard.save(userDefaults: userDefaults)
            return standard
        }
        return decoded
    }

    static func storedChat(userDefaults: UserDefaults = .standard) -> NotchHomeSize {
        guard let raw = userDefaults.string(forKey: Chat.storageKey) else { return Chat.standard }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return Chat.standard }
        return NotchHomeSize(width: parts[0], heightBelowHousing: parts[1]).clampedForChat()
    }

    func saveChat(userDefaults: UserDefaults = .standard) {
        let size = clampedForChat()
        userDefaults.set("\(size.width),\(size.heightBelowHousing)", forKey: Chat.storageKey)
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

    /// Where the drag started, in screen points. The strips move with the
    /// window as it resizes, so a translation measured in their own space
    /// shrinks toward zero; the pointer's screen position does not.
    @State private var dragStart: NSPoint?

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
            .onHover { inside in
                if inside { edge.cursor.push() } else { NSCursor.pop() }
            }
            .gesture(resizeGesture(edge))
            .onTapGesture(count: 2) { onEnded(true) }
    }

    private func resizeGesture(_ edge: NotchHomeEdge) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in
                let pointer = NSEvent.mouseLocation
                if dragStart == nil {
                    dragStart = pointer
                    onBegan()
                }
                guard let dragStart else { return }
                // Screen y grows upward; the size math wants down as positive.
                onChanged(edge, CGSize(width: pointer.x - dragStart.x, height: dragStart.y - pointer.y))
            }
            .onEnded { _ in
                dragStart = nil
                onEnded(false)
            }
    }
}
