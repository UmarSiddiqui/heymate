//
//  Model3DTests.swift
//  HeyMateTests
//
//  The {"model3d"} block a reply builds a 3D model from: lifted out of the
//  spoken words, validated into safe parts, and turned into a scene whose
//  parts can be clicked by name.
//

import Foundation
import SceneKit
import Testing
@testable import HeyMate

struct Model3DTests {

    private let engineReply = """
    a piston engine turns fuel into motion: the piston slides in the cylinder and the rod turns the crank.
    ```json
    {"model3d": {"title": "Piston engine", "parts": [
      {"name": "cylinder {block}", "shape": "cylinder", "size": [0.4, 1.2], "at": [0, 0.3, 0], "material": "glass", "color": "#9fb4c7", "about": "where the piston slides"},
      {"name": "piston", "shape": "cylinder", "size": [0.36, 0.3], "at": [0, 0.5, 0], "material": "steel", "motion": "bob"},
      {"name": "rod", "shape": "tube", "from": [0, 0.4, 0], "to": [0.2, -0.5, 0], "size": [0.05]},
      {"name": "crank", "shape": "torus", "size": [0.3, 0.06], "at": [0, -0.6, 0], "rotate": [90, 0, 0], "motion": "spin"}
    ]}}
    ```
    """

    @Test func modelBlockIsLiftedOutOfTheSpokenReply() throws {
        let reply = GuidedReplyParser.parse(engineReply)
        #expect(reply.spokenText == "a piston engine turns fuel into motion: the piston slides in the cylinder and the rod turns the crank.")
        let model = try #require(reply.model3D)
        #expect(model.title == "Piston engine")
        #expect(model.parts.map(\.name) == ["cylinder {block}", "piston", "rod", "crank"])
        #expect(model.parts[0].material == .glass)
        #expect(model.parts[0].colorHex == "#9FB4C7")
        #expect(model.parts[1].motion == .bob)
        #expect(model.parts[2].from == [0, 0.4, 0])
        #expect(model.parts[3].rotation == [90, 0, 0])
        #expect(model.spins)
    }

    @Test func aModelStillArrivingIsNeverShownInTheCaption() {
        let partial = "here is the engine.\n```json\n{\"model3d\": {\"title\": \"Pis"
        #expect(GuidedReplyParser.streamingDisplayText(partial) == "here is the engine.")
        #expect(GuidedReplyParser.streamingDisplayText(engineReply).contains("model3d") == false)
    }

    @Test func badPartsAreDroppedOrClampedAndAnEmptyModelIsIgnored() throws {
        let text = """
        {"model3d": {"parts": [
          {"name": "tower", "shape": "box", "size": [0.2], "at": [0, 99, 0], "color": "red"},
          {"shape": "pyramid", "size": [1]},
          {"name": "cable", "shape": "tube", "from": [0, 0, 0], "to": [0, 0, 0]}
        ]}}
        """
        let model = try #require(Model3DParser.extract(from: text).model)
        #expect(model.title == "Model")
        #expect(model.parts.count == 1)
        let tower = model.parts[0]
        #expect(tower.size == [0.3, 0.3, 0.3])
        #expect(tower.position == [0, Model3DSpec.maximumExtent, 0])
        #expect(tower.colorHex == "#B8BCC4")
        #expect(tower.material == .matte)

        let empty = Model3DParser.extract(from: #"see {"model3d": {"parts": [{"shape": "pyramid"}]}}"#)
        #expect(empty.model == nil)
        #expect(empty.text.contains("model3d"))
    }

    @MainActor
    @Test func sceneHasANamedNodePerPartCentredAndACamera() throws {
        let model = try #require(GuidedReplyParser.parse(engineReply).model3D)
        let scene = Model3DSceneBuilder.scene(for: model)
        let root = try #require(scene.rootNode.childNode(withName: Model3DSceneBuilder.modelName, recursively: false))
        #expect(root.childNodes.compactMap(Model3DSceneBuilder.partName) == model.parts.map(\.name))
        #expect(scene.rootNode.childNode(withName: Model3DSceneBuilder.cameraName, recursively: false)?.camera != nil)
        let center = root.boundingSphere.center
        #expect(abs(center.x) < 0.05 && abs(center.y) < 0.05 && abs(center.z) < 0.05)
    }
}
