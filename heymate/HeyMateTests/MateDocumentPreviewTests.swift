import Foundation
import Testing
@testable import HeyMate

struct MateDocumentPreviewTests {
    @Test func markdownKeepsEntireDocument() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "# Review\n\n" + String(repeating: "Complete document content.\n", count: 200)
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(MateDocumentContent.load(path: url.path) == .markdown(text))
    }

    @Test func missingFileShowsUnavailableState() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        guard case .unavailable = MateDocumentContent.load(path: path) else {
            Issue.record("Missing file must not become an empty preview")
            return
        }
    }

    @Test func oversizedTextShowsExplicitFallback() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: url)
        guard case .unavailable = MateDocumentContent.load(path: url.path) else {
            Issue.record("Oversized text must not be silently truncated")
            return
        }
    }
}
