//
//  DriveAppDriver.swift
//  HeyMate
//
//  Reads and works one app's window for a drive.
//
//  Reading is a bounded accessibility walk of the target window. Acting
//  prefers the element's own AXPress, which needs no cursor and works when
//  the window is behind others; synthesized input is the fallback, and it
//  goes through `ComputerUseExecutor` so it carries HeyMate's event tag and
//  the take-back watcher never mistakes it for the person.
//

import AppKit
import ApplicationServices
import Foundation

/// Lets the controller run against a fake app in tests.
@MainActor
protocol DriveAppDriving: AnyObject {
    var lastPoint: CGPoint? { get }
    var userTookOver: Bool { get set }
    var onWillAct: ((CGPoint) -> Void)? { get set }
    func snapshot(processIdentifier: pid_t) async -> DriveSnapshot?
    func perform(_ decision: DriveDecision, in snapshot: DriveSnapshot, request: DriveRequest, screenshot: ScreenSnapshot?) async throws -> String
}

@MainActor
final class DriveAppDriver: DriveAppDriving {
    /// Where HeyMate last acted, in AppKit global coordinates.
    private(set) var lastPoint: CGPoint?
    /// Set the moment the person takes the wheel. Nothing acts after that.
    var userTookOver = false
    /// Called with the target just before acting, so the overlay can show it.
    var onWillAct: ((CGPoint) -> Void)?

    private let executor: ComputerUseExecutor
    /// AX handles for the last snapshot, keyed by token.
    private var handles: [Int: AXUIElement] = [:]

    static let maximumNodesVisited = 3_000
    static let maximumTreeDepth = 28

    init(executor: ComputerUseExecutor? = nil) {
        let executor = executor ?? ComputerUseExecutor()
        self.executor = executor
        executor.onWillSynthesizeInput = { [weak self] point in self?.onWillAct?(point) }
    }

    // MARK: Reading

    func snapshot(processIdentifier: pid_t) -> DriveSnapshot? {
        guard AccessibilityElementFinder.isAccessibilityTrusted,
              let application = NSRunningApplication(processIdentifier: processIdentifier) else { return nil }
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let window = Self.element(applicationElement, kAXFocusedWindowAttribute)
            ?? Self.element(applicationElement, kAXMainWindowAttribute)
            ?? (Self.attribute(applicationElement, kAXWindowsAttribute) as? [AXUIElement])?.first
        let root = window ?? applicationElement
        let focused = Self.element(applicationElement, kAXFocusedUIElementAttribute)

        var elements: [DriveElement] = []
        var visible: [String] = []
        var newHandles: [Int: AXUIElement] = [:]
        var seen = Set<String>()
        var visited = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= Self.maximumTreeDepth, visited < Self.maximumNodesVisited else { return }
            visited += 1
            let role = Self.attribute(element, kAXRoleAttribute) as? String ?? ""
            let subrole = Self.attribute(element, kAXSubroleAttribute) as? String
            let title = Self.text(element, kAXTitleAttribute)
            let description = Self.text(element, kAXDescriptionAttribute)
            let value = Self.text(element, kAXValueAttribute)
            let placeholder = Self.text(element, kAXPlaceholderValueAttribute)
            for text in [title, description, value] { if let text { visible.append(text) } }

            let driveRole = subrole == "AXSearchField" ? "AXSearchField" : role
            if AccessibilityElementFinder.actionableRoles.contains(role) || driveRole == "AXSearchField",
               let label = [title, description, placeholder, Self.text(element, kAXHelpAttribute), value]
                .compactMap({ $0 }).first,
               (Self.attribute(element, kAXEnabledAttribute) as? Bool) ?? true,
               let frame = AccessibilityElementFinder.globalFrame(of: element),
               frame.width >= AccessibilityElementFinder.minimumInteractiveSide,
               frame.height >= AccessibilityElementFinder.minimumInteractiveSide,
               seen.insert("\(driveRole)|\(label)|\(Int(frame.midX)),\(Int(frame.midY))").inserted {
                let token = elements.count + 1
                elements.append(DriveElement(
                    token: token,
                    role: driveRole,
                    label: label,
                    value: value,
                    frame: frame,
                    isFocused: focused.map { CFEqual($0, element) } ?? false
                ))
                newHandles[token] = element
            }
            guard let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        handles = newHandles
        return DriveSnapshot(
            applicationName: application.localizedName ?? "the app",
            processIdentifier: processIdentifier,
            windowTitle: window.flatMap { Self.text($0, kAXTitleAttribute) },
            elements: elements,
            visibleStrings: visible
        )
    }

