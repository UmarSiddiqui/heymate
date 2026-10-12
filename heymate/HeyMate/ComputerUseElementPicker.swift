//
//  ComputerUseElementPicker.swift
//  HeyMate
//
//  Fast-path AX lookup for a single click in the front window: resolve a
//  target by name or role and return its center point without an LLM turn.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum ComputerUseElementPicker {

    /// Substrings that must never be clicked via the fast loop; matching is
    /// case-insensitive against AX title and description only.
    static let deniedLabelFragments = [
        "send",
        "delete",
        "pay",
        "purchase",
        "confirm-purchase"
    ]

    enum PickResult: Equatable, Sendable {
        case success(center: CGPoint, element: AccessibleElement)
        case denied(reason: String)
        case notFound(String)
        case accessibilityPermissionMissing
    }

    /// Finds the best matching actionable element in the frontmost app's
    /// focused window and returns the center of its frame.
    static func pickCenter(
        matching nameOrRole: String,
        inApplicationWithProcessIdentifier processIdentifier: pid_t? = nil
    ) -> PickResult {
        guard AccessibilityElementFinder.isAccessibilityTrusted else {
            return .accessibilityPermissionMissing
        }

        let trimmedQuery = nameOrRole.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return .notFound("No target name or role was provided.")
        }

        let candidates = actionableElementsInFocusedWindow(
            matching: trimmedQuery,
            inApplicationWithProcessIdentifier: processIdentifier
        )

        guard let element = candidates.first else {
            return .notFound("No matching element in the front window for “\(trimmedQuery)”.")
        }

        if let denial = denialReasonIfBlocked(title: element.title, description: element.description) {
            return .denied(reason: denial)
        }

        let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        return .success(center: center, element: element)
    }

    /// Returns a refusal sentence when `title` or `description` hits the deny
    /// list; nil when the target is allowed.
    static func denialReasonIfBlocked(title: String?, description: String?) -> String? {
        for field in [title, description].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
            let normalizedField = AccessibilityElementFinder.normalize(field)
            for fragment in deniedLabelFragments {
                let normalizedFragment = AccessibilityElementFinder.normalize(fragment)
                if normalizedField.contains(normalizedFragment) {
                    return "Refusing fast click: “\(field)” matches a protected action (\(fragment))."
                }
            }
        }
        return nil
    }

    /// Whether `candidateLabel` matches a name-style query using the same
    /// scoring rules as the accessibility finder.
    static func matchesNameQuery(_ query: String, candidateLabel: String) -> Bool {
        let normalizedSearch = AccessibilityElementFinder.normalize(query)
        guard !normalizedSearch.isEmpty else { return false }
        return AccessibilityElementFinder.matchScore(
            label: candidateLabel,
            normalizedSearch: normalizedSearch
        ) != nil
    }

    // MARK: - Focused window traversal

    private static func actionableElementsInFocusedWindow(
        matching searchText: String,
        inApplicationWithProcessIdentifier processIdentifier: pid_t?
    ) -> [AccessibleElement] {
        guard AccessibilityElementFinder.isAccessibilityTrusted else { return [] }
        guard let application = targetApplication(processIdentifier: processIdentifier) else { return [] }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let focusedWindow = copyElementAttribute(
            applicationElement,
            kAXFocusedWindowAttribute as String
        ) else { return [] }

        let applicationName = application.localizedName ?? "the app"
        var collected: [AccessibleElement] = []
        var nodesVisited = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= AccessibilityElementFinder.maximumTreeDepth,
                  nodesVisited < AccessibilityElementFinder.maximumNodesVisited else { return }
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

        visit(focusedWindow, depth: 0)

        if let roleFilter = axRoleFilter(forQuery: searchText) {
            let roleMatches = collected.filter { normalizeRole($0.role) == roleFilter }
            if roleMatches.isEmpty {
                return []
            }
            if roleMatches.count == 1 {
                return roleMatches
            }
            return []
        }

        let normalizedSearch = AccessibilityElementFinder.normalize(searchText)
        return collected
            .compactMap { element -> (AccessibleElement, Int)? in
                guard let score = AccessibilityElementFinder.matchScore(
                    label: element.label,
                    normalizedSearch: normalizedSearch
                ) else { return nil }
                return (element, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private static func axRoleFilter(forQuery query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = AccessibilityElementFinder.normalize(trimmed)
            .replacingOccurrences(of: " ", with: "")
        let aliases: [String: String] = [
            "button": kAXButtonRole as String,
            "checkbox": kAXCheckBoxRole as String,
            "checkboxes": kAXCheckBoxRole as String,
            "radiobutton": kAXRadioButtonRole as String,
            "textfield": kAXTextFieldRole as String,
            "textarea": kAXTextAreaRole as String,
            "link": "AXLink",
            "menuitem": kAXMenuItemRole as String,
            "popupbutton": kAXPopUpButtonRole as String
        ]
        if let aliased = aliases[normalized] {
            return normalizeRole(aliased)
        }
        let uppercasedQuery = trimmed.uppercased()
        if AccessibilityElementFinder.actionableRoles.contains(where: { normalizeRole($0) == uppercasedQuery }) {
            return uppercasedQuery
        }
        return nil
    }

    private static func normalizeRole(_ role: String) -> String {
        role.uppercased()
    }

    private static func targetApplication(processIdentifier: pid_t?) -> NSRunningApplication? {
        if let processIdentifier {
            return NSRunningApplication(processIdentifier: processIdentifier)
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return frontmost
    }

    private static func describeIfActionable(
        _ element: AXUIElement,
        applicationName: String
    ) -> AccessibleElement? {
        guard let role = copyAttribute(element, kAXRoleAttribute as String) as? String,
              AccessibilityElementFinder.actionableRoles.contains(role) else { return nil }

        guard let frame = AccessibilityElementFinder.globalFrame(of: element),
              frame.width >= AccessibilityElementFinder.minimumInteractiveSide,
              frame.height >= AccessibilityElementFinder.minimumInteractiveSide else { return nil }

        let title = (copyAttribute(element, kAXTitleAttribute as String) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (copyAttribute(element, kAXDescriptionAttribute as String) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (copyAttribute(element, kAXValueAttribute as String) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let help = (copyAttribute(element, kAXHelpAttribute as String) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let label = [title, description, value, help]
            .compactMap { $0 }
            .first { !$0.isEmpty }

        guard let label, !label.isEmpty else { return nil }

        let isEnabled = (copyAttribute(element, kAXEnabledAttribute as String) as? Bool) ?? true

        return AccessibleElement(
            role: role,
            label: label,
            title: title?.isEmpty == true ? nil : title,
            description: description?.isEmpty == true ? nil : description,
            frame: frame,
            isEnabled: isEnabled,
            applicationName: applicationName
        )
    }

    private static func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
