//
//  AgentFolderNamingTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct AgentFolderNamingTests {

    @Test func slugIsLowercaseHyphenatedAndCapped() {
        #expect(AgentFolderNaming.slug(from: "Make a Landing Page!") == "make-a-landing-page")
        #expect(AgentFolderNaming.slug(from: "---") == "agent")
        #expect(AgentFolderNaming.slug(from: "") == "agent")
        let longPrompt = String(repeating: "a", count: 80)
        #expect(AgentFolderNaming.slug(from: longPrompt).count == AgentFolderNaming.maximumSlugLength)
    }

    @Test func shortIDIsFourHexCharacters() {
        let uuid = UUID(uuidString: "AABBCCDD-0000-0000-0000-000000000000")!
        #expect(AgentFolderNaming.shortID(from: uuid) == "aabb")
    }

    @Test func sandboxPathLivesUnderProjectsHeymate() {
        let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
        let uuid = UUID(uuidString: "AABBCCDD-0000-0000-0000-000000000000")!
        let folder = AgentFolderNaming.sandboxFolderURL(
            prompt: "landing page",
            uuid: uuid,
            homeDirectoryURL: home
        )
        #expect(folder.path == "/Users/demo/Projects/heymate/landing-page-aabb")
    }
}
