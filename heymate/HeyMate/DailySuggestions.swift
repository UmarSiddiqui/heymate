//
//  DailySuggestions.swift
//  HeyMate
//
//  A local deck of at most three nudges from recent mates, tasks, and
//  connected apps. Skipping the same title twice removes it from the deck.
//

import Foundation

enum DailySuggestionAction: String, Equatable, CaseIterable {
    case approve
    case skip
    case adjust
}

struct DailySuggestionCard: Equatable, Identifiable {
    var id: String { title }
    let title: String
    let detail: String

    static let actions: [DailySuggestionAction] = DailySuggestionAction.allCases
}

enum DailySuggestions {
    static let maxCards = 3
    static let skipFatigueThreshold = 2

    static func deck(
        recentMateNames: [String],
        recentTaskTitles: [String],
        connectedAppNames: [String],
        skippedTitleCounts: [String: Int] = [:]
    ) -> [DailySuggestionCard] {
        var candidates: [DailySuggestionCard] = []

        for task in cleanedUnique(recentTaskTitles) {
            candidates.append(
                DailySuggestionCard(
                    title: "Pick up \"\(task)\"",
                    detail: "Continue where you left off and say what changed since last time."
                )
            )
        }

        for app in cleanedUnique(connectedAppNames) {
            candidates.append(
                DailySuggestionCard(
                    title: "Check \(app)",
                    detail: "Look for one thing waiting in \(app) and offer to handle or draft it."
                )
            )
        }

        for mate in cleanedUnique(recentMateNames) {
            candidates.append(
                DailySuggestionCard(
                    title: "Ask \(mate)",
                    detail: "Send \(mate) the next small step on something you already started together."
                )
            )
        }

        if candidates.isEmpty {
            candidates.append(
                DailySuggestionCard(
                    title: "Plan one small win",
                    detail: "Name one thing you want off your plate today and who should do it."
                )
            )
        }

        return candidates
            .filter { (skippedTitleCounts[$0.title] ?? 0) < skipFatigueThreshold }
            .prefix(maxCards)
            .map { $0 }
    }

    private static func cleanedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            ordered.append(trimmed)
        }
        return ordered
    }
}
