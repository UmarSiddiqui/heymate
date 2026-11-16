import Foundation
import Testing
@testable import HeyMate

struct MateFilesTests {
    private func scratch() throws -> (base: URL, folder: URL, data: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mate-files-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("mate", isDirectory: true)
        let data = base.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (base, folder, data)
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func pathsStayInsideTheFolderAfterSymlinksAndDotDot() throws {
        let (base, folder, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        try write("secret", base.appendingPathComponent("outside.txt"))
        try write("mine", folder.appendingPathComponent("notes/plan.md"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: base)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("inner"),
                                                   withDestinationURL: folder.appendingPathComponent("notes"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("dangling"),
                                                   withDestinationURL: base.appendingPathComponent("missing"))

        #expect(MateFolderGuard.url(forRelative: "notes/plan.md", in: folder) != nil)
        #expect(MateFolderGuard.url(forRelative: "notes/new.md", in: folder) != nil)
        #expect(MateFolderGuard.url(forRelative: "../outside.txt", in: folder) == nil)
        #expect(MateFolderGuard.url(forRelative: "notes/../../outside.txt", in: folder) == nil)
        #expect(MateFolderGuard.url(forRelative: "escape/outside.txt", in: folder) == nil)
        #expect(MateFolderGuard.url(forRelative: "escape/new.txt", in: folder) == nil)
        #expect(MateFolderGuard.url(forRelative: "dangling", in: folder) == nil)
        #expect(MateFolderGuard.url(forRelative: "/etc/hosts", in: folder) == nil)
        #expect(MateFolderGuard.url(forRelative: "inner/plan.md", in: folder) != nil)
        #expect(MateFolderGuard.relativePath(of: folder.appendingPathComponent("inner/plan.md"), in: folder) == "notes/plan.md")
        #expect(!MateFolderGuard.isValidName("../x") && !MateFolderGuard.isValidName(".hidden") && MateFolderGuard.isValidName("Plan 2.md"))

        let actions = MateFileStore(folder: folder, dataRoot: base.appendingPathComponent("data"))
        #expect(throws: MateFileActionError.self) {
            try MateFileActions.rename("notes/plan.md", to: "../../evil", in: folder, store: actions)
        }
        #expect(throws: MateFileActionError.self) {
            try MateFileActions.newFolder(named: "x", inDirectory: "escape", in: folder)
        }
        #expect(throws: MateFileActionError.self) {
            try MateFileActions.moveToTrash("escape/outside.txt", in: folder, store: actions)
        }
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("outside.txt").path))
    }

    @Test func treeSkipsHiddenAndEscapingLinksPagesLargeFoldersAndSorts() throws {
        let (base, folder, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        try write("x", folder.appendingPathComponent(".secret"))
        try write("x", base.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.txt"),
                                                   withDestinationURL: base.appendingPathComponent("outside.txt"))
        for index in 0..<12 { try write("\(index)", folder.appendingPathComponent("many/file \(index).txt")) }
        try write("b", folder.appendingPathComponent("b.txt"))
        try write("a", folder.appendingPathComponent("a.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)],
                                              ofItemAtPath: folder.appendingPathComponent("b.txt").path)

        let top = MateFileTree.list("", in: folder, sort: .name)
        #expect(top.entries.map(\.name) == ["many", "a.txt", "b.txt"])
        #expect(MateFileTree.list("", in: folder, sort: .modified).entries.first?.name == "b.txt")

        let many = MateFileTree.list("many", in: folder, sort: .name, pageSize: 5)
        #expect(many.shown.count == 5 && many.remaining == 7)
        #expect(many.shown.first?.relativePath == "many/file 0.txt")
        let rows = MateFileTree.rows(listings: ["": top, "many": many], expanded: ["many"])
        #expect(rows.count == 3 + 5 + 1)
        #expect(rows[6] == .more(directory: "many", remaining: 7, depth: 1))
        #expect(MateFileTree.rows(listings: ["": top, "many": many], expanded: []).count == 3)

        let found = MateFileTree.search("FILE 1", in: folder)
        #expect(Set(found.matches.map(\.name)) == ["file 1.txt", "file 10.txt", "file 11.txt"])
        #expect(found.complete)
        #expect(MateFileTree.search("file", in: folder, limit: 2).matches.count == 2)
        #expect(!MateFileTree.search("file", in: folder, limit: 2).complete)
        #expect(MateFileTree.search("secret", in: folder).matches.isEmpty)
        #expect(MateFileTree.search("escape", in: folder).matches.isEmpty)
        #expect(MateFileTree.list("../", in: folder, sort: .name).entries.isEmpty)
    }

    @Test func originsFoldMovesRemovalsAndFoldersFromRecordedEvents() throws {
        let (base, folder, data) = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = MateFileStore(folder: folder, dataRoot: data)
        store.record(.person, relativePaths: ["inbox/report.pdf", "inbox/photos"])
        store.record(.mate, relativePaths: ["draft.md"])
        store.recordMove(from: "draft.md", to: "final.md")
        store.recordMove(from: "inbox", to: "given")
        store.recordRemoval("given/report.pdf")
        // A line appended by the runtime in its own encoding.
        let runtimeLine = #"{"path":"notes/a.md","origin":"mate","at":"2026-11-16T00:00:00.000Z"}"# + "\nnot json\n"
        let handle = try FileHandle(forWritingTo: store.originsURL)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(runtimeLine.utf8)); try handle.close()

        let origins = store.origins()
        #expect(MateFileOrigins.origin(of: "final.md", in: origins) == .mate)
        #expect(MateFileOrigins.origin(of: "draft.md", in: origins) == .other)
        #expect(MateFileOrigins.origin(of: "given/photos/cat.jpg", in: origins) == .person)
        #expect(MateFileOrigins.origin(of: "given/report.pdf", in: origins) == .other)
        #expect(MateFileOrigins.origin(of: "notes/a.md", in: origins) == .mate)
        #expect(store.root.path.hasPrefix(data.path))
        #expect(MateFolderGuard.storeKey(for: folder) == MateFolderGuard.storeKey(for: folder.appendingPathComponent("x/..")))
    }

    @Test func versionsArePrunedPerFileAndAcrossTheMate() {
        func version(_ id: String, _ second: Int, size: Int64 = 10) -> MateFileVersion {
            MateFileVersion(id: id, at: String(format: "2026-01-01T00:00:%02d.000Z", second), size: size, source: "mate")
        }
        var index = MateFileVersionIndex()
        index.files["a"] = (0..<12).map { version("a\($0)", $0) }
        index.files["b"] = [version("b0", 0, size: 1), version("b1", 30, size: 1)]
        let perFile = MateFileVersionPolicy.prune(index)
        #expect(perFile.index.files["a"]?.map(\.id) == (2..<12).map { "a\($0)" })
        #expect(perFile.removed == ["a0", "a1"])
        let total = MateFileVersionPolicy.prune(index, totalBytes: 61)
        #expect(total.index.files["a"]?.count == 6)
        #expect(total.index.files["b"]?.map(\.id) == ["b1"])
    }

    @Test func restoreKeepsTheReplacedBytesAndHistoryFollowsRenames() throws {
        let (base, folder, data) = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = MateFileStore(folder: folder, dataRoot: data)
        let file = folder.appendingPathComponent("plan.md")
        try write("first", file)
        let first = try #require(try store.snapshot("plan.md", source: "mate"))
        try write("second", file)
        try store.restore(first, of: "plan.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == "first")
        let versions = store.versions(of: "plan.md")
        #expect(versions.map(\.source) == ["restore", "mate"])
        #expect(store.data(of: versions[0]).flatMap { String(data: $0, encoding: .utf8) } == "second")
        try MateFileActions.rename("plan.md", to: "Plan v2.md", in: folder, store: store)
        #expect(store.versions(of: "Plan v2.md").count == 2)
        #expect(store.versions(of: "plan.md").isEmpty)
        #expect(throws: MateFileStoreError.self) { try store.snapshot("../escape", source: "mate") }
    }

    @Test func lineDiffMarksChangesAndFoldsUnchangedRuns() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 10", with: "line ten") + "\nline 21"
        let lines = MateTextDiff.lines(old: old, new: new)
        #expect(lines.contains(.removed("line 10")) && lines.contains(.added("line ten")) && lines.contains(.added("line 21")))
        #expect(lines.filter { if case .same = $0 { return true }; return false }.count == 19)
        let compact = MateTextDiff.compact(lines, context: 1)
        #expect(compact.first == .skipped(8))
        #expect(MateTextDiff.lines(old: "a\nb", new: "c\nd", maximumCells: 1) == [.removed("a"), .removed("b"), .added("c"), .added("d")])
        #expect(MateTextDiff.text(from: Data([0x66, 0x00, 0x67])) == nil)
    }

    @Test func documentAttachmentsAreCopiedNamedForTheModelAndShownAsChips() throws {
        let (base, folder, data) = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("budget.csv")
        try write("a,b\n1,2", source)
        let store = MateFileStore(folder: folder, dataRoot: data)
        let (documents, problems) = MateChatDocuments.attach([source, source], into: folder, store: store)
        #expect(problems.isEmpty)
        #expect(documents.map(\.name) == ["budget.csv", "budget 2.csv"])
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(MateFileOrigins.origin(of: "inbox/budget 2.csv", in: store.origins()) == .person)

        let text = MateChatDocuments.messageText("Sum these", documents: documents)
        #expect(text.contains(documents[0].path))
        let shown = MateChatDocuments.display(text)
        #expect(shown.body == "Sum these" && shown.names == ["budget.csv", "budget 2.csv"])
        #expect(MateChatDocuments.display("plain message").names.isEmpty)

        #expect(MateChatDocuments.problem(with: source, size: MateChatDocuments.maximumBytes + 1)?.contains("up to") == true)
        let split = MateChatDocuments.classify([source, folder, base.appendingPathComponent("photo.png")])
        #expect(split.documents == [source] && split.other == [folder] && split.images.count == 1)
    }
}
