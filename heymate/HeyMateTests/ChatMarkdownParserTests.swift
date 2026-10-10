//
//  ChatMarkdownParserTests.swift
//  HeyMateTests
//
//  Replies are split into prose and fenced code so code renders as code.
//

import Foundation
import Testing
@testable import HeyMate

struct ChatMarkdownParserTests {

    @Test func plainTextIsOneProseSegment() {
        #expect(ChatMarkdownParser.segments(from: "hello there") == [.prose("hello there")])
    }

    @Test func fencedCodeIsSplitOutWithoutItsFences() {
        let text = "Run this:\n```bash\ngit status\n```\nThen commit."
        #expect(ChatMarkdownParser.segments(from: text) == [
            .prose("Run this:"),
            .code("git status"),
            .prose("Then commit.")
        ])
    }

    @Test func anUnclosedFenceMidStreamIsAlreadyCode() {
        let text = "Here:\n```swift\nlet x = 1"
        #expect(ChatMarkdownParser.segments(from: text) == [
            .prose("Here:"),
            .code("let x = 1")
        ])
    }

    @Test func inlineMarkdownKeepsLineBreaksAndDropsMarkers() {
        let rendered = ChatMarkdownParser.inlineAttributedString(from: "**Save** first\n- then `push`")
        let plain = String(rendered.characters)
        #expect(plain == "Save first\n- then push")
    }

    @Test func headingLinesBecomeHeadingBlocks() {
        let blocks = ChatMarkdownParser.proseBlocks(from: "Step one.\n\n## Findings\n- **Xada:** none\n#hashtag stays")
        #expect(blocks == [
            .body("Step one."),
            .heading("Findings"),
            .body("- **Xada:** none\n#hashtag stays")
        ])
    }
}
