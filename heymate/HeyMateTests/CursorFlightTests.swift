//
//  CursorFlightTests.swift
//  HeyMateTests
//
//  The arc the floating cursor flies when it points at something or moves
//  between the pointer and the notch dock.
//

import CoreGraphics
import Testing
@testable import HeyMate

struct CursorFlightTests {

    @Test func flightTakesOffAndLandsOnItsEndpoints() {
        let flight = CursorFlight(from: CGPoint(x: 10, y: 400), to: CGPoint(x: 610, y: 400))
        #expect(flight.sample(at: 0).position == CGPoint(x: 10, y: 400))
        #expect(flight.sample(at: 1).position == CGPoint(x: 610, y: 400))
        #expect(flight.sample(at: 0).scale == 1)
        #expect(abs(flight.sample(at: 1).scale - 1) < 0.0001)
    }

    @Test func longerFlightsTakeLongerWithinLimits() {
        let hop = CursorFlight(from: .zero, to: CGPoint(x: 50, y: 0))
        let medium = CursorFlight(from: .zero, to: CGPoint(x: 800, y: 0))
        let across = CursorFlight(from: .zero, to: CGPoint(x: 5000, y: 0))
        #expect(hop.duration == 0.6)
        #expect(medium.duration == 1.0)
        #expect(across.duration == 1.4)
    }

    @Test func flightArcsUpwardAndSwellsMidAir() {
        let flight = CursorFlight(from: CGPoint(x: 0, y: 500), to: CGPoint(x: 800, y: 500))
        let middle = flight.sample(at: 0.5)
        // A medium flight lifts at most 80 pt, and the bezier peaks at half of it.
        #expect(flight.reach == .medium)
        #expect(middle.position.x == 400)
        #expect(middle.position.y == 460)
        #expect(abs(middle.scale - 1.3) < 0.0001)
    }

    @Test func reachSetsLiftAndSwell() {
        #expect(CursorFlight.Reach(distance: 320) == .hop)
        #expect(CursorFlight.Reach(distance: 321) == .medium)
        #expect(CursorFlight.Reach(distance: 900) == .medium)
        #expect(CursorFlight.Reach(distance: 901) == .long)

        let hop = CursorFlight(from: CGPoint(x: 0, y: 500), to: CGPoint(x: 300, y: 500))
        #expect(abs(hop.sample(at: 0.5).scale - 1.15) < 0.0001)
        let long = CursorFlight(from: CGPoint(x: 0, y: 500), to: CGPoint(x: 1000, y: 500))
        #expect(long.sample(at: 0.5).position.y == 440)
        #expect(abs(long.sample(at: 0.5).scale - 1.4) < 0.0001)
    }

    @Test func longFlightsWindUpBeforeLeaving() {
        let long = CursorFlight(from: CGPoint(x: 0, y: 500), to: CGPoint(x: 1600, y: 500))
        // Pulled back against the flight (left of the start) early on.
        #expect(long.sample(at: 0.04).position.x < 0)
        #expect(long.sample(at: 0).position == CGPoint(x: 0, y: 500))
        let medium = CursorFlight(from: CGPoint(x: 0, y: 500), to: CGPoint(x: 800, y: 500))
        #expect(medium.sample(at: 0.04).position.x >= 0)
    }

    @Test func arrowheadFacesTheDirectionOfTravel() {
        let flight = CursorFlight(from: CGPoint(x: 0, y: 500), to: CGPoint(x: 1000, y: 500))
        // Flying right and level at the top of the arc: the tip points right.
        #expect(abs(flight.sample(at: 0.5).headingDegrees - 90) < 0.0001)
        // Climbing at take-off, so tilted up from horizontal.
        #expect(flight.sample(at: 0.05).headingDegrees < 90)
    }

    @Test func retargetingMovesTheLandingAndHalfTheArc() {
        var flight = CursorFlight(from: .zero, to: CGPoint(x: 400, y: 0))
        let peakBefore = flight.control
        flight.retarget(to: CGPoint(x: 500, y: 40))
        #expect(flight.end == CGPoint(x: 500, y: 40))
        #expect(flight.control == CGPoint(x: peakBefore.x + 50, y: peakBefore.y + 20))
        #expect(flight.sample(at: 1).position == CGPoint(x: 500, y: 40))
    }

    @Test func listeningMeterIgnoresNoiseAndSaturates() {
        #expect(CompanionListeningMeter.easedLevel(0) == 0)
        #expect(CompanionListeningMeter.easedLevel(0.008) == 0)
        #expect(CompanionListeningMeter.easedLevel(1) == 1)
        #expect(CompanionListeningMeter.easedLevel(0.1) > 0.1)
    }
}
