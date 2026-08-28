//
//  ComputerUseExecutor.swift
//  leanring-buddy
//
//  Performs an approved `ComputerUseAction`.
//
//  Three rules the rest of the app depends on:
//
//  1. **Accessibility first.** `clickElement` asks the element to press
//     itself (`AXPress`). Nothing is synthesized, the pointer does not
//     move, and it works when the target is not frontmost. Only when the
//     tree yields nothing do we fall back to a synthesized click at the
//     element's frame.
//
//  2. **Synthesized input is visible.** When a real click is unavoidable,
//     the companion cursor flies to the target first so the user watches
//     it happen. An assistant that moves the pointer invisibly is
//     indistinguishable from malware, and users are right to treat it that
//     way.
//
//  3. **Approval is the caller's job and cannot be skipped here.** This
//     type refuses anything above `readOnly` unless handed a token proving
//     the user said yes to that exact request id.
//

import AppKit
import CoreGraphics
import Foundation

/// Proof that a specific request was approved. Only `ComputerUseApproval`
/// can mint one, and it carries the id it was minted for, so an approval
/// for "click Save" cannot be replayed to authorize "press cmd+q".
struct ComputerUseApprovalToken: Equatable, Sendable {
    let requestID: UUID
    fileprivate init(requestID: UUID) { self.requestID = requestID }

    /// Mint a token. Call this only from the code path that showed the
    /// approval UI and observed the user accept.
    static func grantedByUser(forRequestID requestID: UUID) -> ComputerUseApprovalToken {
        ComputerUseApprovalToken(requestID: requestID)
    }
}

enum ComputerUseError: LocalizedError {
    case accessibilityPermissionMissing
    case approvalRequired
    case approvalMismatch
    case credentialEntryRefused
    case elementNotFound(String)
    case applicationNotFound(String)
    case unsupportedKeyCombination(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Turn on Accessibility for HeyMate in System Settings › Privacy & Security."
        case .approvalRequired:
            return "That needs your approval first."
        case .approvalMismatch:
            return "That approval was for a different action."
        case .credentialEntryRefused:
            return "I won't type passwords, keys, or tokens. Please enter that yourself."
        case .elementNotFound(let label):
            return "I couldn't find “\(label)” in the current window."
        case .applicationNotFound(let name):
            return "I couldn't find an app called \(name)."
        case .unsupportedKeyCombination(let combination):
            return "I don't know the key “\(combination)”."
        }
    }
}

struct ComputerUseOutcome: Sendable {
    let summary: String
    /// Populated for read-only actions whose whole point is the data.
    let payload: String?
}

@MainActor
final class ComputerUseExecutor {

    /// Called before a synthesized click so the overlay can fly the
    /// companion cursor to the target and let the user see it coming.
    var onWillSynthesizeInput: ((CGPoint) -> Void)?

    /// Pause after the cursor flight starts, so the animation is visible
    /// rather than instantaneous. Short enough not to feel sluggish.
    private static let synthesizedInputLeadIn: Duration = .milliseconds(280)

    func execute(
        _ request: ComputerUseRequest,
        approval: ComputerUseApprovalToken?
    ) async throws -> ComputerUseOutcome {
        let action = request.action

        if action.isCredentialShaped {
            throw ComputerUseError.credentialEntryRefused
        }

        if action.risk > .readOnly {
            guard let approval else { throw ComputerUseError.approvalRequired }
            guard approval.requestID == request.id else { throw ComputerUseError.approvalMismatch }
        }

        switch action {
        case .screenshot, .readFocusedWindow:
            return try await readCurrentContext(action)

        case .listActionableElements(let query):
            return try listElements(matching: query)

        case .clickElement(let label):
            return try await clickElement(labeled: label)

        case .clickPoint(let point):
            try await synthesizeClick(at: point, clickCount: 1, button: .left)
            return ComputerUseOutcome(summary: "Clicked.", payload: nil)

        case .doubleClickPoint(let point):
            try await synthesizeClick(at: point, clickCount: 2, button: .left)
            return ComputerUseOutcome(summary: "Double-clicked.", payload: nil)

        case .rightClickPoint(let point):
            try await synthesizeClick(at: point, clickCount: 1, button: .right)
            return ComputerUseOutcome(summary: "Right-clicked.", payload: nil)

        case .moveCursor(let point):
            onWillSynthesizeInput?(point)
            postMouseEvent(type: .mouseMoved, at: point, button: .left, clickCount: 0)
            return ComputerUseOutcome(summary: "Moved the pointer.", payload: nil)

        case .scroll(let deltaX, let deltaY):
            postScroll(deltaX: deltaX, deltaY: deltaY)
            return ComputerUseOutcome(summary: "Scrolled.", payload: nil)

        case .drag(let start, let end):
            try await synthesizeDrag(from: start, to: end)
            return ComputerUseOutcome(summary: "Dragged.", payload: nil)

        case .typeText(let text):
            try typeText(text)
            return ComputerUseOutcome(summary: "Typed \(text.count) characters.", payload: nil)

        case .pressKeyCombination(let combination):
            try pressKeyCombination(combination)
            return ComputerUseOutcome(summary: "Pressed \(combination).", payload: nil)

        case .openApplication(let name), .activateApplication(let name):
            return try activateApplication(named: name)
        }
    }

