//
//  MateRailTabsTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct MateRailTabsTests {

    private let mainID = UUID()
    private let builderID = UUID()

    private func session(
        _ title: String,
        mateID: UUID?,
        minutesAgo: Double,
        text: String = "hello"
    ) -> ChatSession {
        let date = Date().addingTimeInterval(-minutesAgo * 60)
        return ChatSession(
            id: UUID(),
            title: title,
            createdAt: date,
            updatedAt: date,
            messages: [ChatMessage(id: UUID(), role: .user, text: text, createdAt: date)],
            mateID: mateID
        )
    }

    @Test func chatsIsTheDefaultTabAndMatesIsSecond() {
        #expect(MateRailTab.allCases == [.chats, .mates])
        #expect(MateRailTab.defaultTab == .chats)
        #expect(MateRailTab.stored("") == .chats)
        #expect(MateRailTab.stored("bogus") == .chats)
        #expect(MateRailTab.stored("mates") == .mates)
        #expect(MateRailTab.chats.searchPrompt == "Search chats")
        #expect(MateRailTab.mates.searchPrompt == "Search mates")
    }

    @Test func chatsTabListsOnlyMainHeyMateNewestFirst() {
        let old = session("Old", mateID: mainID, minutesAgo: 30)
        let legacy = session("Legacy", mateID: nil, minutesAgo: 20)
        let recent = session("Recent", mateID: mainID, minutesAgo: 1)
        let builder = session("Builder chat", mateID: builderID, minutesAgo: 0)
        let list = MainChatList.sessions(
            saved: [old, builder, legacy, recent],
            current: recent,
            defaultMateID: mainID,
            query: ""
        )
        #expect(list.map(\.title) == ["Recent", "Legacy", "Old"])
    }

    @Test func freshUnsavedMainChatIsListedButAMatesIsNot() {
        let saved = session("Saved", mateID: mainID, minutesAgo: 5)
        var fresh = ChatSession.empty()
        fresh.mateID = mainID
        let withFresh = MainChatList.sessions(saved: [saved], current: fresh, defaultMateID: mainID, query: "")
        #expect(withFresh.first?.id == fresh.id)
        #expect(withFresh.count == 2)

        var mateChat = ChatSession.empty()
        mateChat.mateID = builderID
        let withMate = MainChatList.sessions(saved: [saved], current: mateChat, defaultMateID: mainID, query: "")
        #expect(withMate.map(\.id) == [saved.id])
    }

    @Test func chatSearchMatchesTitlesAndMessages() {
        let trip = session("Trip plan", mateID: mainID, minutesAgo: 3)
        let taxes = session("Numbers", mateID: mainID, minutesAgo: 2, text: "help with my taxes")
        let mateTaxes = session("Taxes", mateID: builderID, minutesAgo: 1)
        let byTitle = MainChatList.sessions(saved: [trip, taxes, mateTaxes], current: trip, defaultMateID: mainID, query: " trip ")
        #expect(byTitle.map(\.id) == [trip.id])
        let byMessage = MainChatList.sessions(saved: [trip, taxes, mateTaxes], current: trip, defaultMateID: mainID, query: "TAXES")
        #expect(byMessage.map(\.id) == [taxes.id])
    }

    @Test func mainRowIsSelectedOnlyWhileMainHeyMateIsOpen() {
        let main = session("Main", mateID: mainID, minutesAgo: 1)
        #expect(MainChatList.selectedID(current: main, activeMateID: mainID, defaultMateID: mainID) == main.id)
        #expect(MainChatList.selectedID(current: main, activeMateID: nil, defaultMateID: mainID) == main.id)
        let mateChat = session("Builder", mateID: builderID, minutesAgo: 1)
        #expect(MainChatList.selectedID(current: mateChat, activeMateID: builderID, defaultMateID: mainID) == nil)
        #expect(MainChatList.selectedID(current: main, activeMateID: builderID, defaultMateID: mainID) == nil)
    }
}
