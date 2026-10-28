//
//  AppGuidesTests.swift
//  HeyMateTests
//
//  A turn carries guides only for the apps enabled in its chat.
//

import Foundation
import Testing
@testable import HeyMate

struct AppGuidesTests {
    @Test func onlyEnabledAppsWithAGuideAreIncluded() {
        let text = AppGuides.text(for: ["slack", "gmail", "jira"])
        #expect(text.contains("Gmail:\n"))
        #expect(text.contains("Jira:\n"))
        #expect(!text.contains("Outlook:"))
        #expect(text.range(of: "Gmail:")!.lowerBound < text.range(of: "Jira:")!.lowerBound)
        #expect(AppGuides.text(for: ["slack"]).isEmpty)
        #expect(AppGuides.text(for: []).isEmpty)
    }

    @Test func everyGuideHasADisplayName() {
        #expect(Set(AppGuides.guides.keys) == Set(AppGuides.names.keys))
    }
}