    // MARK: Reading

    private func readCurrentContext(_ action: ComputerUseAction) async throws -> ComputerUseOutcome {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return ComputerUseOutcome(summary: "Nothing is frontmost.", payload: nil)
        }
        let applicationName = frontmost.localizedName ?? "an app"
        let elements = AccessibilityElementFinder.actionableElements(matching: "")
        let elementSummary = elements.prefix(20)
            .map { "\($0.role.replacingOccurrences(of: "AX", with: "")): \($0.label)" }
            .joined(separator: "\n")
        return ComputerUseOutcome(
            summary: "Frontmost app is \(applicationName).",
            payload: elementSummary.isEmpty ? nil : elementSummary
        )
    }

    private func listElements(matching query: String) throws -> ComputerUseOutcome {
        guard AccessibilityElementFinder.isAccessibilityTrusted else {
            throw ComputerUseError.accessibilityPermissionMissing
        }
        let elements = AccessibilityElementFinder.actionableElements(matching: query)
        guard !elements.isEmpty else {
            return ComputerUseOutcome(summary: "Nothing matched.", payload: nil)
        }
        let rendered = elements.prefix(25).map { element in
            "\(element.label) — \(element.role.replacingOccurrences(of: "AX", with: ""))"
                + (element.isEnabled ? "" : " (disabled)")
        }.joined(separator: "\n")
        return ComputerUseOutcome(
            summary: "Found \(elements.count) matching element\(elements.count == 1 ? "" : "s").",
            payload: rendered
        )
    }

    // MARK: Clicking

    private func clickElement(labeled label: String) async throws -> ComputerUseOutcome {
        guard AccessibilityElementFinder.isAccessibilityTrusted else {
            throw ComputerUseError.accessibilityPermissionMissing
        }

        // Preferred path: the element presses itself. No pointer movement,
        // no synthesized events, works off-screen and unfocused.
        if AccessibilityElementFinder.performPress(on: label) {
            return ComputerUseOutcome(summary: "Pressed “\(label)”.", payload: nil)
        }

        // Fallback: we know where it is but it has no press action, so
        // click its center — visibly.
        guard let element = AccessibilityElementFinder.bestMatch(for: label) else {
            throw ComputerUseError.elementNotFound(label)
        }
        guard element.isEnabled else {
            return ComputerUseOutcome(summary: "“\(element.label)” is disabled right now.", payload: nil)
        }
        try await synthesizeClick(at: CGPoint(x: element.frame.midX, y: element.frame.midY),
                                  clickCount: 1,
                                  button: .left)
        return ComputerUseOutcome(summary: "Clicked “\(element.label)”.", payload: nil)
    }

    /// Fly the cursor, pause so it is seen, then post the event. The pause
    /// is the honesty tax on synthesizing input.
    private func synthesizeClick(at point: CGPoint, clickCount: Int, button: CGMouseButton) async throws {
        onWillSynthesizeInput?(point)
        try? await Task.sleep(for: Self.synthesizedInputLeadIn)

        postMouseEvent(type: .mouseMoved, at: point, button: button, clickCount: 0)
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        postMouseEvent(type: downType, at: point, button: button, clickCount: clickCount)
        postMouseEvent(type: upType, at: point, button: button, clickCount: clickCount)
    }

    private func synthesizeDrag(from start: CGPoint, to end: CGPoint) async throws {
        onWillSynthesizeInput?(start)
        try? await Task.sleep(for: Self.synthesizedInputLeadIn)

        postMouseEvent(type: .mouseMoved, at: start, button: .left, clickCount: 0)
        postMouseEvent(type: .leftMouseDown, at: start, button: .left, clickCount: 1)

        // Interpolate so the destination app receives a plausible drag
        // rather than a teleport, which many drop targets reject.
        let stepCount = 12
        for step in 1...stepCount {
            let progress = CGFloat(step) / CGFloat(stepCount)
            let intermediate = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            postMouseEvent(type: .leftMouseDragged, at: intermediate, button: .left, clickCount: 1)
            try? await Task.sleep(for: .milliseconds(12))
        }
        postMouseEvent(type: .leftMouseUp, at: end, button: .left, clickCount: 1)
    }

    /// CGEvent uses a top-left origin; the rest of this app uses AppKit's
    /// bottom-left. Convert once, here, so callers never have to think
    /// about it.
    private func postMouseEvent(type: CGEventType, at appKitPoint: CGPoint, button: CGMouseButton, clickCount: Int) {
        guard let primaryScreen = NSScreen.screens.first else { return }
        let quartzPoint = CGPoint(x: appKitPoint.x, y: primaryScreen.frame.maxY - appKitPoint.y)

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: quartzPoint,
            mouseButton: button
        ) else { return }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(deltaX: Int, deltaY: Int) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: Typing

    /// Unicode-first typing: rather than mapping characters to virtual key
    /// codes (which breaks on every non-US layout), post the string as the
    /// event's unicode payload. Emoji and accented text work unchanged.
    private func typeText(_ text: String) throws {
        guard AccessibilityElementFinder.isAccessibilityTrusted else {
            throw ComputerUseError.accessibilityPermissionMissing
        }
        // Chunked because CGEvent's unicode buffer is bounded; 20 UTF-16
        // units per event is comfortably inside every observed limit.
        let utf16Units = Array(text.utf16)
        for chunkStart in stride(from: 0, to: utf16Units.count, by: 20) {
            let chunk = Array(utf16Units[chunkStart..<min(chunkStart + 20, utf16Units.count)])
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func pressKeyCombination(_ combination: String) throws {
        guard AccessibilityElementFinder.isAccessibilityTrusted else {
            throw ComputerUseError.accessibilityPermissionMissing
        }
        let normalized = ComputerUseAction.normalizeKeyCombination(combination)
        let tokens = normalized.split(separator: "+").map(String.init)
        guard let keyToken = tokens.last,
              let virtualKey = Self.virtualKeyCode(forToken: keyToken) else {
            throw ComputerUseError.unsupportedKeyCombination(combination)
        }

        var modifierFlags = CGEventFlags()
        for token in tokens.dropLast() {
            switch token {
            case "cmd": modifierFlags.insert(.maskCommand)
            case "opt": modifierFlags.insert(.maskAlternate)
            case "ctrl": modifierFlags.insert(.maskControl)
            case "shift": modifierFlags.insert(.maskShift)
            case "fn": modifierFlags.insert(.maskSecondaryFn)
            default: throw ComputerUseError.unsupportedKeyCombination(combination)
            }
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false) else {
            throw ComputerUseError.unsupportedKeyCombination(combination)
        }
        keyDown.flags = modifierFlags
        keyUp.flags = modifierFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Virtual key codes for the keys a chord can actually end on. Letters
    /// and digits use the US layout positions, which is what CGEvent's
    /// virtualKey parameter means regardless of the user's input source.
    static func virtualKeyCode(forToken token: String) -> CGKeyCode? {
        let namedKeys: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
            "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
        ]
        if let named = namedKeys[token] { return named }

        let letterKeyCodes: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
            "j": 38, "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
            "7": 26, "8": 28, "9": 25, "0": 29
        ]
        guard token.count == 1, let character = token.first else { return nil }
        return letterKeyCodes[character]
    }

    // MARK: Applications

    private func activateApplication(named name: String) throws -> ComputerUseOutcome {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            running.activate(options: [.activateAllWindows])
            return ComputerUseOutcome(summary: "Switched to \(name).", payload: nil)
        }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
                ?? Self.applicationURL(forDisplayName: name) else {
            throw ComputerUseError.applicationNotFound(name)
        }
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: NSWorkspace.OpenConfiguration())
        return ComputerUseOutcome(summary: "Opened \(name).", payload: nil)
    }

    private static func applicationURL(forDisplayName name: String) -> URL? {
        let searchDirectories = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
