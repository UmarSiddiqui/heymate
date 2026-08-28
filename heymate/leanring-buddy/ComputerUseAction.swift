//
//  ComputerUseAction.swift
//  leanring-buddy
//
//  What the model is allowed to ask the Mac to do, and what each request
//  costs in trust.
//
//  Every action is a value type with a risk level and a plain-English
//  sentence describing it. That sentence is what the approval sheet shows,
//  so the user is never asked to approve `{"type":"key","text":"cmd+q"}` —
//  they are asked to approve "quit Safari".
//
//  Deliberately absent: anything that types into a password field, drags a
//  file to the Trash, or confirms a purchase. Those live behind the same
//  wall as they do everywhere else in this app.
//

import CoreGraphics
import Foundation

enum ComputerUseAction: Equatable, Sendable {

    // Read-only observation
    case screenshot(displayIndex: Int?)
    case readFocusedWindow
    case listActionableElements(matching: String)

    // Pointer
    case clickElement(label: String)
    case clickPoint(CGPoint)
    case doubleClickPoint(CGPoint)
    case rightClickPoint(CGPoint)
    case moveCursor(CGPoint)
    case scroll(deltaX: Int, deltaY: Int)
    case drag(from: CGPoint, to: CGPoint)

    // Keyboard
    case typeText(String)
    case pressKeyCombination(String)

    // Application
    case openApplication(name: String)
    case activateApplication(name: String)

    var risk: ConnectorToolRisk {
        switch self {
        case .screenshot, .readFocusedWindow, .listActionableElements:
            return .readOnly
        case .moveCursor, .scroll, .activateApplication, .openApplication:
            return .reversibleWrite
        case .clickElement, .clickPoint, .doubleClickPoint, .rightClickPoint, .drag, .typeText:
            return .externalSideEffect
        case .pressKeyCombination(let combination):
            // A key combination can be anything from ⌘C to ⌘⇧⌫. Treat the
            // known-destructive ones as destructive rather than assuming
            // every chord is equally harmless.
            return Self.destructiveKeyCombinations.contains(Self.normalizeKeyCombination(combination))
                ? .destructive
                : .externalSideEffect
        }
    }

    /// Chords that delete, quit, or force-close. These always need an
    /// explicit yes regardless of the connector's approval policy.
    static let destructiveKeyCombinations: Set<String> = [
        "cmd+q", "cmd+delete", "cmd+shift+delete", "cmd+opt+esc",
        "cmd+w", "cmd+shift+q", "ctrl+cmd+q"
    ]

    /// Canonical form so "Command+Q", "⌘Q" and "cmd+q" compare equal.
    static func normalizeKeyCombination(_ combination: String) -> String {
        combination
            .lowercased()
            .replacingOccurrences(of: "⌘", with: "cmd+")
            .replacingOccurrences(of: "⌥", with: "opt+")
            .replacingOccurrences(of: "⌃", with: "ctrl+")
            .replacingOccurrences(of: "⇧", with: "shift+")
            .replacingOccurrences(of: "command", with: "cmd")
            .replacingOccurrences(of: "option", with: "opt")
            .replacingOccurrences(of: "control", with: "ctrl")
            .replacingOccurrences(of: " ", with: "")
    }

    /// The sentence shown on the approval sheet. Written as an imperative
    /// the user can evaluate at a glance.
    var approvalDescription: String {
        switch self {
        case .screenshot: return "Take a screenshot"
        case .readFocusedWindow: return "Read the window you're in"
        case .listActionableElements(let query):
            return query.isEmpty ? "List what's clickable here" : "Find “\(query)” on screen"
        case .clickElement(let label): return "Click “\(label)”"
        case .clickPoint(let point): return "Click at \(Int(point.x)), \(Int(point.y))"
        case .doubleClickPoint(let point): return "Double-click at \(Int(point.x)), \(Int(point.y))"
        case .rightClickPoint(let point): return "Right-click at \(Int(point.x)), \(Int(point.y))"
        case .moveCursor: return "Move the pointer"
        case .scroll(_, let deltaY): return deltaY >= 0 ? "Scroll up" : "Scroll down"
        case .drag: return "Drag from one point to another"
        case .typeText(let text): return "Type “\(Self.truncatedForDisplay(text))”"
        case .pressKeyCombination(let combination): return "Press \(combination)"
        case .openApplication(let name): return "Open \(name)"
        case .activateApplication(let name): return "Switch to \(name)"
        }
    }

    static func truncatedForDisplay(_ text: String) -> String {
        text.count <= 60 ? text : String(text.prefix(60)) + "…"
    }

    /// True for anything that could enter a credential. The executor
    /// refuses these outright rather than asking, because "approve typing
    /// your password" is not a question we should ever pose.
    var isCredentialShaped: Bool {
        guard case .typeText(let text) = self else { return false }
        return Self.looksLikeCredential(text)
    }

    /// Heuristic, and intentionally cautious: a false positive costs the
    /// user one manual keystroke, a false negative costs them a secret.
    static func looksLikeCredential(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let credentialMarkers = [
            "sk-", "sk_live", "sk_test", "ghp_", "ghs_", "gho_",
            "aki", "aws_secret", "-----begin", "bearer ", "xoxb-", "xoxp-",
            "password", "passwd", "api_key", "apikey", "secret", "token"
        ]
        return credentialMarkers.contains { lowercased.contains($0) }
    }
}

/// One pending request, from proposal through resolution. The overlay
/// renders this; the executor consumes the resolution.
struct ComputerUseRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let action: ComputerUseAction
    /// Why the model wants this, in its own words. Shown under the
    /// action so the user can judge intent, not just mechanics.
    let statedReason: String
    let requestedAt: Date

    init(action: ComputerUseAction, statedReason: String, id: UUID = UUID(), requestedAt: Date = Date()) {
        self.id = id
        self.action = action
        self.statedReason = statedReason
        self.requestedAt = requestedAt
    }
}
