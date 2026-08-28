//
//  NotchActivity.swift
//  leanring-buddy
//
//  A "live activity" is one line of ambient truth the notch is allowed to
//  show while the companion is otherwise idle: the track that is playing,
//  the timer that is counting down, the file waiting on the shelf, the
//  battery that just started charging, the agent that is still working.
//
//  Activities are deliberately dumb value types. Producers (media watcher,
//  timer store, shelf store, power monitor, agent store) publish them; the
//  notch pill renders whichever one currently has the highest priority.
//  Nothing here touches AppKit, so the priority rules are unit-testable.
//

import Foundation
import SwiftUI

/// Which micro-app produced an activity. Also the identity used to replace
/// an activity in place rather than stacking duplicates.
enum NotchActivityKind: String, CaseIterable, Identifiable, Sendable {
    case agent
    case timer
    case shelf
    case media
    case battery
    case download
    case focus
    case calendar
    case clipboard

    var id: String { rawValue }

    /// SF Symbol shown in the pill's compact leading slot.
    var symbolName: String {
        switch self {
        case .agent: return "sparkle"
        case .timer: return "timer"
        case .shelf: return "tray.full"
        case .media: return "waveform"
        case .battery: return "bolt.fill"
        case .download: return "arrow.down.circle"
        case .focus: return "moon.fill"
        case .calendar: return "calendar"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    /// Higher wins when several micro-apps want the notch at once. Things
    /// the user just caused (a drop on the shelf, a started agent) outrank
    /// ambient background facts (battery level, the next meeting).
    var priority: Int {
        switch self {
        case .agent: return 100
        case .shelf: return 90
        case .timer: return 80
        case .download: return 70
        case .battery: return 60
        case .media: return 50
        case .calendar: return 40
        case .focus: return 30
        case .clipboard: return 20
        }
    }
}

/// One renderable ambient fact. `trailingText` is the only string the
/// collapsed pill shows, so producers must keep it short enough to sit
/// beside a 185pt camera housing (roughly 14 characters).
struct NotchActivity: Equatable, Identifiable, Sendable {
    let kind: NotchActivityKind
    /// Short right-hand label, e.g. "12:04", "3 files", "Bad Guy".
    let trailingText: String
    /// Optional 0…1 progress ring drawn around the leading glyph.
    let progress: Double?
    /// Tint override; nil uses the user's theme color.
    let tintHex: String?
    /// When this activity should stop being shown. nil means "until the
    /// producer replaces or clears it".
    let expiresAt: Date?

    var id: String { kind.rawValue }

    init(
        kind: NotchActivityKind,
        trailingText: String,
        progress: Double? = nil,
        tintHex: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.kind = kind
        self.trailingText = trailingText
        self.progress = progress
        self.tintHex = tintHex
        self.expiresAt = expiresAt
    }

    func isExpired(asOf referenceDate: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return referenceDate >= expiresAt
    }

    var tintColor: Color {
        guard let tintHex else { return AppTheme.color }
        return Color(hex: tintHex)
    }
}

/// Pure selection rules for "which activity does the notch show right now".
/// Kept separate from the store so the priority behavior can be tested
/// without spinning up any producers.
enum NotchActivityArbiter {

    /// Drop expired entries, then return the highest-priority survivor.
    /// Ties break on kind priority alone, which is stable and total, so the
    /// pill never flickers between two equally ranked activities.
    static func frontmostActivity(
        among activities: [NotchActivity],
        asOf referenceDate: Date = Date()
    ) -> NotchActivity? {
        activities
            .filter { !$0.isExpired(asOf: referenceDate) }
            .max { leftActivity, rightActivity in
                leftActivity.kind.priority < rightActivity.kind.priority
            }
    }

    /// Replace-or-insert by kind. Producers call this instead of appending
    /// so a media track update does not stack a second media activity.
    static func upserting(
        _ activity: NotchActivity,
        into activities: [NotchActivity]
    ) -> [NotchActivity] {
        var updated = activities.filter { $0.kind != activity.kind }
        updated.append(activity)
        return updated
    }

    static func removing(
        kind: NotchActivityKind,
        from activities: [NotchActivity]
    ) -> [NotchActivity] {
        activities.filter { $0.kind != kind }
    }
}
