//
//  HeyMateLaunchTests.swift
//  HeyMateUITests
//
//  HeyMate runs as a menu-bar agent (LSUIElement) with no main window and
//  no Dock tile, so the one thing a UI test can check about a launch is that
//  the process comes up, stays up, and quits cleanly when asked.
//

import XCTest

final class HeyMateLaunchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesStaysRunningAndQuits() throws {
        let app = XCUIApplication()
        app.launch()

        let isUp = app.wait(for: .runningForeground, timeout: 10) || app.state == .runningBackground
        XCTAssertTrue(isUp, "HeyMate should be running after launch, was \(app.state.rawValue)")

        // XCTest has no window to close for a menu-bar app, so quit it here
        // and wait, instead of leaving teardown to fail on it.
        app.terminate()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 10),
            "HeyMate should have quit after terminate(), was \(app.state.rawValue)"
        )
    }
}
