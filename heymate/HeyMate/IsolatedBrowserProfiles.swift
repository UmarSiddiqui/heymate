//
//  IsolatedBrowserProfiles.swift
//  HeyMate
//
//  Pure pieces of the mates' browsers (IsolatedBrowserWorkers):
//  which mates keep a persistent Chrome profile, which open profile to close
//  when too many are open, and how a full-page read is stitched together
//  from viewport reads.
//
//  Each persistent mate's Cua profile is named from its mate ID
//  ("heymate-mate-<uuid>"), so moving from the single-mate setting to a set
//  keeps the earlier mate's profile directory, and its sign-ins, untouched.
//

import Foundation

nonisolated enum IsolatedBrowserProfiles {
    static let preferenceKey = "persistentBrowserMateIDs"
    /// The single-mate setting this replaces.
    static let legacyPreferenceKey = "persistentBrowserMateID"
    /// Each persistent profile is a whole Chrome process. Two open at once
    /// keeps memory reasonable next to the four temporary workers; a third
    /// closes the least recently used idle one.
    static let maximumOpen = 2

    static func profileName(for mateID: UUID) -> String { "heymate-mate-" + mateID.uuidString.lowercased() }

    /// Reads the set, folding in (and removing) the legacy single value.
    static func load(from preferences: UserDefaults?) -> Set<UUID> {
        guard let preferences else { return [] }
        var ids = Set((preferences.stringArray(forKey: preferenceKey) ?? []).compactMap(UUID.init(uuidString:)))
        if let legacy = preferences.string(forKey: legacyPreferenceKey) {
            if let id = UUID(uuidString: legacy) { ids.insert(id) }
            save(ids, to: preferences)
            preferences.removeObject(forKey: legacyPreferenceKey)
        }
        return ids
    }

    static func save(_ ids: Set<UUID>, to preferences: UserDefaults?) {
        preferences?.set(ids.map(\.uuidString).sorted(), forKey: preferenceKey)
    }

    struct OpenProfile: Equatable, Sendable {
        let mateID: UUID
        let lastUsed: UInt64
        /// In a turn, taken over, or mid-IO: never closed to make room.
        let busy: Bool
    }

    /// Which open profiles to close so `opening` fits under `maximum`.
    /// Nil when there is no room and every candidate is busy.
    static func profilesToClose(open: [OpenProfile], opening: UUID, maximum: Int = maximumOpen) -> [UUID]? {
        let others = open.filter { $0.mateID != opening }
        let excess = others.count + 1 - maximum
        guard excess > 0 else { return [] }
        let idle = others.filter { !$0.busy }.sorted { $0.lastUsed < $1.lastUsed }
        guard idle.count >= excess else { return nil }
        return idle.prefix(excess).map(\.mateID)
    }

    /// "mate-uuid/chat-uuid" worker owners belong to that mate.
    static func mateID(fromOwner owner: String) -> UUID? {
        if owner.hasPrefix("heymate-mate-") { return UUID(uuidString: String(owner.dropFirst("heymate-mate-".count))) }
        return owner.split(separator: "/").first.flatMap { UUID(uuidString: String($0)) }
    }
}

/// A whole-page read built from viewport reads taken while scrolling down.
nonisolated enum BrowserPageText {
    static let characterLimit = 60_000
    static let maximumSteps = 25
    static let truncationMarker = "[Page text truncated at 60,000 characters. Use snapshot and scroll to read further.]"

    /// Appends `next` to `accumulated`, overlapping the longest run of lines
    /// that ends one and starts the other, so text seen in two viewports
    /// appears once. Returns the lines actually added.
    static func merge(_ accumulated: inout [String], _ next: [String]) -> Int {
        let limit = min(accumulated.count, next.count)
        var overlap = 0
        if limit > 0 {
            for size in stride(from: limit, through: 1, by: -1)
            where Array(accumulated.suffix(size)) == Array(next.prefix(size)) {
                overlap = size
                break
            }
        }
        let added = next.dropFirst(overlap)
        accumulated.append(contentsOf: added)
        return added.count
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Caps the joined text and marks the cut clearly.
    static func capped(_ lines: [String], limit: Int = characterLimit) -> (text: String, truncated: Bool) {
        let text = lines.joined(separator: "\n")
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)) + "\n\n" + truncationMarker, true)
    }
}

/// What a mate's browser is on now, for the live panel in its chat.
nonisolated struct BrowserLiveState: Equatable, Sendable {
    var url = ""
    var title = ""
    var isPersistent = false
    /// True from a browser operation until its turn finishes; the panel
    /// refreshes its picture only while this is set.
    var isWorking = false
}