    // MARK: Acting

    func perform(_ decision: DriveDecision, in snapshot: DriveSnapshot, request: DriveRequest, screenshot: ScreenSnapshot?) async throws -> String {
        guard !userTookOver else { throw CancellationError() }
        try Task.checkCancellation()
        switch decision {
        case .press(let token):
            guard let element = snapshot.element(withToken: token) else { throw DriveActionError.missingElement(token) }
            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            lastPoint = center
            onWillAct?(center)
            if let handle = handles[token], AXUIElementPerformAction(handle, kAXPressAction as CFString) == .success {
                return "Pressed \"\(element.label)\"."
            }
            _ = try await run(.clickPoint(center))
            return "Clicked \"\(element.label)\"."

        case .type(let token, let modelText, let submit):
            var text = modelText
            if let token, let element = snapshot.element(withToken: token) {
                if let supplied = DriveEngine.suppliedValue(for: element, values: request.values) { text = supplied }
                let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
                lastPoint = center
                onWillAct?(center)
                let handle = handles[token]
                let focused = handle.map {
                    AXUIElementSetAttributeValue($0, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
                } ?? false
                if !focused { _ = try await run(.clickPoint(center)) }
                try await Task.sleep(for: .milliseconds(120))
                // Replace what is there rather than appending to it.
                _ = try await run(.pressKeyCombination("cmd+a"))
            }
            _ = try await run(.typeText(text))
            if submit { _ = try await run(.pressKeyCombination("return")) }
            return "Typed \(text.count) characters\(submit ? " and pressed Return" : "")."

        case .key(let keys):
            _ = try await run(.pressKeyCombination(keys))
            return "Pressed \(keys)."

        case .scroll(let direction):
            guard let action = ComputerUseTagParser.scrollAction(forDirection: direction) else {
                throw DriveActionError.unsupported("scroll \(direction)")
            }
            _ = try await run(action)
            return "Scrolled \(direction)."

        case .openApplication(let name):
            let outcome = try await run(.openApplication(name: name))
            try await Task.sleep(for: .milliseconds(900))
            return outcome.summary

        case .clickPoint(let pixel):
            guard let screenshot else { throw DriveActionError.unsupported("pixel click without a screenshot") }
            let point = ScreenCoordinateMath.globalAppKitPoint(
                fromScreenshotPixelPoint: pixel,
                geometry: DisplayGeometry(
                    screenshotPixelWidth: screenshot.screenshotWidthInPixels,
                    screenshotPixelHeight: screenshot.screenshotHeightInPixels,
                    displayWidthInPoints: screenshot.displayWidthInPoints,
                    displayHeightInPoints: screenshot.displayHeightInPoints,
                    displayFrame: screenshot.displayFrame
                )
            )
            lastPoint = point
            _ = try await run(.clickPoint(point))
            return "Clicked at \(Int(pixel.x)),\(Int(pixel.y))."

        case .drag(let fromToken, let toToken):
            guard let from = snapshot.element(withToken: fromToken) else { throw DriveActionError.missingElement(fromToken) }
            guard let to = snapshot.element(withToken: toToken) else { throw DriveActionError.missingElement(toToken) }
            let end = CGPoint(x: to.frame.midX, y: to.frame.midY)
            lastPoint = end
            _ = try await run(.drag(from: CGPoint(x: from.frame.midX, y: from.frame.midY), to: end))
            return "Dragged \"\(from.label)\" onto \"\(to.label)\"."

        case .wait:
            try await Task.sleep(for: .seconds(1))
            return "Waited."

        case .done, .blocked:
            return ""
        }
    }

    /// The drive's own yes covers each step it takes; the executor still
    /// refuses credential-shaped text on its own.
    private func run(_ action: ComputerUseAction) async throws -> ComputerUseOutcome {
        guard !userTookOver else { throw CancellationError() }
        let request = ComputerUseRequest(action: action, statedReason: "drive step")
        return try await executor.execute(request, approval: .grantedByUser(forRequestID: request.id))
    }

    // MARK: AX plumbing

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func text(_ element: AXUIElement, _ name: String) -> String? {
        guard let raw = attribute(element, name) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 400 else { return nil }
        return trimmed
    }
}

enum DriveActionError: LocalizedError {
    case missingElement(Int)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .missingElement(let token): return "element \(token) is gone"
        case .unsupported(let what): return "can't do \(what)"
        }
    }
}
