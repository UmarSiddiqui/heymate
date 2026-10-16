import Foundation
import AppKit
import Testing
@testable import HeyMate

@MainActor
struct MiloCharacterTests {
    @Test func everyAppearanceAndCompanionPoseHasBundledArtwork() {
        for look in MiloLook.allLooks {
            #expect(NSImage(named: NSImage.Name(look.headAssetName)) != nil)
            #expect(NSImage(named: NSImage.Name(look.bodyAssetName)) != nil)
            #expect(NSImage(named: NSImage.Name(look.perchedAssetName)) != nil)
        }
        for prefix in ["Milo", "MiloFuture", "Nova", "NovaFuture"] {
            for pose in ["Idle", "Wave", "Think", "Blink", "Celebrate", "Peek", "PeekBlink", "PeekThink", "PeekWave", "PeekCelebrate"] {
                #expect(NSImage(named: NSImage.Name(prefix + pose)) != nil)
            }
        }
    }
    @Test func bothCharacterPacksHaveDistinctValidatedCatalogTokens() {
        #expect(MiloLook.allLooks.count == 216)
        #expect(Set(MiloLook.allLooks.map(\.assetName)).count == 216)
        #expect(MiloLook.standard.assetName == "Milo-sweep-tide-caramel-sea")
        for look in MiloLook.allLooks {
            #expect(MiloLook(assetName: look.assetName) == look)
            #expect(MateFace.storedAssetName(look.assetName) == look.assetName)
            #expect(MateFace.persistedName(look.assetName, customFileExists: { _ in false }) == look.assetName)
            #expect(MateFace.pack(containing: look.assetName)?.id == look.characterPack.rawValue.lowercased())
        }
    }

    @Test func classicTokensStayCompatibleAndFutureOutfitRoundTrips() throws {
        let classic = try #require(MiloLook(assetName: "Milo-sweep-tide-caramel-sea"))
        #expect(classic.outfit == .classic)
        #expect(classic.bodyAssetName == "MiloBody-sweep-tide-caramel-sea-classic")
        let future = try #require(MiloLook(assetName: "Milo-sweep-tide-caramel-sea-future"))
        #expect(future.outfit == .future)
        #expect(future.headAssetName == classic.headAssetName)
        #expect(future.bodyAssetName == "MiloBody-sweep-tide-caramel-sea-future")
        #expect(future.companionAsset(for: .idle) == "MiloFuturePeek")
        #expect(future.companionAsset(for: .thinking) == "MiloFuturePeekThink")
        #expect(MiloLook(assetName: "Milo-sweep-tide-caramel-sea-classic") == nil)
        #expect(MiloLook(assetName: "Milo-sweep-tide-caramel-sea-armor") == nil)
        #expect(MiloLook(assetName: "Milo-sweep-tide-caramel-sea-future-extra") == nil)
    }

    @Test func malformedOrUnknownLookTokensAreRejected() {
        for token in ["Milo", "milo-sweep-tide-caramel-sea", "Milo-sweep-tide-caramel", "Milo-sweep-tide-caramel-sea-extra",
                      "Milo-curl-tide-caramel-sea", "Milo-sweep-black-caramel-sea", "Milo-sweep-tide-pale-sea",
                      "Milo-sweep-tide-caramel-blue", "Milo--tide-caramel-sea", "Milo-sweep-tide-caramel-sea "] {
            #expect(MiloLook(assetName: token) == nil)
            #expect(MateFace.storedAssetName(token) == nil)
            #expect(MateFace.persistedName(token, customFileExists: { _ in false }) == nil)
        }
    }

    @Test func selectedLookSurvivesProfileSaveAndMateSerialization() throws {
        let mate = sample()
        for look in MiloLook.allLooks {
            let result = MateProfileEdit.applying(
                MateProfileEdit.Draft(name: mate.name, job: mate.job, soul: "calm", faceAssetName: look.assetName),
                to: mate, now: Date(timeIntervalSince1970: 50), nameTaken: { _ in false }
            )
            guard case .success(let saved) = result else { Issue.record("Character profile did not save"); return }
            let reloaded = try JSONDecoder().decode(Mate.self, from: JSONEncoder().encode(saved))
            #expect(reloaded.faceAssetName == look.assetName)
            #expect(MateFace.selectionToken(for: reloaded) == look.assetName)
            #expect(reloaded.memoryNote == mate.memoryNote)
            #expect(reloaded.folderPath == mate.folderPath)
        }
    }

