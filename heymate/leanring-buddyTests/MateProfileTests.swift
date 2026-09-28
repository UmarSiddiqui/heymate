//
//  MateProfileTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct MateProfileTests {

    @Test func chosenFaceWinsAndAnUnknownFaceFallsBack() {
        var hey = sample(name: Mate.defaultName)
        #expect(MateFace.assetName(for: hey) == "MateFaceLilac")
        hey.faceAssetName = "MateFaceAmber"
        #expect(MateFace.assetName(for: hey) == "MateFaceAmber")
        hey.faceAssetName = "not-a-face"
        #expect(MateFace.assetName(for: hey) == "MateFaceLilac")
    }

    @Test func saveKeepsMemoryAndFolderAndRejectsATakenName() {
        var mate = sample(name: "Inbox Scout")
        mate.memoryNote = "prefers short notes"
        mate.folderPath = "/tmp/inbox"
        let now = Date(timeIntervalSince1970: 50)
        let saved = MateProfileEdit.applying(
            MateProfileEdit.Draft(
                name: " Mail Scout ",
                job: " Watch mail ",
                soul: " warm and brief ",
                faceAssetName: "MateFaceStar"
            ),
            to: mate,
            now: now,
            nameTaken: { _ in false }
        )
        guard case .success(let updated) = saved else {
            Issue.record("expected a saved mate")
            return
        }
        #expect(updated.name == "Mail Scout")
        #expect(updated.job == "Watch mail")
        #expect(updated.soul == "warm and brief")
        #expect(updated.faceAssetName == "MateFaceStar")
        #expect(updated.memoryNote == "prefers short notes")
        #expect(updated.folderPath == "/tmp/inbox")
        #expect(updated.updatedAt == now)

        let taken = MateProfileEdit.applying(
            MateProfileEdit.Draft(name: "Mail Scout", job: "Watch mail", soul: "", faceAssetName: nil),
            to: mate,
            now: now,
            nameTaken: { _ in true }
        )
        #expect(taken == .failure(.nameTaken))
        let blank = MateProfileEdit.applying(
            MateProfileEdit.Draft(name: " ", job: "Watch mail", soul: "", faceAssetName: nil),
            to: mate,
            now: now,
            nameTaken: { _ in false }
        )
        #expect(blank == .failure(.missingNameOrJob))
    }

    @Test func anUnchangedSaveDoesNotBumpTheTimestamp() {
        let mate = sample(name: "Inbox Scout")
        let saved = MateProfileEdit.applying(
            MateProfileEdit.Draft(
                name: mate.name,
                job: mate.job,
                soul: "",
                faceAssetName: nil
            ),
            to: mate,
            now: Date(timeIntervalSince1970: 90),
            nameTaken: { _ in false }
        )
        guard case .success(let updated) = saved else {
            Issue.record("expected a saved mate")
            return
        }
        #expect(updated.updatedAt == mate.updatedAt)
    }

    @Test func aCustomPictureIsKeptOnlyWhenTheFileIsReal() {
        #expect(MateFaceStore.fileName(in: "custom:abc.png") == "abc.png")
        #expect(MateFaceStore.fileName(in: "custom:../abc.png").isEmpty)
        #expect(MateFaceStore.fileName(in: "MateFaceLilac").isEmpty)
        #expect(
            MateFace.persistedName("custom:abc.png", customFileExists: { $0 == "custom:abc.png" })
                == "custom:abc.png"
        )
        #expect(MateFace.persistedName("custom:missing.png", customFileExists: { _ in false }) == nil)
        #expect(MateFace.persistedName("MateFaceRobot", customFileExists: { _ in false }) == "MateFaceRobot")
    }

    @Test func soulEntersThePromptOnlyWhenItIsWritten() {
        #expect(MateSoul.promptBlock(name: "HeyMate", job: "General chat", soul: "  ") == nil)
        let block = MateSoul.promptBlock(name: "Inbox Scout", job: "Watch the inbox", soul: "calm")
        #expect(block?.contains("Inbox Scout") == true)
        #expect(block?.contains("calm") == true)
    }

    @Test func matesSavedBeforeSoulStillDecode() throws {
        let mate = sample(name: "HeyMate")
        let data = try JSONEncoder().encode(mate)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "soul")
        object.removeValue(forKey: "faceAssetName")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Mate.self, from: stripped)
        #expect(decoded.soul == "")
        #expect(decoded.faceAssetName == nil)
        #expect(decoded.name == "HeyMate")
        #expect(decoded.memoryNote == mate.memoryNote)
    }

    private func sample(name: String) -> Mate {
        Mate(
            id: UUID(),
            name: name,
            job: "A job",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            memoryNote: "",
            folderPath: nil
        )
    }
}
