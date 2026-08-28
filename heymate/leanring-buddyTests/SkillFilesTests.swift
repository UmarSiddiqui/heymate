//
//  SkillFilesTests.swift
//  leanring-buddyTests
//
//  Unit tests for Markdown skill-file parsing (FR-13 clean-room format)
//  and transcript-based skill retrieval: fence structure validation,
//  frontmatter extraction, CRLF tolerance, directory loading, and the
//  word-overlap relevance ranking.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct SkillFilesTests {

    // MARK: - Fixtures

    private static let validSkillMarkdown = """
    ---
    name: reply-to-client
    trigger: writing an email reply to a client
    tools:
      - gmail.read
      - gmail.createDraft
    ---

    # Instructions
    - Match my concise tone.
    - Never send automatically.
    """

    private static let expectedValidSkill = SkillFile(
        name: "reply-to-client",
        trigger: "writing an email reply to a client",
        tools: ["gmail.read", "gmail.createDraft"],
        instructions: "# Instructions\n- Match my concise tone.\n- Never send automatically."
    )

    /// Creates a fresh empty temp directory per test so file-based tests
    /// never observe each other's fixtures.
    private static func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private static func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Valid document parses fully

    @Test func validDocumentParsesFully() {
        let parsed = SkillMarkdownParser.parse(Self.validSkillMarkdown)

        #expect(parsed == Self.expectedValidSkill)
        #expect(parsed?.name == "reply-to-client")
        #expect(parsed?.trigger == "writing an email reply to a client")
        #expect(parsed?.tools == ["gmail.read", "gmail.createDraft"])
        #expect(parsed?.instructions == "# Instructions\n- Match my concise tone.\n- Never send automatically.")
    }

    @Test func claudeCodeDescriptionActsAsTrigger() {
        let markdown = """
        ---
        name: local-reviewer
        description: Review local Swift changes for correctness
        ---

        Check behavior before style.
        """

        let parsed = SkillMarkdownParser.parse(markdown)

        #expect(parsed?.name == "local-reviewer")
        #expect(parsed?.trigger == "Review local Swift changes for correctness")
        #expect(parsed?.instructions == "Check behavior before style.")
    }

    @Test func triggerTakesPrecedenceOverClaudeCodeDescription() {
        let markdown = """
        ---
        name: dual-format
        trigger: use this HeyMate trigger
        description: ignore this Claude Code description
        ---

        Instructions
        """

        #expect(SkillMarkdownParser.parse(markdown)?.trigger == "use this HeyMate trigger")
    }

    @Test func toolListItemOrderIsPreserved() {
        let markdown = """
        ---
        name: order-check
        trigger: checking list ordering
        tools:
          - zeta.tool
          - alpha.tool
          - middle.tool
        ---
        Body.
        """

        #expect(SkillMarkdownParser.parse(markdown)?.tools == ["zeta.tool", "alpha.tool", "middle.tool"])
    }

    @Test func quotedScalarValuesAreUnquotedAndEmptyToolsListAllowed() {
        let markdown = """
        ---
        name: "summarize-doc"
        trigger: "reading a long pdf"
        tools:
        ---
        Summarize the document.
        """

        let parsed = SkillMarkdownParser.parse(markdown)

        #expect(parsed?.name == "summarize-doc")
        #expect(parsed?.trigger == "reading a long pdf")
        #expect(parsed?.tools.isEmpty == true)
    }

    // MARK: - Malformed documents return nil

    @Test func documentWithoutFencesReturnsNil() {
        #expect(SkillMarkdownParser.parse("# Instructions\n- Just a body, no frontmatter fences.") == nil)
        #expect(SkillMarkdownParser.parse("") == nil)
    }

    @Test func unclosedFrontmatterFenceReturnsNil() {
        let markdown = """
        ---
        name: never-closed
        trigger: this fence is never closed
        tools:
          - some.tool
        """

        #expect(SkillMarkdownParser.parse(markdown) == nil)
    }

    @Test func missingNameReturnsNil() {
        let markdown = """
        ---
        trigger: has a trigger but no name
        tools:
          - gmail.read
        ---
        Body.
        """

        #expect(SkillMarkdownParser.parse(markdown) == nil)
    }

    @Test func missingTriggerReturnsNil() {
        let markdown = """
        ---
        name: no-trigger-here
        tools:
          - gmail.read
        ---
        Body.
        """

        #expect(SkillMarkdownParser.parse(markdown) == nil)
    }

    // MARK: - Tolerance

    @Test func crlfLineEndingsAreTolerated() {
        let crlfMarkdown = Self.validSkillMarkdown.replacingOccurrences(of: "\n", with: "\r\n")

        #expect(SkillMarkdownParser.parse(crlfMarkdown) == Self.expectedValidSkill)
    }

    @Test func unknownFrontmatterKeysAreIgnored() {
        let markdown = """
        ---
        model: claude-opus
        name: reply-to-client
        priority: high
        trigger: writing an email reply to a client
        tools:
          - gmail.read
          - gmail.createDraft
        ---
        Body.
        """

        let parsed = SkillMarkdownParser.parse(markdown)

        #expect(parsed?.name == "reply-to-client")
        #expect(parsed?.trigger == "writing an email reply to a client")
        #expect(parsed?.tools == ["gmail.read", "gmail.createDraft"])
    }

    // MARK: - loadAll

    @Test func loadAllReturnsFilesSortedByFilenameAndSkipsNonMarkdown() throws {
        let directoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try Self.write(
            Self.validSkillMarkdown.replacingOccurrences(of: "reply-to-client", with: "b-skill"),
            to: directoryURL.appendingPathComponent("b-second.md")
        )
        try Self.write(
            Self.validSkillMarkdown.replacingOccurrences(of: "reply-to-client", with: "a-skill"),
            to: directoryURL.appendingPathComponent("a-first.md")
        )
        // A .txt file must be skipped even when it contains valid skill text.
        try Self.write(
            Self.validSkillMarkdown.replacingOccurrences(of: "reply-to-client", with: "txt-skill"),
            to: directoryURL.appendingPathComponent("c-notes.txt")
        )
        // A .md file inside a subdirectory must NOT load (non-recursive).
        let nestedDirectoryURL = directoryURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectoryURL, withIntermediateDirectories: true)
        try Self.write(
            Self.validSkillMarkdown.replacingOccurrences(of: "reply-to-client", with: "nested-skill"),
            to: nestedDirectoryURL.appendingPathComponent("z-nested.md")
        )

        let loadedSkills = SkillMarkdownParser.loadAll(fromDirectory: directoryURL)

        #expect(loadedSkills.map(\.name) == ["a-skill", "b-skill"])
    }

    @Test func loadAllWithMissingDirectoryReturnsEmptyArray() {
        let missingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillFilesTests-missing-\(UUID().uuidString)", isDirectory: true)

        #expect(SkillMarkdownParser.loadAll(fromDirectory: missingDirectoryURL).isEmpty)
    }

    // MARK: - Bundled default seeding

    private static let sampleDefault = (
        fileName: "z-default.md",
        markdown: """
        ---
        name: z-default
        trigger: testing the seeder
        tools:
        ---
        Seeded body.
        """
    )

    @Test func seedingWritesMissingDefaultsAndReportsThem() throws {
        let directoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let writtenFileNames = SkillMarkdownParser.seedDefaultsIfNeeded(
            intoDirectory: directoryURL,
            defaults: [Self.sampleDefault]
        )

        #expect(writtenFileNames == ["z-default.md"])
        let seededContent = try String(
            contentsOf: directoryURL.appendingPathComponent("z-default.md"),
            encoding: .utf8
        )
        #expect(seededContent == Self.sampleDefault.markdown)
    }

    @Test func seedingNeverOverwritesExistingFiles() throws {
        let directoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let userEditedContent = "---\nname: z-default\ntrigger: user rewrote me\ntools:\n---\nMine now."
        try Self.write(userEditedContent, to: directoryURL.appendingPathComponent("z-default.md"))

        let writtenFileNames = SkillMarkdownParser.seedDefaultsIfNeeded(
            intoDirectory: directoryURL,
            defaults: [Self.sampleDefault]
        )

        #expect(writtenFileNames.isEmpty)
        let onDiskContent = try String(
            contentsOf: directoryURL.appendingPathComponent("z-default.md"),
            encoding: .utf8
        )
        #expect(onDiskContent == userEditedContent)
    }

    /// The shipped catalog must stay parseable by the real parser — a typo
    /// in a bundled default would otherwise silently vanish at seed time.
    @Test func everyCatalogEntryParsesIntoASkill() {
        for defaultSkill in DefaultSkillCatalog.skills {
            let parsed = SkillMarkdownParser.parse(defaultSkill.markdown)
            #expect(parsed != nil, "catalog entry \(defaultSkill.fileName) failed to parse")
            #expect(parsed?.name.isEmpty == false)
            #expect(parsed?.trigger.isEmpty == false)
            #expect(defaultSkill.fileName.hasSuffix(".md"))
        }
        #expect(DefaultSkillCatalog.skills.count >= 3)
    }

    @Test func catalogFileNamesAreUnique() {
        let fileNames = DefaultSkillCatalog.skills.map(\.fileName)
        #expect(Set(fileNames).count == fileNames.count)
    }

    // MARK: - Retrieval ranking

    @Test func obviousMatchRanksAboveUnrelatedSkill() {
        let emailSkill = SkillFile(
            name: "reply-to-client",
            trigger: "writing an email reply to a client",
            tools: [],
            instructions: ""
        )
        let bluetoothSkill = SkillFile(
            name: "fix-bluetooth",
            trigger: "configuring bluetooth devices",
            tools: [],
            instructions: ""
        )
        let transcript = "I have been writing an email reply to a client all morning"

        let relevantSkills = SkillRetrieval.relevant(
            skills: [bluetoothSkill, emailSkill],
            transcript: transcript
        )

        #expect(relevantSkills == [emailSkill])
    }

    @Test func zeroOverlapTranscriptReturnsEmptyArray() {
        let emailSkill = SkillFile(
            name: "reply-to-client",
            trigger: "writing an email reply to a client",
            tools: [],
            instructions: ""
        )
        let transcript = "totally unrelated words about gardening tomatoes"

        #expect(SkillRetrieval.relevant(skills: [emailSkill], transcript: transcript).isEmpty)
    }

    @Test func limitIsRespectedWithHighestScoresFirst() {
        let fourWordMatch = SkillFile(name: "four", trigger: "email client reply writing", tools: [], instructions: "")
        let twoWordMatch = SkillFile(name: "two", trigger: "email reply", tools: [], instructions: "")
        let oneWordMatch = SkillFile(name: "one", trigger: "email", tools: [], instructions: "")
        let transcript = "email client reply writing"

        let topTwoSkills = SkillRetrieval.relevant(
            skills: [oneWordMatch, fourWordMatch, twoWordMatch],
            transcript: transcript,
            limit: 2
        )

        #expect(topTwoSkills.count == 2)
        #expect(topTwoSkills == [fourWordMatch, twoWordMatch])
    }

    @Test func tiedScoresPreserveOriginalOrder() {
        let firstSkill = SkillFile(name: "first", trigger: "alpha beta", tools: [], instructions: "")
        let secondSkill = SkillFile(name: "second", trigger: "gamma delta", tools: [], instructions: "")
        let transcript = "alpha beta gamma delta"

        let forwardOrderResult = SkillRetrieval.relevant(skills: [firstSkill, secondSkill], transcript: transcript)
        let reverseOrderResult = SkillRetrieval.relevant(skills: [secondSkill, firstSkill], transcript: transcript)

        #expect(forwardOrderResult == [firstSkill, secondSkill])
        #expect(reverseOrderResult == [secondSkill, firstSkill])
    }
}
