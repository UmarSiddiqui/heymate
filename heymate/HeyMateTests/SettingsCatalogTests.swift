//
//  SettingsCatalogTests.swift
//  HeyMateTests
//
//  Settings search, the shortcut-conflict warning, and the bundle-id check
//  are plain logic, so they are tested here rather than by eye. Nothing
//  here reads or writes UserDefaults.
//

import Testing
@testable import HeyMate

@MainActor
struct SettingsCatalogTests {

    // MARK: Catalog

    @Test func everySectionHasSearchableSettings() {
        for tab in DesktopSettingsTab.allCases {
            #expect(SettingsItem.allCases.contains { $0.tab == tab }, "No searchable settings in \(tab.title)")
        }
    }

    @Test func everySettingHasATitleAndSynonyms() {
        for item in SettingsItem.allCases {
            #expect(!item.title.isEmpty)
            #expect(!item.keywords.isEmpty)
        }
    }

    @Test func titlesAreUniqueWithinASection() {
        for tab in DesktopSettingsTab.allCases {
            let titles = SettingsItem.allCases.filter { $0.tab == tab }.map(\.title)
            #expect(Set(titles).count == titles.count, "Duplicate row title in \(tab.title)")
        }
    }

    // MARK: Search

    @Test func emptyOrBlankQueryFindsNothing() {
        #expect(SettingsSearch.results(for: "").isEmpty)
        #expect(SettingsSearch.results(for: "   ").isEmpty)
    }

    @Test func findsByTitleIgnoringCase() {
        #expect(SettingsSearch.results(for: "MICROPHONE").first == .microphone)
    }

    @Test func findsBySynonym() {
        #expect(SettingsSearch.results(for: "airpods").contains(.microphone))
        #expect(SettingsSearch.results(for: "wipe").contains(.eraseData))
        #expect(SettingsSearch.results(for: "hotkey").contains(.talkShortcut))
    }

    @Test func ignoresDiacritics() {
        #expect(SettingsSearch.results(for: "micróphone").first == .microphone)
    }

    @Test func everyWordMustMatch() {
        let results = SettingsSearch.results(for: "elevenlabs voice")
        #expect(results.contains(.elevenLabsVoice))
        #expect(!results.contains(.microphone))
    }

    @Test func titleMatchesRankAboveSynonymMatches() {
        // "Sounds" is in the Interaction sounds title and in no title
        // earlier in the catalog, so the title match must come first.
        let results = SettingsSearch.results(for: "sounds")
        #expect(results.first == .interactionSounds)
    }

    @Test func sectionNameFindsItsSettings() {
        let results = SettingsSearch.results(for: "shortcuts")
        #expect(results.contains(.talkShortcut))
        #expect(results.contains(.restoreShortcuts))
    }

    @Test func nonsenseFindsNothing() {
        #expect(SettingsSearch.results(for: "zzqqxx").isEmpty)
    }

    // MARK: Shortcut conflicts

    @Test func shippedShortcutsDoNotConflict() {
        let defaults = Dictionary(uniqueKeysWithValues: SettingsShortcutRole.allCases.map { ($0, $0.defaultOption) })
        #expect(SettingsShortcutRole.conflictingRoles(in: defaults).isEmpty)
    }

    @Test func sharedComboFlagsBothRoles() {
        let assignments: [SettingsShortcutRole: BuddyPushToTalkShortcut.ShortcutOption] = [
            .talk: .controlOption,
            .chat: .controlCommand,
            .dictate: .controlOption,
            .region: .shiftControl
        ]
        #expect(SettingsShortcutRole.conflictingRoles(in: assignments) == [.talk, .dictate])
    }

    @Test func threeWayConflictFlagsAllThree() {
        let assignments: [SettingsShortcutRole: BuddyPushToTalkShortcut.ShortcutOption] = [
            .talk: .shiftControl,
            .chat: .shiftControl,
            .dictate: .shiftFunction,
            .region: .shiftControl
        ]
        #expect(SettingsShortcutRole.conflictingRoles(in: assignments) == [.talk, .chat, .region])
    }

    @Test func eachRoleSearchesToItsOwnRow() {
        for role in SettingsShortcutRole.allCases {
            #expect(role.item.tab == .shortcuts)
        }
    }

    // MARK: Privacy

    @Test func bundleIdentifierCheckAcceptsReverseDNS() {
        #expect(SettingsPrivacyPane.isPlausibleBundleIdentifier("com.apple.Safari"))
        #expect(SettingsPrivacyPane.isPlausibleBundleIdentifier("com.1password.1password"))
    }

    @Test func bundleIdentifierCheckRejectsNamesAndTypos() {
        #expect(!SettingsPrivacyPane.isPlausibleBundleIdentifier("Safari"))
        #expect(!SettingsPrivacyPane.isPlausibleBundleIdentifier("com.apple."))
        #expect(!SettingsPrivacyPane.isPlausibleBundleIdentifier(".com.apple"))
        #expect(!SettingsPrivacyPane.isPlausibleBundleIdentifier("com apple.Safari"))
    }
}
