import Foundation
import Testing
@testable import HeyMate

struct MateFirstMomentTests {
    @Test func tutorAndReviewerHaveDistinctTruthfulIntroductions() {
        let mira = mate(name: "Mira", job: "a patient design tutor")
        let bolt = mate(name: "Bolt", job: "a practical code reviewer")
        #expect(MateFirstMoment.greeting(for: mira).hasPrefix("I'm Mira."))
        #expect(MateFirstMoment.greeting(for: mira).contains("one step at a time"))
        #expect(MateFirstMoment.starter(for: mira).label == "Choose something to learn")
        #expect(MateFirstMoment.greeting(for: bolt).hasPrefix("I'm Bolt."))
        #expect(MateFirstMoment.greeting(for: bolt).contains("Share a small change"))
        #expect(MateFirstMoment.starter(for: bolt).label == "Review a small change")
        #expect(MateFirstMoment.starter(for: bolt).prompt.contains("Ask which project or snippet"))
        #expect(MateFirstMoment.chat(for: mira).firstMoment?.confirmation == "Mira was created · a patient design tutor")
    }

    @Test func savedTeachingStyleShapesTheLocalGreeting() {
        var tutor = mate(name: "Mira", job: "Photopea tutor")
        #expect(!MateFirstMoment.greeting(for: tutor).contains("one step at a time"))
        tutor.soul = "Explain one step then wait."
        #expect(MateFirstMoment.greeting(for: tutor).contains("one step at a time"))
    }

    @Test func customRoleGetsNeutralInvitationWithoutInventedSpecialty() {
        var echo = mate(name: "Echo", job: "catalogues unusual sounds")
        echo.soul = "Be curious. Do not start coding jobs."
        #expect(MateFirstMoment.chat(for: echo).firstMoment?.role == "catalogues unusual sounds")
        #expect(MateFirstMoment.greeting(for: echo).hasPrefix("I'm Echo."))
        #expect(MateFirstMoment.starter(for: echo).label == "Describe a first task")
        #expect(!MateFirstMoment.greeting(for: echo).contains("reviewed"))
        #expect(!MateFirstMoment.greeting(for: echo).contains("HeyMate"))
        #expect(MateFirstMoment.chat(for: echo).apiHistoryPairs().isEmpty)
    }

    @Test func firstMomentRoundTripsAndOldChatsStillDecode() throws {
        let chat = MateFirstMoment.chat(for: mate(name: "Mira", job: "a patient design tutor"))
        let data = try JSONEncoder().encode(chat)
        #expect(try JSONDecoder().decode(ChatSession.self, from: data) == chat)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "firstMoment")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let oldChat = try JSONDecoder().decode(ChatSession.self, from: oldData)
        #expect(oldChat.firstMoment == nil)
        #expect(oldChat.messages == chat.messages)
    }

    private func mate(name: String, job: String) -> Mate {
        Mate(id: UUID(), name: name, job: job, pinned: false, archived: false,
             unreadCount: 0, createdAt: Date(), updatedAt: Date(), memoryNote: "", folderPath: nil)
    }
}
