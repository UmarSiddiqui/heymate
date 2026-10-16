//
//  CompanionManager+MacAccounts.swift
//  HeyMate
//
//  Feeds Calendar and Mail into a turn that asks about them. The reading
//  itself lives in `MacAccountContext`; this only decides whether the user
//  allowed it and keeps the slow part off the main actor.
//

import Foundation

extension CompanionManager {

    /// Prompt blocks for the Mac apps this question is about. Empty when the
    /// question is about something else, or when the matching Mac app is not
    /// switched on in Apps — a calendar is never read uninvited.
    func macAccountContextBlocks(
        for transcript: String,
        calendarReader: @escaping @Sendable () -> String? = { MacAccountContext.calendarBlock() },
        mailReader: @escaping @Sendable () -> String? = { MacAccountContext.mailBlock() }
    ) async -> [String] {
        let topics = MacAccountContext.topics(in: transcript)
        guard !topics.isEmpty else { return [] }

        let readsCalendar = topics.contains(.calendar) && isMacAppConnected("apple-calendar")
        let readsMail = topics.contains(.mail) && isMacAppConnected("apple-mail")
        guard readsCalendar || readsMail else { return [] }

        let blocks = await Task.detached(priority: .userInitiated) {
            var blocks: [(String, String)] = []
            if readsCalendar {
                blocks.append(("apple-calendar", calendarReader() ?? Self.unavailableMacContext("Calendar")))
            }
            if readsMail {
                blocks.append(("apple-mail", mailReader() ?? Self.unavailableMacContext("Mail")))
            }
            return blocks
        }.value
        guard !Task.isCancelled else { return [] }
        // A user can switch an integration off while its read is in flight.
        // Recheck before any source content is passed to the model.
        return blocks.filter { isMacAppConnected($0.0) }.map(\.1)
    }

    private func isMacAppConnected(_ connectorID: String) -> Bool {
        guard isConnectorEnabledForChat(connectorID) else { return false }
        if case .connected = connectorStore.connectionState(for: connectorID) { return true }
        return false
    }

    nonisolated private static func unavailableMacContext(_ name: String) -> String {
        "\(name) context could not be read this turn. This does not mean it is empty. Do not invent its contents; explain that access is unavailable or use another enabled source."
    }
}
