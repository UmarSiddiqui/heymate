import Foundation
import Testing
@testable import HeyMate

struct ProfileInterviewTests {
    @Test func questionsAreFourAndInOrder() {
        #expect(ProfileInterview.questions.count == 4)
    }

    @Test func markdownUsesSectionsAndPlaceholder() {
        let markdown = ProfileInterview.profileMarkdown(
            name: "Umar",
            answers: ["Product design", "", "send email", "Ship the landing page"]
        )
        #expect(markdown.contains("# Umar"))
        #expect(markdown.contains("## Identity"))
        #expect(markdown.contains("Product design"))
        #expect(markdown.contains("## Apps"))
        #expect(markdown.contains(ProfileInterview.emptyAnswerPlaceholder))
        #expect(markdown.contains("## Boundaries"))
        #expect(markdown.contains("send email"))
        #expect(markdown.contains("## This week"))
        #expect(markdown.contains("Ship the landing page"))
    }

    @Test func writeCreatesProfileFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileInterviewTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try ProfileInterview.write(
            name: "Alex",
            answers: ["Editing video", "Final Cut and Notion", "delete files", "Export launch clip"],
            to: folder
        )

        let url = folder.appendingPathComponent(ProfileInterview.profileFileName)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == ProfileInterview.profileMarkdown(name: "Alex", answers: [
            "Editing video", "Final Cut and Notion", "delete files", "Export launch clip",
        ]))
    }
}
