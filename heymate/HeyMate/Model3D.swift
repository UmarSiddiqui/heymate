//
//  Model3D.swift
//  HeyMate
//
//  A 3D model a reply can build when the answer is a real thing (an engine,
//  a molecule, a building). The model writes one {"model3d": {...}} json
//  block: a title and named parts made of simple shapes. HeyMate builds it
//  part by part in a small window, where it turns slowly, can be dragged
//  round, and a click on a part asks about that part.
//

import Foundation

nonisolated struct Model3DSpec: Equatable {
    static let maximumParts = 60
    /// Model space is roughly -1…1; anything further out is pulled in.
    static let maximumExtent: Double = 4

    enum Shape: String, CaseIterable {
        case box, sphere, cylinder, cone, torus, capsule, tube
    }

    enum Material: String, CaseIterable {
        case matte, steel, glass, wood, paint, glow
    }

    enum Motion: String, CaseIterable {
        case spin, bob, pulse
    }

    struct Part: Equatable {
        let name: String
        let shape: Shape
        /// box [w,h,d]; sphere [r]; cylinder, cone, capsule [r,h];
        /// torus [ring, pipe]; tube uses `from`/`to` and size [r].
        let size: [Double]
        let position: [Double]
        /// Degrees around x, y, z.
        let rotation: [Double]
        let from: [Double]?
        let to: [Double]?
        let colorHex: String
        let material: Material
        let motion: Motion?
        /// One line the window shows when the pointer is over the part.
        let about: String?
    }

    let title: String
    let parts: [Part]
    /// Whether the whole model turns slowly on its own.
    let spins: Bool
}

nonisolated enum Model3DParser {

    /// Pulls the {"model3d": …} block out of a reply. Returns the text with
    /// the block (and its code fence) removed, and the model when it has at
    /// least one usable part. Text that only mentions the key is untouched.
    static func extract(from text: String) -> (text: String, model: Model3DSpec?) {
        guard let range = blockRange(in: text) else { return (text, nil) }
        guard let data = String(text[range]).data(using: .utf8),
              let wire = try? JSONDecoder().decode(WireEnvelope.self, from: data),
              let model = wire.model3d.flatMap(validate) else {
            return (text, nil)
        }
        var lower = range.lowerBound
        var upper = range.upperBound
        // Swallow a ``` or ```json fence wrapped around the block.
        let before = text[..<lower]
        if let fence = before.range(of: #"```[a-zA-Z0-9]*\s*$"#, options: .regularExpression) {
            lower = fence.lowerBound
        }
        let after = text[upper...]
        if let fence = after.range(of: #"^\s*```"#, options: .regularExpression) {
            upper = fence.upperBound
        }
        let remaining = (String(text[..<lower]) + " " + String(text[upper...]))
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (remaining, model)
    }

    /// Where a still-arriving model block starts, so a streaming caption can
    /// stop before it. Nil when no block has begun.
    static func openBlockStart(in text: String) -> String.Index? {
        guard let key = text.range(of: #"\"model3d\""#, options: .regularExpression),
              let brace = text[..<key.lowerBound].lastIndex(of: "{") else { return nil }
        if let fence = text[..<brace].range(of: #"```[a-zA-Z0-9]*\s*$"#, options: .regularExpression) {
            return fence.lowerBound
        }
        return brace
    }

    /// The balanced object that holds the "model3d" key. Braces inside
    /// strings do not count, since part names may contain them.
    private static func blockRange(in text: String) -> Range<String.Index>? {
        guard let start = openBlockStart(in: text),
              let open = text[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return open..<text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Validation

    static func validate(_ wire: WireModel) -> Model3DSpec? {
        let parts = (wire.parts ?? []).prefix(Model3DSpec.maximumParts).enumerated().compactMap { index, part in
            validate(part, index: index)
        }
        guard !parts.isEmpty else { return nil }
        let title = wire.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Model3DSpec(
            title: String((title?.isEmpty == false ? title! : "Model").prefix(60)),
            parts: parts,
            spins: wire.spin ?? true
        )
    }

    private static func validate(_ part: WirePart, index: Int) -> Model3DSpec.Part? {
        guard let shape = Model3DSpec.Shape(rawValue: (part.shape ?? "").lowercased()) else { return nil }
        let extent = Model3DSpec.maximumExtent
        func vector(_ values: [Double]?, fallback: [Double]) -> [Double] {
            guard let values, values.count == 3, values.allSatisfy(\.isFinite) else { return fallback }
            return values.map { min(max($0, -extent), extent) }
        }
        let sizes = (part.size ?? []).filter(\.isFinite).map { min(max(abs($0), 0.005), extent) }
        let needed: Int
        switch shape {
        case .box: needed = 3
        case .sphere, .tube: needed = 1
        case .cylinder, .cone, .capsule, .torus: needed = 2
        }
        let defaults: [Double] = shape == .tube ? [0.05] : [0.3, 0.3, 0.3]
        let size = sizes.count >= needed ? Array(sizes.prefix(needed)) : Array(defaults.prefix(needed))

        var from: [Double]?
        var to: [Double]?
        if shape == .tube {
            guard let start = part.from, let end = part.to, start.count == 3, end.count == 3 else { return nil }
            from = vector(start, fallback: [0, 0, 0])
            to = vector(end, fallback: [0, 0, 0])
            guard from != to else { return nil }
        }

        let name = part.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let about = part.about?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Model3DSpec.Part(
            name: String((name?.isEmpty == false ? name! : "part \(index + 1)").prefix(40)),
            shape: shape,
            size: size,
            position: vector(part.at, fallback: [0, 0, 0]),
            rotation: (part.rotate?.count == 3 && part.rotate!.allSatisfy(\.isFinite))
                ? part.rotate!.map { $0.truncatingRemainder(dividingBy: 360) } : [0, 0, 0],
            from: from,
            to: to,
            colorHex: validHex(part.color) ?? "#B8BCC4",
            material: Model3DSpec.Material(rawValue: (part.material ?? "").lowercased()) ?? .matte,
            motion: part.motion.flatMap { Model3DSpec.Motion(rawValue: $0.lowercased()) },
            about: about?.isEmpty == false ? String(about!.prefix(120)) : nil
        )
    }

    private static func validHex(_ value: String?) -> String? {
        guard let value else { return nil }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + hex.uppercased()
    }

    // MARK: - Wire

    struct WireEnvelope: Decodable {
        let model3d: WireModel?
    }

    struct WireModel: Decodable {
        let title: String?
        let parts: [WirePart]?
        let spin: Bool?
    }

    struct WirePart: Decodable {
        let name: String?
        let shape: String?
        let size: [Double]?
        let at: [Double]?
        let rotate: [Double]?
        let from: [Double]?
        let to: [Double]?
        let color: String?
        let material: String?
        let motion: String?
        let about: String?
    }
}
