import Foundation
import Testing
@testable import HeyMate

struct MateAddressWorkspaceSuggestionTests {

    @Test func tellAskAndMessageRouteTheRemainder() {
        let told = MateAddressParser.parse("tell Inbox Scout that the draft is ready")
        #expect(told?.mateName == "Inbox Scout")
        #expect(told?.message == "the draft is ready")
        let asked = MateAddressParser.parse("please ask Field Notes to save this")
        #expect(asked?.message == "save this")
        #expect(MateAddressParser.parse("hello there") == nil)
    }

    @Test func spokenNameLandsOnTheLongestMate() {
        let scout = sampleMate(name: "Inbox Scout")
        let inbox = sampleMate(name: "Inbox")
        let match = MateAddressParser.match("the Inbox Scout", mates: [inbox, scout])
        #expect(match?.id == scout.id)
        #expect(MateAddressParser.match("nobody", mates: [scout]) == nil)
    }

    @Test func newMateGetsAFolderOfFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-workspace-\(UUID().uuidString)", isDirectory: true)
        let mate = sampleMate(name: "Inbox Scout")
        let folder = try MateWorkspace.ensureFolder(for: mate, projectsRoot: root)
        #expect(folder.lastPathComponent == "inbox-scout")
        let note = folder.appendingPathComponent("note.md")
        try "Hello mate".write(to: note, atomically: true, encoding: .utf8)
        let names = MateWorkspace.files(in: folder.path).map(\.name)
        #expect(names == ["note.md"])
        #expect(MateWorkspace.previewText(at: note.path) == "Hello mate")
        try? FileManager.default.removeItem(at: root)
    }

    private func sampleMate(name: String, job: String = "A job") -> Mate {
        Mate(
            id: UUID(),
            name: name,
            job: job,
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: Date(),
            updatedAt: Date(),
            memoryNote: "",
            folderPath: nil
        )
    }
}
