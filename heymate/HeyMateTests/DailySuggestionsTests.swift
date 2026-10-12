import Foundation
import Testing
@testable import HeyMate

struct DailySuggestionsTests {
    @Test func deckCapsAtThree() {
        let deck = DailySuggestions.deck(
            recentMateNames: ["Scout", "Guide", "Clerk", "Extra"],
            recentTaskTitles: ["Inbox", "Notes", "Export", "Review"],
            connectedAppNames: ["Mail", "Calendar", "Drive", "Slack"]
        )
        #expect(deck.count == DailySuggestions.maxCards)
    }

    @Test func skippedTwiceRemovesTitle() {
        let title = "Pick up \"Inbox\""
        let skipped = [title: DailySuggestions.skipFatigueThreshold]
        let deck = DailySuggestions.deck(
            recentMateNames: [],
            recentTaskTitles: ["Inbox", "Notes"],
            connectedAppNames: ["Mail"],
            skippedTitleCounts: skipped
        )
        #expect(deck.contains { $0.title == title } == false)
        #expect(deck.first?.title == "Pick up \"Notes\"")
    }

    @Test func cardsExposeAllActions() {
        #expect(DailySuggestionCard.actions == [.approve, .skip, .adjust])
    }
}
