import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

struct DriveDragTests {
    private func window() -> DriveSnapshot {
        let element = { (token: Int, label: String) in
            DriveElement(token: token, role: "AXRow", label: label, value: nil,
                         frame: CGRect(x: 0, y: CGFloat(token) * 30, width: 100, height: 24), isFocused: false)
        }
        return DriveSnapshot(applicationName: "Finder", processIdentifier: 1, windowTitle: nil,
                             elements: [element(1, "report.pdf"), element(2, "Archive 2026"), element(3, "Trash")],
                             visibleStrings: [])
    }

    @Test func parsesDrag() {
        #expect(DriveEngine.parseDecision(#"{"action":"drag","from":1,"to":2}"#) == .drag(fromToken: 1, toToken: 2))
        #expect(DriveEngine.parseDecision(#"{"action":"drag","from":1}"#) == nil)
    }

    @Test func dragIsVettedAtBothEnds() {
        let request = DriveRequest(goal: "file it")
        #expect(DriveEngine.vet(.drag(fromToken: 1, toToken: 2), snapshot: window(), request: request, hasScreenshot: false) == nil)
        #expect(DriveEngine.vet(.drag(fromToken: 1, toToken: 3), snapshot: window(), request: request, hasScreenshot: false)
            == .refusedControl(label: "Trash"))
        #expect(DriveEngine.vet(.drag(fromToken: 1, toToken: 9), snapshot: window(), request: request, hasScreenshot: false)
            == .untrustedAnswer("there is no element 9"))
        #expect(DriveEngine.vet(.drag(fromToken: 2, toToken: 2), snapshot: window(), request: request, hasScreenshot: false) != nil)
        #expect(DriveEngine.historyLine(for: .drag(fromToken: 1, toToken: 2), snapshot: window())
            == "dragged \"report.pdf\" onto \"Archive 2026\"")
    }

    @Test func onlyEscapeStopsADriveMidAction() {
        var judge = DriveTakeBackJudge()
        let now = Date()
        let acting = now.addingTimeInterval(5)
        #expect(judge.observe(DrivePointerInput(kind: .click, isSynthesized: false, location: .zero), at: now, actuatingUntil: acting) == nil)
        #expect(judge.observe(DrivePointerInput(kind: .key(keyCode: 0), isSynthesized: false, location: .zero), at: now, actuatingUntil: acting) == nil)
        #expect(judge.observe(DrivePointerInput(kind: .key(keyCode: 53), isSynthesized: false, location: .zero), at: now, actuatingUntil: acting) == .escape)
        #expect(judge.observe(DrivePointerInput(kind: .click, isSynthesized: false, location: .zero), at: now) == .pointer)
    }
}

@MainActor
struct CuaDriveAppDriverTests {
    @Test func projectsCuaElementsWindowFirstAndKeepsTheirTokens() {
        let state: [String: Any] = [
            "app_name": "Calculator",
            "window_title": "Calculator",
            "elements": [
                ["role": "AXWindow", "label": "Calculator", "actions": ["AXRaise"], "element_token": "s1:0"],
                ["role": "AXMenuItem", "label": "Copy", "actions": ["AXPress"], "element_token": "s1:90",
                 "frame": ["x": 0.0, "y": 0.0, "w": 10.0, "h": 10.0]],
                ["role": "AXButton", "label": "7", "actions": ["AXPress"], "enabled": true, "element_token": "s1:5",
                 "frame": ["x": 427.0, "y": 495.0, "w": 48.0, "h": 48.0]],
                ["role": "AXButton", "label": "Off", "actions": ["AXPress"], "enabled": false, "element_token": "s1:6"],
                ["role": "AXTextField", "label": "", "placeholder": "Search", "actions": [], "element_token": "s1:7"],
            ],
            "tree_markdown": "- [0] AXWindow \"Calculator\"\n    - AXStaticText = \"27\" (Edit field)\n    - AXHeading (Results)\n    - [5] AXButton (7) [actions=[press]]",
        ]
        var tokens: [Int: String] = [:]
        let snapshot = CuaDriveAppDriver.project(state, processIdentifier: 42, tokens: &tokens)
        #expect(snapshot.elements.map(\.label) == ["7", "Search", "Copy"])
        #expect(snapshot.elements.map(\.token) == [1, 2, 3])
        #expect(tokens == [1: "s1:5", 2: "s1:7", 3: "s1:90"])
        #expect(snapshot.visibleStrings.contains("27"))
        #expect(snapshot.visibleStrings.contains("Results"))
        #expect(snapshot.elements[0].frame.size == CGSize(width: 48, height: 48))
    }

    @Test func keyCombinationsUseCuaNames() {
        #expect(CuaDriveAppDriver.keyParts("Command+Shift+N") == ["cmd", "shift", "n"])
        #expect(CuaDriveAppDriver.keyParts("enter") == ["return"])
        #expect(CuaDriveAppDriver.keyParts("opt+esc") == ["option", "escape"])
    }

    @Test func dragPointsLandInWindowPixels() throws {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        // An element whose top-left global point is (427, 495), 48pt square.
        let element = DriveElement(token: 1, role: "AXButton", label: "7", value: nil,
                                   frame: CGRect(x: 427, y: primaryHeight - 495 - 48, width: 48, height: 48), isFocused: false)
        let point = try CuaDriveAppDriver.windowPixel(for: element, geometry: [
            "window_bounds": ["x": 417.0, "y": 308.0, "width": 230.0, "height": 408.0], "screenshot_scale": 2.0,
        ])
        #expect(point == CGPoint(x: (427 + 24 - 417) * 2, y: (495 + 24 - 308) * 2))
    }
}
