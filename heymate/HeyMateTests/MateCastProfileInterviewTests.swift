import Foundation
import Testing
@testable import HeyMate

struct MateCastProfileInterviewTests {
    @Test func emptyProfileAnswersYieldNoMates() {
        let none = MateCast.proposals(fromProfileAnswers: ["", "", "", ""], existingNames: [])
        #expect(none.isEmpty)
        let partial = MateCast.proposals(
            fromProfileAnswers: ["Runs a studio", "", "", ""],
            existingNames: ["First Mate"]
        )
        #expect(partial.count == 3)
        #expect(Set(partial.map(\.name)).count == 3)
        #expect(partial[0].job.localizedCaseInsensitiveContains("studio"))
        #expect(partial[1].job.localizedCaseInsensitiveContains("apps"))
        #expect(partial[2].job.localizedCaseInsensitiveContains("week"))
    }

    @Test func boundaryLandsInSoul() {
        let cast = MateCast.proposals(
            fromProfileAnswers: [
                "Freelance writing",
                "Google Docs",
                "post on social",
                "Finish client draft",
            ],
            packID: "signal",
            existingNames: []
        )
        #expect(cast.count == 3)
        #expect(cast.allSatisfy { $0.soul.localizedCaseInsensitiveContains("post on social") })
        #expect(cast.allSatisfy { $0.soul.localizedCaseInsensitiveContains("without me asking") })
        #expect(cast[1].job.localizedCaseInsensitiveContains("Google Docs"))
    }
}
