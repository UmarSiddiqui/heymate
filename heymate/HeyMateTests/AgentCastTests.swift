import Foundation
import Testing
@testable import HeyMate

struct AgentCastTests {
    @Test func suggestionsHideWhenThatWorkAlreadyExists() {
        let open = AgentSuggestionCatalog.offers(existingJobs: ["General chat"])
        #expect(open.map(\.name) == ["Inbox Scout", "Screen Guide", "Desk Clerk", "Marketing Partner", "Developer", "LinkedIn Manager"])
        let taken = AgentSuggestionCatalog.offers(existingJobs: ["Watch the inbox every morning"])
        #expect(taken.map(\.name) == ["Screen Guide", "Desk Clerk", "Marketing Partner", "Developer", "LinkedIn Manager"])
    }
}
