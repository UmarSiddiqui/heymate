//
//  CursorDockPhaseTests.swift
//  leanring-buddyTests
//
import CoreGraphics
import Testing
@testable import HeyMate

struct CursorDockPhaseTests {
    @Test func persistedPreferenceRestoresStablePhase() {
        #expect(CursorDockStateMachine.initialPhase(isEnabled: true) == .deployed)
        #expect(CursorDockStateMachine.initialPhase(isEnabled: false) == .docked)
    }

    @Test func enableRequestAlwaysStartsLaunch() {
        #expect(CursorDockStateMachine.phaseWhenRequesting(
            enabled: true,
            overlayIsVisible: false
        ) == .launching)
    }

    @Test func disableRequestRecallsVisibleBuddy() {
        #expect(CursorDockStateMachine.phaseWhenRequesting(
            enabled: false,
            overlayIsVisible: true
        ) == .returning)
    }

    @Test func disableRequestSkipsAnimationWhenOverlayIsAlreadyHidden() {
        #expect(CursorDockStateMachine.phaseWhenRequesting(
            enabled: false,
            overlayIsVisible: false
        ) == .docked)
    }

    @Test func transitionCompletionSettlesAtExpectedEndpoint() {
        #expect(CursorDockStateMachine.completedPhase(after: .launching) == .deployed)
        #expect(CursorDockStateMachine.completedPhase(after: .returning) == .docked)
    }

    @Test func stablePhasesAcceptInputButTransitionsDoNot() {
        #expect(CursorDockPhase.docked.acceptsDeploymentToggle)
        #expect(CursorDockPhase.deployed.acceptsDeploymentToggle)
        #expect(!CursorDockPhase.launching.acceptsDeploymentToggle)
        #expect(!CursorDockPhase.returning.acceptsDeploymentToggle)
    }

    @Test func launchBayUsesNotchFooterAnchor() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

        let position = CursorDockGeometry.launchBayPosition(
            screenFrame: screen,
            dockAnchorScreenPoint: CGPoint(x: 472, y: 602)
        )

        #expect(position == CGPoint(x: 472, y: 380))
    }

    @Test func launchBayConvertsAnchorForOffsetDisplay() {
        let screen = CGRect(x: -1512, y: 120, width: 1512, height: 982)

        let position = CursorDockGeometry.launchBayPosition(
            screenFrame: screen,
            dockAnchorScreenPoint: CGPoint(x: -1200, y: 950)
        )

        #expect(position == CGPoint(x: 312, y: 152))
    }

    @Test func missingAnchorFallsBackToTopCenter() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

        let position = CursorDockGeometry.launchBayPosition(
            screenFrame: screen,
            dockAnchorScreenPoint: nil
        )

        #expect(position == CGPoint(x: 756, y: 12))
    }
}
