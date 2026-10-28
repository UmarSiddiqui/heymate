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
import simd

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
        /// Stable id a later reply uses to patch this part without rebuilding the rest.
        let id: String
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
        /// shell parts are the outer skin a section cut hides. interior, structure
        /// and detail stay. Nil means the part is always shown.
        let role: String?
    }

    let title: String
    let parts: [Part]
    /// Whether the whole model turns slowly on its own.
    let spins: Bool
    /// How far parts spread from the model's centre. 0 keeps them assembled.
    let explode: Double
    /// Roles omitted from the scene. A section cut hides "shell".
    let hiddenRoles: Set<String>

    /// A follow-up ("remove the shell", "zoom the parts apart") applied to a
    /// model that is already on screen. Parts keep their ids.
    func patched(remove removedIDs: Set<String>, about updates: [String: String], explode nextExplode: Double?, section: Bool) -> Model3DSpec {
        var parts = self.parts
        let survivors = parts.filter { !removedIDs.contains($0.id) }
        if !survivors.isEmpty { parts = survivors }
        if !updates.isEmpty {
            parts = parts.map { part in
                guard let about = updates[part.id] else { return part }
                return part.relabelled(about)
            }
        }
        var hidden = hiddenRoles
        if section { hidden.insert("shell") }
        return Model3DSpec(
            title: title,
            parts: parts,
            spins: spins,
            explode: nextExplode ?? explode,
            hiddenRoles: hidden
        )
    }
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

    /// A follow-up block that changes the model already on screen. Removed
    /// from the spoken text the same way a new model is.
    static func extractPatch(from text: String) -> (text: String, patch: Model3DPatch?) {
        guard let range = blockRange(in: text, key: "model3d_patch") else { return (text, nil) }
        guard let data = String(text[range]).data(using: .utf8),
              let wire = try? JSONDecoder().decode(WirePatchEnvelope.self, from: data),
              let patch = wire.patch.flatMap(validatePatch),
              !patch.isEmpty else {
            return (text, nil)
        }
        let remaining = textRemovingBlock(text, range: range)
        return (remaining, patch)
    }

    /// Where a still-arriving model block starts, so a streaming caption can
    /// stop before it. Nil when no block has begun.
    static func openBlockStart(in text: String) -> String.Index? {
        ["model3d", "model3d_patch"].compactMap { openBlockStart(in: text, key: $0) }.min()
    }

    private static func openBlockStart(in text: String, key: String) -> String.Index? {
        guard let keyRange = text.range(of: "\"\(key)\"", options: .regularExpression),
              let brace = text[..<keyRange.lowerBound].lastIndex(of: "{") else { return nil }
        if let fence = text[..<brace].range(of: #"```[a-zA-Z0-9]*\s*$"#, options: .regularExpression) {
            return fence.lowerBound
        }
        return brace
    }

    private static func textRemovingBlock(_ text: String, range: Range<String.Index>) -> String {
        var lower = range.lowerBound
        var upper = range.upperBound
        let before = text[..<lower]
        if let fence = before.range(of: #"```[a-zA-Z0-9]*\s*$"#, options: .regularExpression) {
            lower = fence.lowerBound
        }
        let after = text[upper...]
        if let fence = after.range(of: #"^\s*```"#, options: .regularExpression) {
            upper = fence.upperBound
        }
        return (String(text[..<lower]) + " " + String(text[upper...]))
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The balanced object that holds the "model3d" key. Braces inside
    /// strings do not count, since part names may contain them.
    private static func blockRange(in text: String) -> Range<String.Index>? {
        blockRange(in: text, key: "model3d")
    }

    private static func blockRange(in text: String, key: String) -> Range<String.Index>? {
        guard let start = openBlockStart(in: text, key: key),
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
        let parts = uniqueIDs((wire.parts ?? []).prefix(Model3DSpec.maximumParts).enumerated().compactMap { index, part in
            validate(part, index: index)
        })
        guard !parts.isEmpty else { return nil }
        let title = wire.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Model3DSpec(
            title: String((title?.isEmpty == false ? title! : "Model").prefix(60)),
            parts: parts,
            spins: wire.spin ?? true,
            explode: 0,
            hiddenRoles: []
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
        let resolvedName = String((name?.isEmpty == false ? name! : "part \(index + 1)").prefix(40))
        return Model3DSpec.Part(
            id: partID(part.id, fallback: resolvedName, index: index),
            name: resolvedName,
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
            about: about?.isEmpty == false ? String(about!.prefix(120)) : nil,
            role: allowedRole(part.role)
        )
    }

    private static let allowedRoles: Set<String> = ["shell", "interior", "structure", "detail"]

    private static func allowedRole(_ value: String?) -> String? {
        guard let value else { return nil }
        let role = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowedRoles.contains(role) ? role : nil
    }

    /// Ids are how a later reply names a part. Spaces and punctuation become dashes.
    private static func uniqueIDs(_ parts: [Model3DSpec.Part]) -> [Model3DSpec.Part] {
        var seen: Set<String> = []
        return parts.map { part in
            var id = part.id
            var suffix = 2
            while seen.contains(id) {
                id = String("\(part.id)-\(suffix)".prefix(40))
                suffix += 1
            }
            seen.insert(id)
            guard id != part.id else { return part }
            return Model3DSpec.Part(
                id: id, name: part.name, shape: part.shape, size: part.size, position: part.position,
                rotation: part.rotation, from: part.from, to: part.to, colorHex: part.colorHex,
                material: part.material, motion: part.motion, about: part.about, role: part.role
            )
        }
    }

    private static func partID(_ raw: String?, fallback: String, index: Int) -> String {
        let source = (raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? raw! : fallback
        let folded = source.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(folded).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        if collapsed.isEmpty { return "part-\(index + 1)" }
        return String(collapsed.prefix(40))
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
        let id: String?
        let role: String?
    }

    struct WirePatchEnvelope: Decodable {
        let patch: WirePatch?
        enum CodingKeys: String, CodingKey { case patch = "model3d_patch" }
    }

    struct WirePatch: Decodable {
        let remove: [String]?
        let about: [String: String]?
        let explode: Double?
        let section: Bool?
    }

    private static func validatePatch(_ wire: WirePatch) -> Model3DPatch? {
        let remove = Set((wire.remove ?? []).compactMap { slug($0) })
        var about: [String: String] = [:]
        for (key, value) in wire.about ?? [:] {
            guard let id = slug(key) else { continue }
            let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { about[id] = String(line.prefix(120)) }
        }
        let explode = wire.explode.flatMap { $0.isFinite ? min(max($0, 0), 1.5) : nil }
        let section = wire.section == true
        let patch = Model3DPatch(remove: remove, about: about, explode: explode, section: section)
        return patch.isEmpty ? nil : patch
    }

    private static func slug(_ raw: String) -> String? {
        let folded = raw.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(folded).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        if collapsed.isEmpty { return nil }
        return String(collapsed.prefix(40))
    }
}

/// A change to the model already on screen. A section hides parts marked
/// "shell"; it does not slice a mesh. Parts are authored already split into
/// skin and interior, which is the cut this version can show.
struct Model3DPatch: Equatable {
    let remove: Set<String>
    let about: [String: String]
    let explode: Double?
    let section: Bool

    var isEmpty: Bool {
        remove.isEmpty && about.isEmpty && explode == nil && !section
    }
}

extension Model3DSpec.Part {
    fileprivate static func vector(_ values: [Double]) -> simd_double3 {
        simd_double3(values.count > 0 ? values[0] : 0, values.count > 1 ? values[1] : 0, values.count > 2 ? values[2] : 0)
    }

    fileprivate func relabelled(_ about: String) -> Model3DSpec.Part {
        Model3DSpec.Part(
            id: id, name: name, shape: shape, size: size, position: position, rotation: rotation,
            from: from, to: to, colorHex: colorHex, material: material, motion: motion,
            about: String(about.prefix(120)), role: role
        )
    }

    /// Moves a part away from the model centre for an exploded view. Tubes
    /// move as a rigid piece: both ends shift by the same amount.
    func exploded(from centroid: simd_double3, distance: Double) -> Model3DSpec.Part {
        guard distance > 0 else { return self }
        let anchor: simd_double3
        if shape == .tube, let from, let to {
            anchor = (Self.vector(from) + Self.vector(to)) / 2
        } else {
            anchor = Self.vector(position)
        }
        let delta = anchor - centroid
        let length = simd_length(delta)
        guard length > 0.0001 else { return self }
        let shift = delta / length * distance
        func moved(_ values: [Double]) -> [Double] {
            let point = Self.vector(values) + shift
            return [point.x, point.y, point.z]
        }
        return Model3DSpec.Part(
            id: id, name: name, shape: shape, size: size,
            position: shape == .tube ? position : moved(position),
            rotation: rotation,
            from: from.map(moved),
            to: to.map(moved),
            colorHex: colorHex, material: material, motion: motion, about: about, role: role
        )
    }
}
