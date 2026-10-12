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
        // A UI test launches the real app outside the unit-test host, so it
        // would otherwise load the user's real mates and data and apply the
        // active mate's brain to their real preferences. The scratch root
        // sends every data path to a throwaway folder (see
        // HeyMateDataDirectory) and restores preferences when the app exits.
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-ui-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratchRoot) }

        let app = XCUIApplication()
        app.launchEnvironment["HEYMATE_TEST_DATA_ROOT"] = scratchRoot.path
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
