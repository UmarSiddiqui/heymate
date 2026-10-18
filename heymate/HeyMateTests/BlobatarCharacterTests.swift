import AppKit
import Foundation
import SwiftUI
import Testing
@testable import HeyMate

@MainActor
struct BlobatarCharacterTests {
    @Test func selectionSurvivesProfileSaveAndReload() throws {
        for face in BlobatarCharacter.faces {
            var mate = Mate(id: UUID(), name: "Blob", job: "Help", pinned: false, archived: false,
                            unreadCount: 0, createdAt: .distantPast, updatedAt: .distantPast, memoryNote: "")
            mate.faceAssetName = face.assetName
            let reloaded = try JSONDecoder().decode(Mate.self, from: JSONEncoder().encode(mate))
            #expect(MateFace.persistedName(reloaded.faceAssetName) == face.assetName)
            #expect(MateFace.assetName(for: reloaded) == face.assetName)
            #expect(MateFace.pack(containing: face.assetName)?.id == "blobatar")
            mate.name = "Renamed"
            #expect(MateFace.selectionToken(for: mate) == face.assetName)
        }
        #expect(MateFace.persistedName("BlobatarUnknown") == nil)
        #expect(MateFace.persistedName("BlobatarTide-happy") == nil)
    }

    @Test func everyLiveStateHasBundledArtwork() {
        let expressions: [MateFaceExpression] = [.still, .idle, .listening, .thinking, .speaking,
            .attention, .success, .failure, .guiding, .reading, .writing, .tooling, .browsing]
        for face in BlobatarCharacter.faces {
            for expression in expressions {
                let artwork = BlobatarCharacter.artwork(for: face.assetName, expression: expression)
                #expect(NSImage(named: artwork) != nil, "Missing artwork: \(artwork)")
            }
        }
        #expect(BlobatarCharacter.artwork(for: "BlobatarTide", expression: .success) == "BlobatarTide-happy")
        #expect(BlobatarCharacter.artwork(for: "BlobatarTide", expression: .failure) == "BlobatarTide-sad")
        #expect(BlobatarCharacter.artwork(for: "BlobatarTide", expression: .still) == "BlobatarTide")
    }

    @Test func generatedIdentityPersistsAndDoesNotDependOnBotName() throws {
        let id = UUID()
        let otherID = UUID()
        let automatic = BlobatarCharacter.configuration(token: BlobatarCharacter.automaticToken, mateID: id)
        #expect(automatic.seed == BlobatarCharacter.configuration(token: BlobatarCharacter.automaticToken, mateID: id).seed)
        #expect(automatic.seed != BlobatarCharacter.configuration(token: BlobatarCharacter.automaticToken, mateID: otherID).seed)
        for token in [BlobatarCharacter.automaticToken, BlobatarCharacter.randomToken()] {
            #expect(MateFace.persistedName(token) == token)
            #expect(MateFace.pack(containing: token)?.id == "blobatar")
            #expect(MateFace.label(for: token) == "Your Blobatar")
        }
        #expect(MateFace.persistedName("blobatar:invalid") == nil)
        #expect(MateFace.persistedName("blobatar:") == nil)
        let random = BlobatarCharacter.randomToken()
        #expect(BlobatarCharacter.configuration(token: random, mateID: id).seed
                == BlobatarCharacter.configuration(token: random, mateID: otherID).seed)
    }

    @Test func nativeRuntimeDrawsEveryUpstreamSilhouette() throws {
        let renderer = BlobatarNativeRenderer.shared
        #expect(renderer.isAvailable)
        // One input inside each of upstream's ten silhouette bands.
        for shape in [0.1, 0.32, 0.51, 0.65, 0.74, 0.82, 0.89, 0.93, 0.96, 0.99] {
            for index in 0..<8 {
                let figure = try #require(renderer.figure(seed: "geometry-\(index)", options: ["traits": ["shape": shape]]))
                #expect(!figure.body.isEmpty)
                #expect(figure.eyes.count == 2)
                #expect(figure.body.allSatisfy { !$0.isEmpty })
                #expect(figure.eyes.allSatisfy { !$0.isEmpty })
                #expect((figure.face["rx"] as? Double ?? 0) > 0)
                #expect((figure.face["ry"] as? Double ?? 0) > 0)
                let fitted = figure.body.reduce(CGRect.null) {
                    $0.union($1.applying(figure.fittingTransform(in: CGSize(width: 116, height: 116), restsOnSurface: true)).boundingRect)
                }
                #expect(abs(max(fitted.width, fitted.height) - 116 * 0.94) < 0.01)
                #expect(abs(fitted.maxY - 116 * 0.98) < 0.01)
                #expect(fitted.minX >= 0 && fitted.maxX <= 116)
                #expect(fitted.minY >= 0)
            }
        }
    }

    @Test func eyesTrackBothAxesAndDisabledMotionStopsEveryLayer() throws {
        let renderer = BlobatarNativeRenderer.shared
        let seed = "pointer-test"
        let figure = try #require(renderer.figure(seed: seed, options: [:]))
        func sample(_ id: String, _ time: Double, _ target: [String: Double]?, animate: Bool = true) throws -> BlobatarFrame {
            try #require(renderer.frame(id: id, seed: seed, options: [:], expression: "idle", now: time,
                                        animate: animate, target: target, figure: figure))
        }
        let left = ["dx": -200.0, "dy": -100.0, "radius": 50.0]
        let right = ["dx": 200.0, "dy": 100.0, "radius": 50.0]
        _ = try sample("left", 0, left)
        _ = try sample("right", 0, right)
        let a = try sample("left", 100, left)
        let b = try sample("right", 100, right)
        let center = CGPoint(x: figure.eyes[0].boundingRect.midX, y: figure.eyes[0].boundingRect.midY)
        #expect(center.applying(a.eyes[0]).x < center.applying(b.eyes[0]).x)
        #expect(center.applying(a.eyes[0]).y < center.applying(b.eyes[0]).y)
        #expect(a.body == b.body)
        let frozen = try sample("left", 1000, left, animate: false)
        let frozenLater = try sample("left", 9000, right, animate: false)
        #expect(frozen.body == frozenLater.body)
        #expect(frozen.eyes == frozenLater.eyes)
        let moving = try sample("idle", 0, nil)
        let movingLater = try sample("idle", 2400, nil)
        #expect(moving.body != movingLater.body)
        for id in ["left", "right", "idle"] { renderer.forget(id) }
    }

    @Test func expressionsMorphWithoutResettingGeometry() throws {
        let renderer = BlobatarNativeRenderer.shared
        let figure = try #require(renderer.figure(seed: "morph", options: [:]))
        func frame(_ expression: String, _ time: Double) throws -> BlobatarFrame {
            try #require(renderer.frame(id: "morph", seed: "morph", options: [:], expression: expression,
                                        now: time, animate: true, target: nil, figure: figure))
        }
        let idle = try frame("idle", 0)
        let start = try frame("happy", 0)
        #expect(idle.eyes == start.eyes)
        let happy = try frame("happy", 350)
        #expect(happy.eyes != idle.eyes)
        let interrupted = try frame("sad", 350)
        #expect(interrupted.eyes == happy.eyes)
        #expect(try frame("sad", 700).eyes != happy.eyes)
        renderer.forget("morph")
    }
}
