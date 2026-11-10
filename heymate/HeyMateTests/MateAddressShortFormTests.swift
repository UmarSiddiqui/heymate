import Foundation
import Testing
@testable import HeyMate

struct MateAddressShortFormTests {
    private func mate(_ name: String, archived: Bool = false) -> Mate {
        Mate(
            id: UUID(), name: name, job: "Job", pinned: false, archived: archived,
            unreadCount: 0, createdAt: Date(), updatedAt: Date(), memoryNote: ""
        )
    }

    @Test func shortFormsReachTheNamedAgent() {
        let clerk = mate("Desk Clerk")
        let scout = mate("Scout")
        let mates = [scout, clerk]
        let cases = [
            "@Desk Clerk merge these", "@desk clerk, merge these", "Desk Clerk, merge these",
            "desk clerk: merge these", "hey Desk Clerk merge these", "Hey Desk Clerk, merge these",
            "have Desk Clerk merge these", "get Desk Clerk to merge these", "ask Desk Clerk to merge these"
        ]
        for text in cases {
            let resolved = MateAddressParser.resolve(text, mates: mates)
            #expect(resolved?.mate.id == clerk.id, "\(text)")
            #expect(resolved?.message == "merge these", "\(text)")
        }
    }

    @Test func leadingAgentNameWinsOverContextToken() {
        let clipboard = mate("Clipboard")
        let clerk = mate("Clipboard Clerk")
        let mates = [clipboard, clerk]
        for mention in ["@Clipboard", "@Clipboard,", "@Clipboard:"] {
            let single = CommandBarParser.parseForAgentSend("\(mention) summarize this", mates: mates)
            #expect(single.mate?.id == clipboard.id)
            #expect(single.input == .message(text: "summarize this", contextTokens: []))
        }

        let multi = CommandBarParser.parseForAgentSend("@clipboard  clerk summarize this @skills", mates: mates)
        #expect(multi.mate?.id == clerk.id)
        #expect(multi.input == .message(text: "summarize this", contextTokens: [.skills]))

        let explicit = CommandBarParser.parseForAgentSend("summarize this @clipboard", mates: mates)
        #expect(explicit.mate == nil)
        #expect(explicit.input == .message(text: "summarize this", contextTokens: [.clipboard]))

        let noMatch = CommandBarParser.parseForAgentSend("@clipboard summarize this", mates: [])
        #expect(noMatch.mate == nil)
        #expect(noMatch.input == .message(text: "summarize this", contextTokens: [.clipboard]))
    }

    @Test func ordinarySentencesGoNowhere() {
        let mates = [mate("Scout"), mate("Desk Clerk"), mate("Gone", archived: true)]
        let plain = [
            "About the Scout draft, can you shorten it", "Thanks, that works", "Scout",
            "Scout,", "Scouting, the report is late", "Gone, merge these", "have a look at this"
        ]
        for text in plain {
            #expect(MateAddressParser.resolve(text, mates: mates) == nil, "\(text)")
        }
    }

    @Test func theLongerNameWins() {
        let scout = mate("Scout")
        let inbox = mate("Scout Two")
        let resolved = MateAddressParser.resolve("Scout Two, check mail", mates: [scout, inbox])
        #expect(resolved?.mate.id == inbox.id)
        #expect(resolved?.message == "check mail")
    }
}
