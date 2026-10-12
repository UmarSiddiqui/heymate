import Foundation
import Testing
@testable import HeyMate

struct AgentReplyBlocksTests {
    @Test func stripsBlocksAndKeepsTheAnswer() {
        let text = """
        2 files and 1 folder.
        <SUMMARY>Counted the sample workspace.</SUMMARY>
        <DONE_TITLE>
        Sample count
        </DONE_TITLE>
        <COMPUTER_USE_REQUEST>
        Open the folder in Finder so you can see the two files.
        </COMPUTER_USE_REQUEST>
        """
        let blocks = AgentReplyBlocks.extract(from: text)
        #expect(blocks.spokenText == "2 files and 1 folder.")
        #expect(blocks.summary == "Counted the sample workspace.")
        #expect(blocks.presentedSummary == "Counted the sample workspace.")
        #expect(blocks.doneTitle == "Sample count")
        #expect(blocks.computerUseRequest == "Open the folder in Finder so you can see the two files.")
        #expect(blocks.routine == nil)
    }

    @Test func capsSummaryAndNextActionsWhileKeepingTheRawText() {
        let summary = String(repeating: "a", count: 250)
        let longAction = "Open " + String(repeating: "b", count: 50)
        var lines = ["- \(longAction)"]
        lines.append(contentsOf: (1...5).map { "\($0). Step \($0)" })
        let text = """
        Answer.
        <SUMMARY>\(summary)</SUMMARY>
        <NEXT_ACTIONS>
        \(lines.joined(separator: "\n"))
        </NEXT_ACTIONS>
        """
        let blocks = AgentReplyBlocks.extract(from: text)
        #expect(blocks.summary == summary)
        #expect(blocks.presentedSummary?.count == AgentReplyBlocks.presentedSummaryLimit)
        #expect(blocks.nextActions.count == 6)
        #expect(blocks.nextActions[0] == longAction)
        #expect(blocks.presentedNextActions.count == 4)
        #expect(blocks.presentedNextActions[0] == String(longAction.prefix(AgentReplyBlocks.presentedNextActionCharacterLimit)))
        #expect(blocks.presentedNextActions.allSatisfy { $0.count <= AgentReplyBlocks.presentedNextActionCharacterLimit })
    }

    @Test func presentedArtifactsLeaveOutScratchPaths() {
        let text = """
        Wrote the report.
        <ARTIFACTS>
        output/report.md
        tmp/notes.txt
        ./tmp/draft.md
        /tmp/outside.txt
        output/tmp/scratch.md
        TMP/again.txt
        https://example.test/post
        https://example.test/tmp/scratch
        </ARTIFACTS>
        """
        let blocks = AgentReplyBlocks.extract(from: text)
        #expect(blocks.artifacts.count == 8)
        #expect(blocks.presentedArtifacts == ["output/report.md", "https://example.test/post"])
    }

    @Test func lastBlockWinsAndABrokenTagStaysInTheAnswer() {
        let text = """
        Keep <DONE_TITLE>unclosed
        <SUMMARY>First</SUMMARY>
        <SUMMARY>Second</SUMMARY>
        """
        let blocks = AgentReplyBlocks.extract(from: text)
        #expect(blocks.summary == "Second")
        #expect(blocks.spokenText.contains("unclosed"))
        #expect(!blocks.spokenText.contains("<SUMMARY>First</SUMMARY>"))
    }

    @Test func routineDecodesEachActionAndDropsBadJSON() {
        let created = AgentReplyBlocks.extract(from: """
        Done counting.
        <ROUTINE>{"action":"create","every_minutes":30,"title":"Digest","task":"Count the inbox"}</ROUTINE>
        """)
        #expect(created.spokenText == "Done counting.")
        guard case .create(let every, let title, let task) = created.routine?.declaration else {
            Issue.record("Expected a create declaration")
            return
        }
        #expect(every == 30)
        #expect(title == "Digest")
        #expect(task == "Count the inbox")

        let updated = AgentReplyBlocks.extract(from: """
        <ROUTINE>
        ```json
        {"action":"update","every_minutes":15,"title":"Digest","task":"Count unread","new_title":"Morning digest"}
        ```
        </ROUTINE>
        """)
        guard case .update(let minutes, let oldTitle, let task, let newTitle) = updated.routine?.declaration else {
            Issue.record("Expected an update declaration")
            return
        }
        #expect(minutes == 15)
        #expect(oldTitle == "Digest")
        #expect(task == "Count unread")
        #expect(newTitle == "Morning digest")

        for sample in [
            (#"{"action":"pause","title":"Digest"}"#, "pause"),
            (#"{"action":"resume","title":"Digest"}"#, "resume"),
            (#"{"action":"delete","title":"Digest"}"#, "delete")
        ] {
            let blocks = AgentReplyBlocks.extract(from: "<ROUTINE>\(sample.0)</ROUTINE>")
            switch blocks.routine?.declaration {
            case .pause(let title):
                #expect(sample.1 == "pause")
                #expect(title == "Digest")
            case .resume(let title):
                #expect(sample.1 == "resume")
                #expect(title == "Digest")
            case .delete(let title):
                #expect(sample.1 == "delete")
                #expect(title == "Digest")
            case .create(_, _, _), .update(_, _, _, _), nil:
                Issue.record("Expected \(sample.1)")
            }
        }

        let broken = AgentReplyBlocks.extract(from: """
        Still the answer.
        <ROUTINE>{"action":"archive"}</ROUTINE>
        """)
        #expect(broken.spokenText == "Still the answer.")
        #expect(broken.routine == nil)
    }

    @Test func summaryRedactionStillRemovesASyntheticToken() {
        let token = "ghp_" + String(repeating: "x", count: 30)
        let text = MateRunReport.finished(
            summary: "Long answer.\n<SUMMARY>Counted 2 files. \(token)</SUMMARY>",
            changedFileCount: 0
        )
        #expect(text.hasPrefix("Result\n\nCounted 2 files."))
        #expect(!text.contains(token))
        #expect(!text.contains("Long answer"))
    }
}
