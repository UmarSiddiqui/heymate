import Foundation

/// Live native characters powered by Alain's MIT-licensed Blobatar 2.7.0.
/// Tokens identify a fixed look, so renaming a mate never changes its character.
enum BlobatarCharacter {
    static let automaticToken = "blobatar:auto"
    static let generatedPrefix = "blobatar:"
    static func randomToken() -> String { generatedPrefix + UUID().uuidString.lowercased() }

    static let faces = ["Tide", "Lilac", "Peach", "Cloud", "Sun", "Mint"].map {
        MateFaceChoice(assetName: "Blobatar\($0)", label: "Blobatar \($0)")
    }

    static let pack = MateFacePack(
        id: "blobatar", name: "Blobatar",
        summary: "A unique companion for every bot. Live eyes, blinking, and cursor tracking by Alain.",
        faces: [MateFaceChoice(assetName: automaticToken, label: "Your Blobatar")] + faces
    )

    static func contains(_ token: String) -> Bool {
        token == automaticToken || faces.contains { $0.assetName == token }
            || (token.hasPrefix(generatedPrefix) && UUID(uuidString: String(token.dropFirst(generatedPrefix.count))) != nil)
    }

    static func artwork(for token: String, expression: MateFaceExpression) -> String {
        guard contains(token) else { return token }
        if !faces.contains(where: { $0.assetName == token }) { return "BlobatarTide" }
        let pose = pose(for: expression)
        return pose == "idle" ? token : "\(token)-\(pose)"
    }

    static func pose(for expression: MateFaceExpression) -> String {
        switch expression {
        case .still, .idle: return "idle"
        case .thinking, .reading, .writing, .tooling, .browsing: return "thinking"
        case .listening, .attention, .speaking: return "surprised"
        case .success: return "happy"
        case .failure: return "sad"
        case .guiding: return "wink"
        }
    }

    struct Configuration {
        let seed: String
        let options: [String: Any]
    }

    static func configuration(token: String, mateID: UUID) -> Configuration {
        if token == automaticToken {
            return Configuration(seed: mateID.uuidString.lowercased(), options: [:])
        }
        if token.hasPrefix(generatedPrefix) {
            return Configuration(seed: String(token.dropFirst(generatedPrefix.count)).lowercased(), options: [:])
        }
        let labels = ["Tide", "Lilac", "Peach", "Cloud", "Sun", "Mint"]
        let hues = [190, 290, 35, 220, 80, 155]
        let shapes = [0.32, 0.1, 0.51, 0.82, 0.96, 0.74]
        guard let index = faces.firstIndex(where: { $0.assetName == token }) else {
            return Configuration(seed: mateID.uuidString.lowercased(), options: [:])
        }
        return Configuration(seed: "HeyMate Blobatar \(labels[index])",
                             options: ["hue": hues[index], "tone": 0.25, "traits": ["shape": shapes[index]]])
    }
}
