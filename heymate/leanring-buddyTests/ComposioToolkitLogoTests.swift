import Foundation
import Testing
@testable import HeyMate

struct ComposioToolkitLogoTests {
    @Test func canonicalComposioLogoLeadsPayloadLogoFallback() throws {
        let payloadLogo = try #require(URL(string: "https://example.com/custom.svg"))
        let toolkit = ComposioToolkit(
            slug: "GoogleCalendar",
            name: "Google Calendar",
            description: "Calendar",
            logoURL: payloadLogo,
            toolCount: 1,
            categories: [],
            usesComposioManagedAuth: true,
            requiresNoAuthentication: false
        )

        #expect(toolkit.logoCandidates.map(\.absoluteString) == [
            "https://logos.composio.dev/api/googlecalendar",
            "https://example.com/custom.svg"
        ])
    }

    @Test func duplicateCanonicalPayloadLogoIsOnlyLoadedOnce() throws {
        let canonicalLogo = try #require(URL(string: "https://logos.composio.dev/api/gmail"))
        let toolkit = ComposioToolkit(
            slug: "gmail",
            name: "Gmail",
            description: "Email",
            logoURL: canonicalLogo,
            toolCount: 1,
            categories: [],
            usesComposioManagedAuth: true,
            requiresNoAuthentication: false
        )

        #expect(toolkit.logoCandidates == [canonicalLogo])
    }
}
