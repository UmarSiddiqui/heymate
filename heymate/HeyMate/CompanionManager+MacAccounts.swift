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
    func macAccountContextBlocks(for transcript: String) async -> [String] {
        let topics = MacAccountContext.topics(in: transcript)
        guard !topics.isEmpty else { return [] }

        let readsCalendar = topics.contains(.calendar) && isMacAppConnected("apple-calendar")
        let readsMail = topics.contains(.mail) && isMacAppConnected("apple-mail")
        guard readsCalendar || readsMail else { return [] }

        return await Task.detached(priority: .userInitiated) {
            var blocks: [String] = []
            if readsCalendar, let block = MacAccountContext.calendarBlock() {
                blocks.append(block)
            }
            if readsMail, let block = MacAccountContext.mailBlock() {
                blocks.append(block)
            }
            return blocks
        }.value
    }

    private func isMacAppConnected(_ connectorID: String) -> Bool {
        if case .connected = connectorStore.connectionState(for: connectorID) { return true }
        return false
    }
}