    @Test func retiredBuiltInsMigrateWhilePhotosStaySelected() {
        var mate = sample()
        #expect(MateFace.selectionToken(for: mate) == MiloLook.defaultLook.assetName)
        for legacy in MateFace.retiredAssetNames {
            mate.faceAssetName = legacy
            #expect(MateFace.selectionToken(for: mate) == MiloLook.defaultLook.assetName)
        }
        #expect(MateFace.persistedName("custom:portrait.png", customFileExists: { _ in true }) == "custom:portrait.png")
        mate.name = "Scout"
        mate.faceAssetName = nil
        #expect(MateFace.selectionToken(for: mate) == MiloLook.defaultLook.assetName)
    }

    @Test func customMaterialsNeverRevertWhenCompanionStateChanges() {
        let custom = MiloLook(hairstyle: .crop, hair: .lilac, skin: .umber, eye: .amber, outfit: .future)
        let states: [MateFaceExpression] = [.still, .idle, .listening, .thinking, .speaking, .success, .failure, .attention, .guiding, .reading, .writing, .tooling, .browsing]
        for state in states { #expect(custom.companionAsset(for: state) == custom.perchedAssetName) }
        #expect(MiloLook.standard.companionAsset(for: .idle) == "MiloPeek")
        #expect(MiloLook.standard.companionAsset(for: .thinking) == "MiloPeekThink")
        #expect(MiloLook.standard.companionAsset(for: .success) == "MiloPeekCelebrate")
    }

    @Test func newDefaultUsesFutureWithoutChangingSavedClassicTokens() throws {
        #expect(MiloLook.defaultLook.outfit == .future)
        #expect(MiloLook.defaultLook.assetName == "Milo-sweep-tide-caramel-sea-future")
        var mate = sample()
        #expect(MateFace.selectionToken(for: mate) == MiloLook.defaultLook.assetName)
        mate.faceAssetName = MiloLook.standard.assetName
        #expect(MateFace.selectionToken(for: mate) == "Milo-sweep-tide-caramel-sea")
        #expect(try #require(MiloLook(assetName: MateFace.selectionToken(for: mate))).outfit == .classic)
    }

    @Test func originalMotionStaysBoundedAndRejectsInvalidSamples() {
        let states: [MateFaceExpression] = [.still, .idle, .thinking, .listening, .speaking, .success, .failure, .attention, .guiding, .reading, .writing, .tooling, .browsing]
        for state in states {
            #expect(MiloMotionPose.sample(expression: state, elapsed: .nan) == MiloMotionPose())
            for step in 0...240 {
                let pose = MiloMotionPose.sample(expression: state, elapsed: Double(step) / 24, gaze: CGSize(width: 10, height: -10))
                #expect(abs(pose.rotation) <= 6)
                #expect(abs(pose.x) <= 0.014)
                #expect(abs(pose.y) <= 0.055)
                #expect((0.99...1.02).contains(pose.scale))
                if state == .still { #expect(pose == MiloMotionPose()) }
            }
        }
        #expect(!MiloMotionPose.isBlinking(elapsed: .nan))
        #expect(!MiloMotionPose.isBlinking(elapsed: 5.79))
        #expect(MiloMotionPose.isBlinking(elapsed: 5.85))
        #expect(!MiloMotionPose.isBlinking(elapsed: 5.95))
        #expect(MiloMotionPose.isBlinking(elapsed: 12.05))
    }

    private func sample() -> Mate {
        Mate(id: UUID(), name: Mate.defaultName, job: Mate.defaultJob, pinned: true, archived: false,
             unreadCount: 0, createdAt: .distantPast, updatedAt: .distantPast,
             memoryNote: "Keep short notes", folderPath: "/tmp/milo-test")
    }
}
