//
//  ContextualConnectorSuggestion.swift
//  leanring-buddy
//
//  URL-only browser context for optional Composio suggestions. Reads the
//  frontmost browser's AX document URL; never reads screenshots, page text,
//  history, or background tabs.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

struct ContextualConnectorSuggestion: Equatable, Sendable {
    let hostname: String
    let toolkitSlug: String
    let toolkitName: String
    let capabilities: [String]

    var suppressionIdentifier: String { "\(hostname)|\(toolkitSlug)" }

    var toolkit: ComposioToolkit {
        ComposioToolkit(
            slug: toolkitSlug,
            name: toolkitName,
            description: "Connect \(toolkitName) through Composio.",
            logoURL: nil,
            toolCount: 0,
            categories: [],
            usesComposioManagedAuth: true,
            requiresNoAuthentication: false
        )
    }
}

protocol BrowserPageURLProviding {
    func currentFrontmostBrowserURL() -> URL?
}

struct AccessibilityBrowserPageURLProvider: BrowserPageURLProviding {
    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser"
    ]

    func currentFrontmostBrowserURL() -> URL? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              Self.browserBundleIdentifiers.contains(bundleIdentifier) else { return nil }

        let accessibilityApplication = AXUIElementCreateApplication(application.processIdentifier)
        guard let focusedWindow = accessibilityElementAttribute(
            accessibilityApplication,
            attribute: kAXFocusedWindowAttribute as CFString
        ) else { return nil }

        if let documentURL = urlAttribute(focusedWindow, attribute: kAXDocumentAttribute as CFString) {
            return documentURL
        }

        // Chromium exposes URL on its web-area child instead of window.
        // Search roles only, stop at web area, and never request title/value
        // or descend into page content.
        var pendingElements: [AXUIElement] = [focusedWindow]
        var visitedElementCount = 0
        while !pendingElements.isEmpty, visitedElementCount < 80 {
            let element = pendingElements.removeFirst()
            visitedElementCount += 1
            let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString)
            if role == "AXWebArea" {
                return urlAttribute(element, attribute: kAXURLAttribute as CFString)
                    ?? urlAttribute(element, attribute: kAXDocumentAttribute as CFString)
            }
            guard role != "AXWebArea",
                  let children = accessibilityElementArrayAttribute(
                    element,
                    attribute: kAXChildrenAttribute as CFString
                  ) else { continue }
            pendingElements.append(contentsOf: children)
        }
        return nil
    }

    private func accessibilityElementAttribute(
        _ element: AXUIElement,
        attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return (value as! AXUIElement?)
    }

    private func accessibilityElementArrayAttribute(
        _ element: AXUIElement,
        attribute: CFString
    ) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func stringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func urlAttribute(_ element: AXUIElement, attribute: CFString) -> URL? {
        guard let rawValue = stringAttribute(element, attribute: attribute) else { return nil }
        return URL(string: rawValue)
    }
}

@MainActor
final class ContextualConnectorSuggestionMonitor: ObservableObject {
    nonisolated static let suppressedIdentifiersPreferenceKey = "contextualConnectorSuppressedIdentifiers"
    nonisolated static let snoozeDatesPreferenceKey = "contextualConnectorSnoozeDates"
    nonisolated static let defaultSnoozeDuration: TimeInterval = 60 * 60 * 24

    @Published private(set) var suggestion: ContextualConnectorSuggestion?

    private let browserPageURLProvider: BrowserPageURLProviding
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private var refreshTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    init(
        browserPageURLProvider: BrowserPageURLProviding = AccessibilityBrowserPageURLProvider(),
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.browserPageURLProvider = browserPageURLProvider
        self.userDefaults = userDefaults
        self.now = now
    }

    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        suggestion = nil
    }

    func refresh() {
        guard let url = browserPageURLProvider.currentFrontmostBrowserURL(),
              let candidate = Self.suggestion(for: url),
              !isSuppressed(candidate),
              !isSnoozed(candidate) else {
            suggestion = nil
            return
        }
        suggestion = candidate
    }

    func declinePermanently(_ suggestion: ContextualConnectorSuggestion) {
        var suppressedIdentifiers = Set(
            userDefaults.stringArray(forKey: Self.suppressedIdentifiersPreferenceKey) ?? []
        )
        suppressedIdentifiers.insert(suggestion.suppressionIdentifier)
        userDefaults.set(suppressedIdentifiers.sorted(), forKey: Self.suppressedIdentifiersPreferenceKey)
        self.suggestion = nil
    }

    func snooze(_ suggestion: ContextualConnectorSuggestion) {
        var snoozeDates = userDefaults.dictionary(forKey: Self.snoozeDatesPreferenceKey) as? [String: Date] ?? [:]
        snoozeDates[suggestion.suppressionIdentifier] = now().addingTimeInterval(Self.defaultSnoozeDuration)
        userDefaults.set(snoozeDates, forKey: Self.snoozeDatesPreferenceKey)
        self.suggestion = nil
    }

    nonisolated static func suggestion(for url: URL) -> ContextualConnectorSuggestion? {
        guard let hostname = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else {
            return nil
        }

        let rules: [(hosts: [String], slug: String, name: String, capabilities: [String])] = [
            (["youtube.com", "youtu.be"], "youtube", "YouTube", ["Search videos", "Read channel stats", "Manage subscriptions"]),
            (["mail.google.com"], "gmail", "Gmail", ["Search mail", "Draft replies", "Organize messages"]),
            (["calendar.google.com"], "googlecalendar", "Google Calendar", ["Read events", "Find free time", "Create events"]),
            (["drive.google.com"], "googledrive", "Google Drive", ["Find files", "Read documents", "Organize Drive"]),
            (["github.com"], "github", "GitHub", ["Read issues", "Review pull requests", "Inspect repositories"]),
            (["slack.com"], "slack", "Slack", ["Search messages", "Read channels", "Draft replies"]),
            (["notion.so", "notion.site"], "notion", "Notion", ["Search pages", "Read databases", "Create pages"]),
            (["figma.com"], "figma", "Figma", ["Read files", "Inspect components", "Find designs"]),
            (["trello.com"], "trello", "Trello", ["Read boards", "Create cards", "Update lists"]),
            (["asana.com"], "asana", "Asana", ["Read projects", "Create tasks", "Update work"])
        ]

        guard let rule = rules.first(where: { rule in
            rule.hosts.contains { candidateHost in
                hostname == candidateHost || hostname.hasSuffix(".\(candidateHost)")
            }
        }) else {
            return nil
        }

        return ContextualConnectorSuggestion(
            hostname: rule.hosts[0],
            toolkitSlug: rule.slug,
            toolkitName: rule.name,
            capabilities: rule.capabilities
        )
    }

    private func isSuppressed(_ suggestion: ContextualConnectorSuggestion) -> Bool {
        let identifiers = userDefaults.stringArray(forKey: Self.suppressedIdentifiersPreferenceKey) ?? []
        return identifiers.contains(suggestion.suppressionIdentifier)
    }

    private func isSnoozed(_ suggestion: ContextualConnectorSuggestion) -> Bool {
        let snoozeDates = userDefaults.dictionary(forKey: Self.snoozeDatesPreferenceKey) as? [String: Date] ?? [:]
        guard let snoozeDate = snoozeDates[suggestion.suppressionIdentifier] else { return false }
        return snoozeDate > now()
    }
}
