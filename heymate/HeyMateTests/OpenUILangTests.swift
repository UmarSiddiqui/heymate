//
//  OpenUILangTests.swift
//  HeyMateTests
//
//  OpenUI Lang blocks in replies parse into a tree HeyMate can draw, hold
//  up mid-stream, and copy out as readable text instead of their source.
//

import Foundation
import Testing
@testable import HeyMate

struct OpenUILangTests {

    @Test func rootResolvesForwardReferences() {
        let document = OpenUILangParser.parse("""
        root = Card([title, Stat("Revenue", "$1.2M", "+12%")], "Q3")
        title = TextContent("Quarter at a glance", "heading")
        """)
        guard case .component(let card) = document.root else {
            Issue.record("root did not resolve to a component")
            return
        }
        #expect(card.name == "Card")
        #expect(card.arg(1) == .string("Q3"))
        #expect(card.arg(0)?.array?.first == .component(OpenUIComponent(
            name: "TextContent", args: [.string("Quarter at a glance"), .string("heading")]
        )))
    }

    @Test func withoutRootTheFirstComponentIsTheEntry() {
        let document = OpenUILangParser.parse("$compact = false\nview = TextContent(\"3 open\")")
        #expect(document.root == .component(OpenUIComponent(name: "TextContent", args: [.string("3 open")])))
    }

    @Test func laterDefinitionsWin() {
        let document = OpenUILangParser.parse("root = a\na = TextContent(\"old\")\na = TextContent(\"new\")")
        #expect(document.root == .component(OpenUIComponent(name: "TextContent", args: [.string("new")])))
    }

    @Test func literalsActionsAndEscapes() {
        let document = OpenUILangParser.parse(#"root = Button("Go \"now\"", @ToAssistant("next"), null, 3.5, true, {id: 42})"#)
        guard case .component(let button) = document.root else {
            Issue.record("no button")
            return
        }
        #expect(button.args == [
            .string(#"Go "now""#),
            .action(OpenUIComponent(name: "ToAssistant", args: [.string("next")])),
            .null,
            .number(3.5),
            .bool(true),
            .object([OpenUIField(key: "id", value: .number(42))])
        ])
        #expect(button.arg(2) == nil)
    }

    @Test func anUnfinishedStatementMidStreamStillDraws() {
        let document = OpenUILangParser.parse("root = Table([\"Plan\", \"Price\"], [[\"Pro\", \"$12")
        guard case .component(let table) = document.root else {
            Issue.record("partial table did not parse")
            return
        }
        #expect(OpenUIPlainText.cells(table.arg(1)) == [["Pro", "$12"]])
    }

    @Test func anUndefinedNameDrawsNothingYet() {
        let document = OpenUILangParser.parse("root = Stack([header, body])\nheader = TextContent(\"Hi\")")
        guard case .component(let stack) = document.root else {
            Issue.record("no stack")
            return
        }
        #expect(stack.arg(0)?.array?.count == 2)
        #expect(stack.args.first?.array?.last == .null)
    }

    @Test func aCallMayWrapAcrossLines() {
        let document = OpenUILangParser.parse("root = List([\n  \"one\",\n  \"two\",\n])")
        #expect(document.root == .component(OpenUIComponent(name: "List", args: [.array([.string("one"), .string("two")])])))
    }

    @Test func fencedOpenUIIsItsOwnSegment() {
        let text = "Here's the split:\n```openui\nroot = TextContent(\"x\")\n```\nDone."
        #expect(ChatMarkdownParser.segments(from: text) == [
            .prose("Here's the split:"),
            .ui("root = TextContent(\"x\")"),
            .prose("Done.")
        ])
        #expect(ChatMarkdownParser.segments(from: "```swift\nlet a = 1\n```") == [.code("let a = 1")])
    }

    @Test func copyingAReplyWritesTheBlockAsText() {
        let reply = """
        Two plans fit.
        ```openui
        root = Stack([Table(["Plan", "Price"], [["Pro", "$12"], ["Team", "$20"]]), Stat("Saving", "17%", "yearly"), go])
        go = Button("Pick Pro", @ToAssistant("pick pro"))
        ```
        """
        #expect(ChatReplyText.readableMarkdown(reply) == """
        Two plans fit.

        | Plan | Price |
        | --- | --- |
        | Pro | $12 |
        | Team | $20 |

        Saving: **17%** (yearly)
        """)
        #expect(ChatReplyText.plainText("**Bold** and `code`") == "Bold and code")
    }

    @Test func tablesCopyAsTabSeparatedCells() {
        #expect(OpenUIPlainText.tabSeparated(columns: ["A", "B"], rows: [["1", "2"]]) == "A\tB\n1\t2")
    }

    @Test func progressAcceptsFractionsPercentsAndMaximums() {
        #expect(OpenUIProgress.percentText(OpenUIComponent(name: "Progress", args: [.string("a"), .number(0.4)])) == "40%")
        #expect(OpenUIProgress.percentText(OpenUIComponent(name: "Progress", args: [.string("a"), .number(65)])) == "65%")
        #expect(OpenUIProgress.percentText(OpenUIComponent(name: "Progress", args: [.string("a"), .number(3), .number(4)])) == "75%")
    }

    @Test func captionsNeverShowOpenUISource() {
        let caption = GuidedReplyParser.strippingMarkdownEmphasis("Done.\n```openui\nroot = TextContent(\"All **set**\")\n```")
        #expect(!caption.contains("root ="))
        #expect(caption.contains("All set"))
    }
}
