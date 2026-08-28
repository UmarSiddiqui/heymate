//
//  AccessibilityElementFinder.swift
//  leanring-buddy
//
//  Finds a real UI element by name instead of guessing a pixel.
//
//  Pixel pointing is what a vision model can do; the accessibility tree is
//  what the operating system already knows. Asking AX first means "click
//  Send" resolves to the actual button — with its real frame, role, and
//  enabled state — rather than to coordinates that drift the moment the
//  window moves. Pixels stay as the fallback for apps that ship no useful
//  tree (Electron with accessibility off, games, remote desktops).
//
//  Traversal is hard-bounded. An unbounded AX walk on a large document can
//  visit hundreds of thousands of nodes and stall the main thread, which
//  is exactly the failure that makes assistive software feel broken.
//

import AppKit
import ApplicationServices
import Foundation

struct AccessibleElement: Equatable, Sendable {
    /// AX role, e.g. `AXButton`, `AXTextField`, `AXMenuItem`.
    let role: String
    /// Best human label found across title, description, and value.
    let label: String
    /// Frame in AppKit global coordinates (origin bottom-left), ready to
    /// hand to the cursor overlay without further conversion.
    let frame: CGRect
    let isEnabled: Bool
    /// Owning application, for the approval prompt: "click Send in Mail".
    let applicationName: String
}

enum AccessibilityElementFinder {

    /// Ceilings tuned against real apps: Mail's message list and Xcode's
    /// navigator both resolve well inside these, and a runaway tree stops
    /// before the user notices a hang.
    static let maximumNodesVisited = 2_500
    static let maximumTreeDepth = 24

    /// Elements smaller than this are almost always layout artifacts, not
    /// things a person could click.
    static let minimumInteractiveSide: CGFloat = 6

    /// Roles worth offering as click targets. Everything else is container
    /// scaffolding and would only add noise to the candidate list.
    static let actionableRoles: Set<String> = [
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXMenuButtonRole as String,
        kAXMenuItemRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        // AXLink has no exported constant in ApplicationServices; the
        // string is the documented role name and is what web content and
        // Help viewers report.
        "AXLink",
        kAXTabGroupRole as String,
        kAXSliderRole as String,
        kAXCellRole as String,
        kAXRowRole as String,
        kAXDisclosureTriangleRole as String,
        kAXToolbarRole as String
    ]

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Bounded text snapshot of frontmost accessibility tree. Used only when
    /// user has enabled screen-text Standing Order. No screenshot or OCR.
    static func visibleText(
        inApplicationWithProcessIdentifier processIdentifier: pid_t? = nil
    ) -> String {
        guard isAccessibilityTrusted,
              let application = targetApplication(processIdentifier: processIdentifier) else { return "" }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var nodesVisited = 0
        var seen = Set<String>()
        var fragments: [String] = []
        var characterCount = 0
        let maximumCharacters = 40_000

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= maximumTreeDepth,
                  nodesVisited < maximumNodesVisited,
                  characterCount < maximumCharacters else { return }
            nodesVisited += 1
            for attribute in [
                kAXTitleAttribute as String,
                kAXDescriptionAttribute as String,
                kAXValueAttribute as String,
                kAXHelpAttribute as String
            ] {
                guard let value = copyAttribute(element, attribute) as? String else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= 2_000, seen.insert(trimmed).inserted else { continue }
                fragments.append(trimmed)
                characterCount += trimmed.count
            }
            guard let children = copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else {
                return
            }
            for child in children {
                visit(child, depth: depth + 1)
            }
        }

