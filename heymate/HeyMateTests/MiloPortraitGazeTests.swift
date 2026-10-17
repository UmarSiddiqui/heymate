import AppKit
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MiloPortraitGazeTests {
    @Test func everySavedLookHasMatchingPortraitCameraLayers() throws {
        var bases = Set<String>()
        var eyes = Set<String>()
        for look in MiloLook.allLooks {
            let base = try #require(NSImage(named: look.portraitGazeBaseAssetName))
            let eye = try #require(NSImage(named: look.portraitGazeEyesAssetName))
            #expect(base.size == NSSize(width: 550, height: 600))
            #expect(eye.size == base.size)
            bases.insert(look.portraitGazeBaseAssetName)
            eyes.insert(look.portraitGazeEyesAssetName)
            // Accessories do not change the camera or erase the chosen colors.
            let hatted = look.wearing(hat: .orbitCap)
            #expect(hatted.portraitGazeBaseAssetName == look.portraitGazeBaseAssetName)
            #expect(hatted.portraitGazeEyesAssetName == look.portraitGazeEyesAssetName)
            #expect(hatted.supportsPortraitGaze)
            #expect(!look.wearing(eyewear: .sunglasses).supportsPortraitGaze)
        }
        #expect(bases.count == 36)
        #expect(eyes.count == 6)
    }

    @Test func portraitMaskMatchesItsCameraAndStaysInsideTheFace() {
        let portrait = MiloGazeEyeGeometry.portrait
        let peek = MiloGazeEyeGeometry.standard
        #expect(portrait.leftCenter.x < portrait.rightCenter.x)
        #expect(portrait.eyeSize.width == peek.eyeSize.width)
        #expect(abs(portrait.eyeSize.height * 600 - peek.eyeSize.height * 490) < 0.001)
        for center in [portrait.leftCenter, portrait.rightCenter] {
            #expect(center.x - portrait.eyeSize.width / 2 > 0)
            #expect(center.x + portrait.eyeSize.width / 2 < 1)
            #expect(center.y - portrait.eyeSize.height / 2 > 0)
            #expect(center.y + portrait.eyeSize.height / 2 < 1)
        }
    }
}
