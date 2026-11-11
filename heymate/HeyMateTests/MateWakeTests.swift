import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MateWakeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func mate(_ name: String, archived: Bool = false) -> Mate {
        Mate(
            id: UUID(), name: name, job: "Job", pinned: false, archived: archived,
            unreadCount: 0, createdAt: now, updatedAt: now, memoryNote: ""
        )
    }

    private func signal(_ kind: MateWakeKind, _ subject: String, occurrence: String = "", after seconds: TimeInterval = 0) -> MateWakeSignal {
        MateWakeSignal(kind: kind, subject: subject, occurrence: occurrence, observedAt: now.addingTimeInterval(seconds))
    }

    @Test func onlyALoneWebAddressCountsAsACopiedLink() {
        #expect(MateWakeMatcher.link(in: " https://example.com/a?b=1 \n")?.host == "example.com")
        #expect(MateWakeMatcher.link(in: "see https://example.com") == nil)
        #expect(MateWakeMatcher.link(in: "my password is hunter2") == nil)
        #expect(MateWakeMatcher.link(in: "file:///Users/me/secret.txt") == nil)
        #expect(MateWakeMatcher.link(in: "https://localhost") == nil)
        #expect(MateWakeMatcher.link(in: "https://example.com/" + String(repeating: "a", count: 2_100)) == nil)
    }

    @Test func aFilterNarrowsEachKindItsOwnWay() {
        let clerk = mate("Clerk")
        let pdfs = MateWake.make(mateID: clerk.id, kind: .downloadedFile, match: ".PDF, png", task: "")
        #expect(pdfs.match == "pdf, png")
        #expect(MateWakeMatcher.matches(pdfs, signal: signal(.downloadedFile, "Invoice.PDF")))
        #expect(!MateWakeMatcher.matches(pdfs, signal: signal(.downloadedFile, "notes.txt")))
        #expect(!MateWakeMatcher.matches(pdfs, signal: signal(.copiedLink, "https://a.com/x.pdf")))

        let github = MateWake.make(mateID: clerk.id, kind: .copiedLink, match: "github.com", task: "")
        #expect(MateWakeMatcher.matches(github, signal: signal(.copiedLink, "https://gist.github.com/a/b")))
        #expect(!MateWakeMatcher.matches(github, signal: signal(.copiedLink, "https://example.com/github.com")))

        let figma = MateWake.make(mateID: clerk.id, kind: .appOpened, match: "Figma", task: "")
        #expect(MateWakeMatcher.matches(figma, signal: signal(.appOpened, "Figma")))
        #expect(!MateWakeMatcher.matches(figma, signal: signal(.appOpened, "FigJam")))
        let anyApp = MateWake.make(mateID: clerk.id, kind: .appOpened, match: "", task: "")
        #expect(!MateWakeMatcher.matches(anyApp, signal: signal(.appOpened, "Figma")))

        let standup = MateWake.make(mateID: clerk.id, kind: .meetingSoon, match: "standup", task: "")
        #expect(MateWakeMatcher.matches(standup, signal: signal(.meetingSoon, "Daily Standup")))
    }

    @Test func theNarrowerWakeWinsAndArchivedAgentsStayQuiet() {
        let scout = mate("Scout")
        let dev = mate("Dev")
        let gone = mate("Gone", archived: true)
        let wakes = [
            MateWake.make(mateID: gone.id, kind: .copiedLink, match: "github.com", task: ""),
            MateWake.make(mateID: scout.id, kind: .copiedLink, match: "", task: "Summarise it."),
            MateWake.make(mateID: dev.id, kind: .copiedLink, match: "github.com", task: "Review it.")
        ]
        let pull = MateWakeMatcher.offer(
            for: signal(.copiedLink, "https://github.com/a/b/pull/1"), wakes: wakes, mates: [scout, dev, gone]
        )
        #expect(pull?.mateName == "Dev")
        #expect(pull?.prompt == "Review it.\nLink: https://github.com/a/b/pull/1")
        #expect(pull?.question == "Look into the link from github.com?")
        let article = MateWakeMatcher.offer(
            for: signal(.copiedLink, "https://www.example.com/post"), wakes: wakes, mates: [scout, dev, gone]
        )
        #expect(article?.mateName == "Scout")
        #expect(article?.question == "Look into the link from example.com?")
    }

    @Test func theSameThingIsOfferedOnceAndCooldownsHold() {
        let scout = mate("Scout")
        var wake = MateWake.make(mateID: scout.id, kind: .copiedLink, match: "", task: "")
        let first = signal(.copiedLink, "https://example.com/a")
        #expect(MateWakeMatcher.offer(for: first, wakes: [wake], mates: [scout]) != nil)
        wake = MateWakeMatcher.recordOffer(wake, signal: first)
        // Same link again, even much later.
        #expect(MateWakeMatcher.offer(
            for: signal(.copiedLink, "https://example.com/a", after: 3_600), wakes: [wake], mates: [scout]
        ) == nil)
        // A different link inside the two-minute cooldown.
        #expect(MateWakeMatcher.offer(
            for: signal(.copiedLink, "https://example.com/b", after: 30), wakes: [wake], mates: [scout]
        ) == nil)
        #expect(MateWakeMatcher.offer(
            for: signal(.copiedLink, "https://example.com/b", after: 180), wakes: [wake], mates: [scout]
        ) != nil)
    }

    @Test func aRepeatingMeetingIsOfferedForEachStart() {
        let brief = mate("Brief")
        var wake = MateWake.make(mateID: brief.id, kind: .meetingSoon, match: "", task: "")
        let monday = signal(.meetingSoon, "Standup", occurrence: "100")
        wake = MateWakeMatcher.recordOffer(wake, signal: monday)
        #expect(MateWakeMatcher.offer(for: signal(.meetingSoon, "Standup", occurrence: "100", after: 60), wakes: [wake], mates: [brief]) == nil)
        #expect(MateWakeMatcher.offer(for: signal(.meetingSoon, "Standup", occurrence: "200", after: 60), wakes: [wake], mates: [brief]) != nil)
    }

    @Test func oneOpenOfferPerWakeAndOldOffersExpire() {
        let clerk = mate("Clerk")
        let wake = MateWake.make(mateID: clerk.id, kind: .downloadedFile, match: "", task: "File it.")
        var file = signal(.downloadedFile, "a.pdf")
        file.fileURL = URL(fileURLWithPath: "/tmp/a.pdf")
        let first = MateWakeMatcher.offer(for: file, wakes: [wake], mates: [clerk])
        #expect(first?.fileURL?.lastPathComponent == "a.pdf")
        #expect(first?.prompt == "File it.")
        #expect(first?.question == "Take a.pdf?")
        let pending = [first].compactMap { $0 }
        #expect(MateWakeMatcher.offer(for: signal(.downloadedFile, "b.pdf", after: 5), wakes: [wake], mates: [clerk], pending: pending) == nil)
        #expect(MateWakeMatcher.current(pending, now: now.addingTimeInterval(60)).count == 1)
        #expect(MateWakeMatcher.current(pending, now: now.addingTimeInterval(31 * 60)).isEmpty)
    }

    @Test func anEmptyTaskFallsBackToAPlainOne() {
        let wake = MateWake.make(mateID: UUID(), kind: .newMail, match: "", task: "  ")
        #expect(MateWakeMatcher.prompt(for: wake, signal: signal(.newMail, "Ada: Invoice 42"))
            == "Look at this new mail and draft a reply if it needs one.\nNew mail: Ada: Invoice 42")
    }

    @Test func downloadsReportOnlyFinishedNewFiles() {
        #expect(MateWakeDownloads.newlyFinished(previous: nil, current: ["old.pdf"]).isEmpty)
        let before: Set<String> = ["old.pdf", "big.zip.crdownload"]
        let after: Set<String> = ["old.pdf", "big.zip", "movie.mp4.download", ".DS_Store", "page.part", "new.png"]
        #expect(MateWakeDownloads.newlyFinished(previous: before, current: after) == ["big.zip", "new.png"])
    }

    @Test func mailReportsOnlyUnreadLinesNotSeenBefore() {
        let raw = "\"Monday 9:00\\tAda Lovelace <ada@example.com>\\tInvoice 42\\tunread\\nMonday 8:00\\tBob <b@example.com>\\tHello\\tread\\nbroken line\\n\""
        let rows = MateWakeMail.rows(rawOutput: raw)
        #expect(rows.count == 2)
        #expect(rows[0].summary == "Ada Lovelace: Invoice 42")
        #expect(MateWakeMail.newUnread(previousKeys: nil, rows: rows).isEmpty)
        #expect(MateWakeMail.newUnread(previousKeys: [], rows: rows).map(\.subject) == ["Invoice 42"])
        #expect(MateWakeMail.newUnread(previousKeys: [rows[0].key], rows: rows).isEmpty)
    }

    @Test func theStoreSkipsWakesItCannotReadAndKeepsTheRest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-wakes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("agent-wakes.json")
        let mateID = UUID()
        let store = FileMateWakeStore(fileURL: url)
        store.upsert(MateWake.make(mateID: mateID, kind: .copiedLink, match: "github.com", task: "Review it."))
        var json = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
        json = json.replacingOccurrences(
            of: "[", with: "[{\"id\":\"\(UUID().uuidString)\",\"kind\":\"somethingNewer\",\"mateID\":\"\(mateID.uuidString)\"},",
            options: [], range: json.range(of: "[")
        )
        try Data(json.utf8).write(to: url)
        let reopened = FileMateWakeStore(fileURL: url).loadAll()
        #expect(reopened.map(\.kind) == [.copiedLink])
        #expect(reopened.first?.task == "Review it.")
        store.deleteAll(mateID: mateID)
        #expect(FileMateWakeStore(fileURL: url).loadAll().isEmpty)
    }
}
