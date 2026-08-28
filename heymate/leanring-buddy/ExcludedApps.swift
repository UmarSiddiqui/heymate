//
//  ExcludedApps.swift
//  leanring-buddy
//
//  Privacy gate for the screen-capture pipeline. When the frontmost app is on
//  the exclusion list, screenshots must be skipped entirely and the companion
//  falls back to voice-only context. The list ships with password managers and
//  System Settings (which hosts password/auth panels), and users can extend it;
//  user additions persist in UserDefaults while shipped defaults can never be
//  removed.
//

import Foundation

enum ExcludedApps {

    /// UserDefaults key holding USER-added exclusions ([String]).
    /// Entries are persisted trimmed and lowercased so reads never re-normalize.
    static let userDefaultsKey = "excludedAppBundleIds"

    /// Shipped defaults: password managers + System Settings (auth panes).
    /// Declared `nonisolated` so the pure decision core below can reference it
    /// as a default argument and run from any isolation domain.
    nonisolated static let defaultExcludedBundleIds: [String] = [
        "com.1password.1password",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.systempreferences",
    ]

    /// Combined effective list: defaults ∪ user additions, deduped,
    /// lowercased, sorted. This is the single source of truth for UI display.
    static func currentList() -> [String] {
        let userEntries = UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? []
        let normalizedDefaultEntries = defaultExcludedBundleIds.map { $0.lowercased() }
        let normalizedUserEntries = userEntries.map { $0.lowercased() }
        return Set(normalizedDefaultEntries + normalizedUserEntries).sorted()
    }

    /// Persists a user exclusion (trims + lowercases; ignores empties/dupes).
    /// Also ignores ids identical to a shipped default — those are already
    /// excluded forever and would only pollute the persisted user list.
    static func addUserExclusion(_ bundleId: String) {
        let normalizedBundleId = bundleId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedBundleId.isEmpty else { return }

        let existingUserEntries = UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? []
        let existingNormalizedUserEntries = existingUserEntries.map { $0.lowercased() }

        guard !existingNormalizedUserEntries.contains(normalizedBundleId),
              !defaultExcludedBundleIds.map({ $0.lowercased() }).contains(normalizedBundleId)
        else { return }

        UserDefaults.standard.set(existingUserEntries + [normalizedBundleId], forKey: userDefaultsKey)
    }

    /// Removes a USER exclusion. Defaults cannot be removed — filtering the
    /// user list simply never touches them, so a default stays excluded even
    /// if the user asks to remove it.
    static func removeUserExclusion(_ bundleId: String) {
        // Normalized symmetrically with addUserExclusion so callers can pass
        // the id in any casing and still hit the persisted entry.
        let normalizedBundleId = bundleId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedBundleId.isEmpty else { return }

        let remainingUserEntries = (UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? [])
            .filter { $0.lowercased() != normalizedBundleId }

        UserDefaults.standard.set(remainingUserEntries, forKey: userDefaultsKey)
    }

    /// Pure decision core. Nil/empty bundleId → false (unknown apps stay
    /// capturable; fail-open for usability, documented): a crash or missing
    /// frontmost-app id must never silently disable the companion's vision,
    /// and the lists here cover known sensitive apps rather than unknown ones.
    nonisolated static func shouldExclude(
        bundleId: String?,
        userList: [String],
        defaultList: [String] = defaultExcludedBundleIds
    ) -> Bool {
        guard let bundleId, !bundleId.isEmpty else { return false }

        // Case-insensitive exact match — bundle ids are conventionally
        // lowercase, but callers may surface them in original system casing.
        let normalizedBundleId = bundleId.lowercased()
        return userList.contains { $0.lowercased() == normalizedBundleId }
            || defaultList.contains { $0.lowercased() == normalizedBundleId }
    }

    /// Convenience reading the current user list straight from UserDefaults.
    static func isCurrentlyExcluded(bundleId: String?) -> Bool {
        let currentUserEntries = UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? []
        return shouldExclude(bundleId: bundleId, userList: currentUserEntries)
    }
}
