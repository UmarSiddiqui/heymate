//
//  MateProfileTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct MateProfileTests {

    @Test func chosenFaceWinsAndAnUnknownFaceFallsBack() {
        var hey = sample(name: Mate.defaultName)
        #expect(MateFace.assetName(for: hey) == MiloLook.defaultLook.assetName)
        hey.faceAssetName = MiloLook.defaultLook(for: .nova).assetName
        #expect(MateFace.assetName(for: hey) == MiloLook.defaultLook(for: .nova).assetName)
        hey.faceAssetName = "not-a-face"
        #expect(MateFace.assetName(for: hey) == MiloLook.defaultLook.assetName)
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
                faceAssetName: MiloLook.defaultLook(for: .nova).assetName
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
        #expect(updated.faceAssetName == MiloLook.defaultLook(for: .nova).assetName)
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

    @Test func customPicturesStaySavedWhenOfflineAndRejectUnsafePaths() {
        #expect(MateFaceStore.fileName(in: "custom:abc.png") == "abc.png")
        #expect(MateFaceStore.fileName(in: "custom:../abc.png").isEmpty)
        #expect(MateFaceStore.fileName(in: "MateFaceLilac").isEmpty)
        #expect(
            MateFace.persistedName("custom:abc.png", customFileExists: { $0 == "custom:abc.png" })
                == "custom:abc.png"
        )
        #expect(MateFace.persistedName("custom:missing.png", customFileExists: { _ in false }) == "custom:missing.png")
        #expect(MateFace.persistedName("custom:../abc.png", customFileExists: { _ in true }) == nil)
        #expect(MateFace.persistedName("MateFaceRobot", customFileExists: { _ in false }) == MiloLook.defaultLook.assetName)
    }

    @Test func nameAndJobStayPresentBeforeAPersonalityIsWritten() throws {
        let block = try #require(MateSoul.promptBlock(name: " Inbox Scout ", job: " Watch the inbox ", soul: "  "))
        let compact = try #require(MateSoul.identityExcerpt(in: block, characterLimit: 1_200))
        #expect(compact.contains("you are Inbox Scout. your job is Watch the inbox."))
        #expect(!compact.contains("- personality:"))
        #expect(block.contains("never the safety or capability rules"))
    }

    @Test func personalityEntersTheIdentityWhenItIsWritten() {
        let block = MateSoul.promptBlock(name: "Inbox Scout", job: "Watch the inbox", soul: "calm")
        #expect(block?.contains("Inbox Scout") == true)
        #expect(block?.contains("calm") == true)
    }

    @Test func savedMemoryBelongsToTheMateEvenWithoutAPersonality() throws {
        let block = try #require(MateSoul.promptBlock(
            name: "Photo Coach", job: "Teach editing", soul: "", memoryNote: " I use Photopea, not Photoshop. "
        ))
        #expect(block.contains("I use Photopea, not Photoshop."))
        let compact = try #require(MateSoul.identityExcerpt(in: block, characterLimit: 1_200))
        #expect(!compact.contains("- personality:"))
        #expect(compact.contains("I use Photopea"))
    }

    @Test func bothConversationStylesUseTheSelectedMateIdentity() {
        for silent in [false, true] {
            let prompt = CompanionPrompts.response(isSilentModeEnabled: silent)
            #expect(prompt.contains("use the mate identity supplied for this turn"))
            #expect(!prompt.lowercased().contains("you are heymate"))
        }
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
