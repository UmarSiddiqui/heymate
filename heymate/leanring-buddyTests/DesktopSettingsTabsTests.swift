//
//  DesktopSettingsTabsTests.swift
//  leanring-buddyTests
//
//  Settings sections are deep-linked by writing a raw value into
//  UserDefaults, so the raw values and key are a contract. The AI &
//  Accounts section turns CLI readiness into account language; these lock
//  that wording to the state.
//
//  Nothing here writes UserDefaults: the host app shares the user's real
//  preferences.
//

import Testing
@testable import HeyMate

@MainActor
struct DesktopSettingsTabsTests {

    @Test func storageKeyIsTheDeepLinkContract() {
        #expect(DesktopSettingsTab.storageKey == "desktopSettingsSelectedTab")
        #expect(DesktopSection.settingsTabDefaultsKey == DesktopSettingsTab.storageKey)
    }

    @Test func sectionsAreInRailOrder() {
        #expect(DesktopSettingsTab.allCases.map(\.rawValue) == [
            "general", "shortcuts", "voice", "notch", "accounts", "agents", "connections", "privacy"
        ])
    }

    @Test func rawValuesFromEarlierVersionsStillResolve() {
        // Written by older builds and by deep links; must keep landing.
        #expect(DesktopSettingsTab.resolve("general") == .general)
        #expect(DesktopSettingsTab.resolve("accounts") == .accounts)
        #expect(DesktopSettingsTab.resolve("notch") == .notch)
        #expect(DesktopSettingsTab.resolve("privacy") == .privacy)
        // The old catch-all tab lands where its only in-app link pointed.
        #expect(DesktopSettingsTab.resolve("advanced") == .connections)
        #expect(DesktopSettingsTab.resolve("not-a-section") == .general)
    }

    @Test func sidebarDeepLinksLandOnTheirSections() {
        #expect(DesktopSection.notch.settingsTab.map(DesktopSettingsTab.resolve) == .notch)
        #expect(DesktopSection.privacy.settingsTab.map(DesktopSettingsTab.resolve) == .privacy)
        #expect(DesktopSection.notch.landingSection == .settings)
        #expect(DesktopSection.privacy.landingSection == .settings)
    }

    @Test func everySectionHasAGroupAndAppearsOnce() {
        let railed = DesktopSettingsTabGroup.allCases.flatMap(\.tabs)
        #expect(railed == DesktopSettingsTab.allCases)
    }

    @Test func accountsOffersTheThreePlansInOrder() {
        #expect(DesktopSettingsAccountsTab.everydayBrains == [.claudeCode, .codex, .onDevice])
        #expect(DesktopSettingsAccountsTab.otherBrains == [.openCode, .customAPI])
        let everyBrain = Set(DesktopSettingsAccountsTab.everydayBrains + DesktopSettingsAccountsTab.otherBrains)
        #expect(everyBrain == Set(AgentBrain.allCases))
    }

    @Test func signedInClaudeShowsPlanAndEmail() {
        let line = SubscriptionAccountStatus.line(
            for: .ready(detail: "Claude Pro · you@example.com"),
            executor: .claudeCode
        )
        #expect(line.text == "Signed in · Claude Pro · you@example.com")
        #expect(line.tone == .good)
        #expect(line.actionTitle == "Switch account")
    }

    @Test func signedInChatGPTDropsTheCLIName() {
        let line = SubscriptionAccountStatus.line(
            for: .ready(detail: "Codex · ChatGPT subscription"),
            executor: .codex
        )
        #expect(line.text == "Signed in · ChatGPT subscription")
    }

    @Test func missingAndSignedOutAccountsOfferTheFix() {
        let notInstalled = SubscriptionAccountStatus.line(
            for: HeadlessExecutorReadiness(state: .notInstalled, detail: "Not installed", remedy: "x"),
            executor: .claudeCode
        )
        #expect(notInstalled.text == "Not installed")
        #expect(notInstalled.actionTitle == "Set up")

        let signedOut = SubscriptionAccountStatus.line(
            for: HeadlessExecutorReadiness(state: .notSignedIn, detail: "Signed out of the Codex CLI", remedy: "x"),
            executor: .codex
        )
        #expect(signedOut.text == "Not signed in")
        #expect(signedOut.actionTitle == "Sign in")
    }

    @Test func unprobedReadinessReadsAsChecking() {
        let line = SubscriptionAccountStatus.line(for: .indeterminate(), executor: .claudeCode)
        #expect(line.text == "Checking…")
        #expect(line.tone == .neutral)

        let probeFailed = SubscriptionAccountStatus.line(
            for: .indeterminate(detail: "Could not read auth status"),
            executor: .claudeCode
        )
        #expect(probeFailed.text == "Installed · couldn't confirm sign-in")
    }

    @Test func statusTextNeverMentionsTheCommandLine() {
        let states: [HeadlessExecutorReadiness] = [
            .ready(detail: "Codex · ChatGPT subscription"),
            HeadlessExecutorReadiness(state: .usingAPIKey, detail: "API key (not claude.ai)", remedy: "Run `claude logout`"),
            HeadlessExecutorReadiness(state: .notSignedIn, detail: "Signed out of the Codex CLI", remedy: "x"),
            .indeterminate(detail: "Could not read login status")
        ]
        for readiness in states {
            for executor in [HeadlessExecutor.claudeCode, .codex] {
                let text = SubscriptionAccountStatus.line(for: readiness, executor: executor).text
                #expect(!text.contains("CLI"))
                #expect(!text.contains("`"))
            }
        }
    }
}
