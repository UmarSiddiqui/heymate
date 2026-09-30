//
//  ReleaseConfigurationTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct SparkleUpdateConfigurationTests {

    private let validPublicKey = Data(repeating: 0x2A, count: 32).base64EncodedString()

    @Test func resolvesACompleteHTTPSReleaseConfiguration() {
        let configuration = SparkleUpdateConfiguration.resolve(from: [
            "SUFeedURL": "https://github.com/example/heymate/releases/latest/download/appcast.xml",
            "SUPublicEDKey": validPublicKey
        ])

        #expect(configuration?.feedURL.absoluteString == "https://github.com/example/heymate/releases/latest/download/appcast.xml")
        #expect(configuration?.publicEDKey == validPublicKey)
    }

    @Test func unsetSourceBuildConfigurationStaysDisabled() {
        #expect(SparkleUpdateConfiguration.resolve(from: [:]) == nil)
        #expect(SparkleUpdateConfiguration.resolve(from: [
            "SUFeedURL": "$(SPARKLE_FEED_URL)",
            "SUPublicEDKey": "$(SPARKLE_PUBLIC_ED_KEY)"
        ]) == nil)
    }

    @Test func rejectsInsecureFeedsAndWrongKeys() {
        #expect(SparkleUpdateConfiguration.resolve(from: [
            "SUFeedURL": "http://example.com/appcast.xml",
            "SUPublicEDKey": validPublicKey
        ]) == nil)
        #expect(SparkleUpdateConfiguration.resolve(from: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": Data(repeating: 0x2A, count: 31).base64EncodedString()
        ]) == nil)
    }
}

struct SupportLinksTests {

    @Test func supportLinksPointAtIssueFormsAndNotDiscussions() {
        let paths = Dictionary(uniqueKeysWithValues: SupportLinks.destinations.map { ($0.id, $0.url.path) })
        let urls = Dictionary(uniqueKeysWithValues: SupportLinks.destinations.map { ($0.id, $0.url) })

        #expect(paths["report-a-bug"]?.hasSuffix("/issues/new") == true)
        #expect(paths["request-a-feature"]?.hasSuffix("/issues/new") == true)
        #expect(paths["issues"]?.hasSuffix("/issues") == true)
        #expect(urls["report-a-bug"]?.query == "template=bug.yml")
        #expect(urls["request-a-feature"]?.query == "template=feature.yml")
        #expect(SupportLinks.destinations.contains { $0.url.path.hasSuffix("/discussions") } == false)
    }
}
