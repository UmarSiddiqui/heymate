//
//  ExcludedAppsTests.swift
//  leanring-buddyTests
//
//  Tests for the screen-capture privacy gate. Pins down the pure exclusion
//  decision (case-insensitive union match, fail-open on unknown ids), the
//  effective-list merge (dedupe + sort + defaults ∪ user), and the persistence
//  behavior of user additions/removals. Tests that touch the real
//  UserDefaults key save and restore the user's prior value.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct ExcludedAppsTests {

    // MARK: - Fixtures & helpers

    private static let onePassword = "com.1password.1password"
    private static let systemSettings = "com.apple.systempreferences"

    /// Restores the user's real persisted exclusions after the test so we
    /// never leak mutations into the developer's actual app settings.
    private func withSavedUserExclusions(_ body: () -> Void) {
        let previousValue = UserDefaults.standard.stringArray(forKey: ExcludedApps.userDefaultsKey)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: ExcludedApps.userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ExcludedApps.userDefaultsKey)
            }
        }
        body()
    }

    private func clearUserExclusions() {
        UserDefaults.standard.removeObject(forKey: ExcludedApps.userDefaultsKey)
    }

    // MARK: - Pure decision core: nil / empty (fail-open)

    @Test func nilBundleIdIsNeverExcluded() {
        #expect(!ExcludedApps.shouldExclude(
            bundleId: nil,
            userList: [Self.onePassword]
        ))
    }

    @Test func emptyBundleIdIsNeverExcluded() {
        // Fail-open: an unreadable frontmost id must not disable vision.
        #expect(!ExcludedApps.shouldExclude(bundleId: "", userList: [Self.onePassword]))
    }

    @Test func unknownBundleIdIsNotExcluded() {
        #expect(!ExcludedApps.shouldExclude(
            bundleId: "com.safari.browser",
            userList: [],
            defaultList: []
        ))
    }

    // MARK: - Pure decision core: matching across the union of lists

    @Test func exactMatchInUserListIsExcluded() {
        #expect(ExcludedApps.shouldExclude(
            bundleId: "com.acme.secretvault",
            userList: ["com.acme.secretvault"],
            defaultList: []
        ))
    }

    @Test func exactMatchInDefaultListIsExcluded() {
        #expect(ExcludedApps.shouldExclude(
            bundleId: Self.onePassword,
            userList: [],
            defaultList: [Self.onePassword]
        ))
    }

    @Test func matchIsCaseInsensitiveAcrossBothLists() {
        // User list stored lowercase, query in mixed casing…
        #expect(ExcludedApps.shouldExclude(
            bundleId: "COM.Acme.SecretVault",
            userList: ["com.acme.secretvault"],
            defaultList: []
        ))

        // …and vice versa for a shipped default.
        #expect(ExcludedApps.shouldExclude(
            bundleId: Self.onePassword,
            userList: [],
            defaultList: ["COM.1Password.1Password"]
        ))
    }

    @Test func untrimmedBundleIdDoesNotMatch() {
        // Normalization lives at the add/read layer; the pure core only does
        // exact case-insensitive comparison, so padded input must not match.
        #expect(!ExcludedApps.shouldExclude(
            bundleId: " com.1password.1password ",
            userList: [Self.onePassword],
            defaultList: []
        ))
    }

    @Test func defaultParameterUsesShippedDefaults() {
        // No explicit defaultList — System Settings id must still be excluded.
        #expect(ExcludedApps.shouldExclude(
            bundleId: Self.systemSettings,
            userList: []
        ))
    }

    // MARK: - currentList(): union, dedupe, sort

    @Test func returnsShippedDefaultsWhenNoUserEntries() {
        withSavedUserExclusions {
            clearUserExclusions()
            #expect(ExcludedApps.currentList() == ExcludedApps.defaultExcludedBundleIds.sorted())
        }
    }

    @Test func currentListMergesDedupesAndSortsAcrossLists() {
        withSavedUserExclusions {
            clearUserExclusions()
            // Duplicates within the user list, a duplicate of a shipped
            // default, and unsorted/mixed-case entries all collapse into
            // one lowercased sorted union.
            UserDefaults.standard.set(
                [
                    "com.zed.editor",
                    "com.zed.editor",
                    "COM.Apple.SystemPreferences",
                    "com.aardvark.client",
                ],
                forKey: ExcludedApps.userDefaultsKey
            )

            let effectiveList = ExcludedApps.currentList()

            // Assert union/dedupe/sort invariants rather than a brittle exact
            // snapshot — other suites may legitimately hold exclusions too.
            for expectedMember in [
                "com.aardvark.client",
                "com.apple.systempreferences",
                "com.bitwarden.desktop",
                "com.zed.editor",
                "com.1password.1password",
                "org.keepassxc.keepassxc",
            ] {
                #expect(effectiveList.contains(expectedMember))
            }
            #expect(Set(effectiveList).count == effectiveList.count)    // deduped
            #expect(effectiveList == effectiveList.sorted())            // sorted
        }
    }

    // MARK: - addUserExclusion: trim + lowercase + ignore empties/dupes

    @Test func addUserExclusionTrimsWhitespaceAndLowercasesBeforePersisting() {
        withSavedUserExclusions {
            clearUserExclusions()
            ExcludedApps.addUserExclusion("  COM.Acme.SecretVault  ")

            #expect(UserDefaults.standard.stringArray(forKey: ExcludedApps.userDefaultsKey) == [
                "com.acme.secretvault"
            ])
        }
    }

    @Test func addUserExclusionIgnoresEmptyAndWhitespaceOnlyStrings() {
        withSavedUserExclusions {
            clearUserExclusions()
            ExcludedApps.addUserExclusion("")
            ExcludedApps.addUserExclusion("   ")

            #expect(UserDefaults.standard.stringArray(forKey: ExcludedApps.userDefaultsKey) == nil)
        }
    }

    @Test func addUserExclusionIgnoresDuplicatesIncludingShippedDefaults() {
        withSavedUserExclusions {
            clearUserExclusions()
            ExcludedApps.addUserExclusion("com.acme.secretvault")
            // Same id again in different casing must not append…
            ExcludedApps.addUserExclusion("COM.ACME.SECRETVAULT")
            // …and a shipped default is already permanently excluded, so
            // persisting it as a user entry would only pollute the list.
            ExcludedApps.addUserExclusion(Self.onePassword)

            #expect(UserDefaults.standard.stringArray(forKey: ExcludedApps.userDefaultsKey) == [
                "com.acme.secretvault"
            ])
        }
    }

    // MARK: - removeUserExclusion: user entries only, never defaults

    @Test func removeUserExclusionRemovesOnlyTheMatchingUserEntry() {
        withSavedUserExclusions {
            clearUserExclusions()
            ExcludedApps.addUserExclusion("com.acme.secretvault")
            ExcludedApps.addUserExclusion("com.zed.editor")
            // Mixed casing + padding must still hit the persisted entry.
            ExcludedApps.removeUserExclusion("  COM.ZED.EDITOR ")

            #expect(UserDefaults.standard.stringArray(forKey: ExcludedApps.userDefaultsKey) == [
                "com.acme.secretvault"
            ])
            #expect(!ExcludedApps.currentList().contains("com.zed.editor"))
        }
    }

    @Test func removeUserExclusionCannotRemoveShippedDefaults() {
        withSavedUserExclusions {
            clearUserExclusions()
            ExcludedApps.removeUserExclusion(Self.onePassword)

            // Behavioral contract: the default stays excluded regardless of
            // what removal attempts do to stored user entries.
            #expect(ExcludedApps.currentList().contains(Self.onePassword))
            #expect(ExcludedApps.isCurrentlyExcluded(bundleId: Self.onePassword))
        }
    }

    // MARK: - Persistence round-trip through the real key

    @Test func addedExclusionRoundTripsThroughDefaultsIntoDecision() {
        withSavedUserExclusions {
            clearUserExclusions()
            let targetBundleId = "com.acme.secretvault"

            #expect(!ExcludedApps.isCurrentlyExcluded(bundleId: targetBundleId))

            ExcludedApps.addUserExclusion(targetBundleId)

            // The persisted value feeds both the convenience check and the
            // effective list without any extra normalization step.
            #expect(ExcludedApps.isCurrentlyExcluded(bundleId: targetBundleId))
            #expect(ExcludedApps.isCurrentlyExcluded(bundleId: targetBundleId.uppercased()))
            #expect(ExcludedApps.currentList().contains(targetBundleId))

            ExcludedApps.removeUserExclusion(targetBundleId)
            #expect(!ExcludedApps.isCurrentlyExcluded(bundleId: targetBundleId))
        }
    }
}
