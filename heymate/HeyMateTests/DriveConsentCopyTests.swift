//
//  DriveConsentCopyTests.swift
//  HeyMateTests
//
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct DriveConsentCopyTests {
    @Test func endStateGoalReadsAsAnAsk() {
        #expect(DriveTakeOverConsentCard.ask(goal: "The current calculation is cleared and 998633 is entered.")
                == "until the current calculation is cleared and 998633 is entered?")
    }

    @Test func namesAndAcronymsKeepTheirCapitals() {
        #expect(DriveTakeOverConsentCard.ask(goal: "Safari shows the pricing page") == "until Safari shows the pricing page?")
        #expect(DriveTakeOverConsentCard.ask(goal: "PDF is exported to Downloads.") == "until PDF is exported to Downloads?")
    }

    @Test func emptyGoalStillAsks() {
        #expect(DriveTakeOverConsentCard.ask(goal: "  ") == "Take over?")
    }
}

@MainActor
struct NotchUsageResetTextTests {
    @Test func resetTimesStayShort() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(NotchUsageView.shortDuration(until: now.addingTimeInterval(45 * 60), from: now) == "45m")
        #expect(NotchUsageView.shortDuration(until: now.addingTimeInterval(3 * 3600 + 120), from: now) == "3h")
        #expect(NotchUsageView.shortDuration(until: now.addingTimeInterval(5 * 86400), from: now) == "5d")
    }
}
