//
//  IntegrationOverlapTests.swift
//  HeyMateTests
//

import Testing
@testable import HeyMate

struct IntegrationOverlapTests {

    private func toolkit(_ slug: String, _ name: String) -> ComposioToolkit {
        ComposioToolkit(
            slug: slug,
            name: name,
            description: "",
            logoURL: nil,
            toolCount: 1,
            categories: [],
            usesComposioManagedAuth: true,
            requiresNoAuthentication: false
        )
    }

    @Test func gitHubThroughGhAndThroughTheWebIsOneChip() {
        let merged = IntegrationOverlap.merged(
            local: [(id: "connector:github-cli", name: "GitHub", logoSlug: "github-cli")],
            web: [
                (id: "composio:github", name: "GitHub", logoSlug: "github"),
                (id: "composio:gmail", name: "Gmail", logoSlug: "gmail")
            ]
        )
        #expect(merged.map(\.name) == ["GitHub", "Gmail"])
        #expect(merged.first?.id == "connector:github-cli")
        #expect(merged.first?.logoSlug == "github")
    }

    @Test func webListHidesComposioAndAppsALocalToolAlreadyReaches() {
        let listed = IntegrationOverlap.webAppsToList(
            [toolkit("composio", "Composio"), toolkit("github", "GitHub"), toolkit("notion", "Notion")],
            connectedLocalNames: ["GitHub", "Git"],
            isConnectedOnWeb: { _ in false }
        )
        #expect(listed.map(\.slug) == ["notion"])
    }

    @Test func webListKeepsAnAppConnectedOnTheWebSoItCanBeDisconnected() {
        let listed = IntegrationOverlap.webAppsToList(
            [toolkit("github", "GitHub")],
            connectedLocalNames: ["GitHub"],
            isConnectedOnWeb: { $0 == "github" }
        )
        #expect(listed.map(\.slug) == ["github"])
    }

    @Test func withoutGhTheWebGitHubIsStillOffered() {
        let listed = IntegrationOverlap.webAppsToList(
            [toolkit("github", "GitHub")],
            connectedLocalNames: [],
            isConnectedOnWeb: { _ in false }
        )
        #expect(listed.map(\.slug) == ["github"])
    }

    @Test func composerNamesBothRoutesWhenTheyShareAName() {
        let labeled = IntegrationOverlap.labeled(
            local: [(id: "a", name: "GitHub", logoSlug: "github-cli"), (id: "b", name: "Git", logoSlug: "git-local")],
            web: [(id: "c", name: "GitHub", logoSlug: "github")]
        )
        #expect(labeled.map(\.name) == ["Git", "GitHub (on this Mac)", "GitHub (web)"])
    }
}
