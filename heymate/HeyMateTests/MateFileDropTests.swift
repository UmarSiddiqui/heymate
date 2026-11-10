import Foundation
import Testing
@testable import HeyMate

struct MateFileDropTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-file-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func picturesStayInTheMessageAndOtherFilesAreHandedOver() {
        let urls = ["/tmp/a.png", "/tmp/b.pdf", "/tmp/c.JPG", "/tmp/notes", "/tmp/d.csv"].map(URL.init(fileURLWithPath:))
        let split = MateFileDrop.split(urls + [URL(string: "https://example.com/x.pdf")!])
        #expect(split.images.map(\.lastPathComponent) == ["a.png", "c.JPG"])
        #expect(split.files.map(\.lastPathComponent) == ["b.pdf", "notes", "d.csv"])
    }

    @Test func copiesLandInTheInboxAndOriginalsStay() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let mateFolder = root.appendingPathComponent("clerk", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let report = source.appendingPathComponent("report.pdf")
        try Data("one".utf8).write(to: report)

        #expect(MateFileDrop.copy([report], into: mateFolder) == ["report.pdf"])
        // A second drop of the same name keeps both.
        #expect(MateFileDrop.copy([report, source.appendingPathComponent("missing.txt")], into: mateFolder) == ["report 2.pdf"])

        let inbox = mateFolder.appendingPathComponent(MateFileDrop.inboxFolderName)
        #expect(try String(contentsOf: inbox.appendingPathComponent("report 2.pdf"), encoding: .utf8) == "one")
        #expect(FileManager.default.fileExists(atPath: report.path))
    }

    @Test func aDropTakesAtMostTheLimit() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (1...(MateFileDrop.maximumItems + 3)).map { index -> URL in
            let url = root.appendingPathComponent("file-\(index).txt")
            try Data("x".utf8).write(to: url)
            return url
        }
        let names = MateFileDrop.copy(urls, into: root.appendingPathComponent("agent", isDirectory: true))
        #expect(names.count == MateFileDrop.maximumItems)
    }

    @Test func theChatBoxNamesTheFilesAndKeepsWhatWasTyped() {
        #expect(MateFileDrop.draft(names: [], existing: "hello") == "hello")
        #expect(MateFileDrop.draft(names: ["a.pdf", "b.pdf"], existing: "  ") == "Files for you in inbox/: a.pdf, b.pdf\n")
        #expect(MateFileDrop.draft(names: ["a.pdf"], existing: "Merge these") == "Merge these\nFiles for you in inbox/: a.pdf\n")
    }
}
