//
//  BuddyCursorTyping.swift
//  HeyMate
//
//  The floating cursor hides while a key is typed and comes back when the
//  pointer moves. One shared monitor serves every screen overlay.
//

import AppKit
import CoreGraphics
import Foundation

enum BuddyCursorTypingPolicy {
    /// Pointer travel, in screen points, that shows the cursor again.
    static let revealDistance: CGFloat = 6

    static func hides(forKeyDown characters: String?) -> Bool {
        guard let characters, !characters.isEmpty else { return false }
        return true
    }

    static func shouldReveal(from origin: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - origin.x, current.y - origin.y) >= revealDistance
    }
}

enum BuddyCursorTypingMonitor {
    private static var monitors: [Any] = []
    private static var retainCount = 0

    static func retain(onKeyDown: @escaping (NSEvent) -> Void) {
        retainCount += 1
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: onKeyDown) {
            monitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKeyDown(event)
            return event
        }
        if let local {
            monitors.append(local)
        }
    }

    static func release() {
        retainCount = max(0, retainCount - 1)
        guard retainCount == 0 else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}