        visit(applicationElement, depth: 0)
        return fragments.joined(separator: "\n")
    }

    // MARK: Search

    /// Every actionable element in the frontmost app, ranked by how well it
    /// matches `searchText`. An empty search returns everything, which is
    /// what the "what can I click here?" case wants.
    static func actionableElements(
        matching searchText: String,
        inApplicationWithProcessIdentifier processIdentifier: pid_t? = nil
    ) -> [AccessibleElement] {
        guard isAccessibilityTrusted else { return [] }

        guard let application = targetApplication(processIdentifier: processIdentifier) else { return [] }
        let applicationName = application.localizedName ?? "the app"
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)

        var collected: [AccessibleElement] = []
        var nodesVisited = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= maximumTreeDepth, nodesVisited < maximumNodesVisited else { return }
            nodesVisited += 1

            if let candidate = describeIfActionable(element, applicationName: applicationName) {
                collected.append(candidate)
            }
            guard let children = copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else {
                return
            }
            for child in children {
                visit(child, depth: depth + 1)
            }
        }

        visit(applicationElement, depth: 0)

        let normalizedSearch = normalize(searchText)
        guard !normalizedSearch.isEmpty else { return collected }

        return collected
            .compactMap { element -> (AccessibleElement, Int)? in
                guard let score = matchScore(label: element.label, normalizedSearch: normalizedSearch) else {
                    return nil
                }
                return (element, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// The single best match, or nil when nothing scored. Callers that need
    /// to disambiguate should use `actionableElements` and show a list.
    static func bestMatch(
        for searchText: String,
        inApplicationWithProcessIdentifier processIdentifier: pid_t? = nil
    ) -> AccessibleElement? {
        actionableElements(
            matching: searchText,
            inApplicationWithProcessIdentifier: processIdentifier
        ).first
    }

    private static func targetApplication(processIdentifier: pid_t?) -> NSRunningApplication? {
        if let processIdentifier {
            return NSRunningApplication(processIdentifier: processIdentifier)
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return frontmost
    }

    // MARK: Scoring

    /// Exact beats prefix beats contains beats word-overlap. Returning nil
    /// (rather than 0) for a non-match keeps unrelated elements out of the
    /// result entirely instead of ranking them last.
    static func matchScore(label: String, normalizedSearch: String) -> Int? {
        let normalizedLabel = normalize(label)
        guard !normalizedLabel.isEmpty else { return nil }

        if normalizedLabel == normalizedSearch { return 100 }
        if normalizedLabel.hasPrefix(normalizedSearch) { return 80 }
        if normalizedLabel.contains(normalizedSearch) { return 60 }

        let searchWords = Set(normalizedSearch.split(separator: " ").map(String.init))
        let labelWords = Set(normalizedLabel.split(separator: " ").map(String.init))
        let sharedWords = searchWords.intersection(labelWords)
        guard !sharedWords.isEmpty else { return nil }
        return 20 + sharedWords.count
    }

    static func normalize(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: AX plumbing

    private static func describeIfActionable(
        _ element: AXUIElement,
        applicationName: String
    ) -> AccessibleElement? {
        guard let role = copyAttribute(element, kAXRoleAttribute as String) as? String,
              actionableRoles.contains(role) else { return nil }

        guard let frame = globalFrame(of: element),
              frame.width >= minimumInteractiveSide,
              frame.height >= minimumInteractiveSide else { return nil }

        let label = [
            copyAttribute(element, kAXTitleAttribute as String) as? String,
            copyAttribute(element, kAXDescriptionAttribute as String) as? String,
            copyAttribute(element, kAXValueAttribute as String) as? String,
            copyAttribute(element, kAXHelpAttribute as String) as? String
        ]
        .compactMap { $0 }
        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard let label, !label.isEmpty else { return nil }

        let isEnabled = (copyAttribute(element, kAXEnabledAttribute as String) as? Bool) ?? true

        return AccessibleElement(
            role: role,
            label: label,
            frame: frame,
            isEnabled: isEnabled,
            applicationName: applicationName
        )
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// AX reports position in a top-left origin space; AppKit windows use
    /// bottom-left. Flip against the primary display's height, which is the
    /// origin AX measures from even on multi-monitor setups.
    static func globalFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var topLeftOrigin = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &topLeftOrigin),
              // swiftlint:disable:next force_cast
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }

        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let flippedY = primaryScreen.frame.maxY - topLeftOrigin.y - size.height
        return CGRect(x: topLeftOrigin.x, y: flippedY, width: size.width, height: size.height)
    }

    /// Ask the element to perform its own press. This is the safe path:
    /// no synthesized events, no cursor movement, and it works even when
    /// the target window is not frontmost.
    @discardableResult
    static func performPress(on searchText: String, inApplicationWithProcessIdentifier processIdentifier: pid_t? = nil) -> Bool {
        guard isAccessibilityTrusted,
              let application = targetApplication(processIdentifier: processIdentifier) else { return false }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let normalizedSearch = normalize(searchText)
        var pressed = false
        var nodesVisited = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard !pressed, depth <= maximumTreeDepth, nodesVisited < maximumNodesVisited else { return }
            nodesVisited += 1

            if let role = copyAttribute(element, kAXRoleAttribute as String) as? String,
               actionableRoles.contains(role),
               let title = copyAttribute(element, kAXTitleAttribute as String) as? String,
               matchScore(label: title, normalizedSearch: normalizedSearch) ?? 0 >= 60,
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                pressed = true
                return
            }
            guard let children = copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else {
                return
            }
            for child in children where !pressed {
                visit(child, depth: depth + 1)
            }
        }

        visit(applicationElement, depth: 0)
        return pressed
    }
}
