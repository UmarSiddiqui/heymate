import Foundation
import CoreFoundation
import CoreGraphics

/// Model output is data. Only these constructors and property assignments can
/// become source code for the existing renderer. Each complete line is a beat.
nonisolated enum ExplanationProgram {
    struct Projection {
        let scaleX: Double
        let scaleY: Double
        let offsetX: Double
        let offsetY: Double
        static let identity = Projection(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0)
    }
    struct Viewport {
        let frame: CGRect
        let canvas: CGSize
        let projection: Projection
    }

    static func viewport(captureFrame: CGRect, imageSize: CGSize, displayFrame: CGRect,
                         existingFrame: CGRect?, existingCanvas: CGSize?) -> Viewport {
        let frame = existingFrame ?? displayFrame
        let density = imageSize.width / max(1, captureFrame.width)
        let canvas = existingCanvas ?? CGSize(width: (frame.width * density).rounded(), height: (frame.height * density).rounded())
        let x = canvas.width / max(1, frame.width), y = canvas.height / max(1, frame.height)
        return Viewport(frame: frame, canvas: canvas, projection: Projection(
            scaleX: captureFrame.width / max(1, imageSize.width) * x,
            scaleY: captureFrame.height / max(1, imageSize.height) * y,
            offsetX: (captureFrame.minX - frame.minX) * x,
            offsetY: (frame.maxY - captureFrame.maxY) * y))
    }
    static let fence = "```heymate\n"
    static let maximumBytes = 196_608
    static let maximumBeats = 12
    static let maximumCommands = 32

    struct Compiled {
        var source = "var __hm = typeof __hm === 'object' ? __hm : Object.create(null);\n"
        var lines: [String] = []
        var inventory: [String: String] = [:]
        var closed = false
        var error: String?
        var rows: [String] = []
        var resetsInventory = false
    }

    private static let drawingCalls: Set<String> = [
        "point", "ring", "frame", "target", "hover", "label", "num", "underline", "highlight", "check", "cross",
        "connect", "trace", "ink", "line", "curve", "arrow", "rect", "circle", "ellipse", "poly", "path", "dot", "text", "write",
        "paper", "sticky", "graph", "timeline", "figure"
    ]
    private static let shapes: Set<String> = ["box", "cyl", "cone", "sphere", "tube", "torus", "capsule", "lathe", "pipe", "spring", "gear", "extrude", "blob", "poly", "arrow", "group"]
    private static let methods: Set<String> = ["label", "spin", "bob", "orbit", "pulse", "path", "move", "view", "camera", "sliderCrank", "plot", "line", "point", "area", "band", "at", "slot", "part"]
    private static let edits: Set<String> = ["erase", "recolor", "restyle", "move", "moveTo", "scale", "highlight"]
    private static let properties: Set<String> = ["pos", "rot", "scale", "show", "glow", "color"]
    private static let fields: Set<String> = ["x", "y", "w", "h", "id"]
    private static let forbiddenKeys: Set<String> = ["__proto__", "constructor", "prototype"]

    enum Invalid: Error { case command }

    /// Partial JSON waits for its newline. A malformed complete beat stops the
    /// stream at its valid prefix, so no part of that beat can execute.
    static func compile(_ reply: String, availableIDs: [String: String]? = nil, projection: Projection = .identity) -> Compiled? {
        guard let opening = reply.range(of: fence) else { return nil }
        var result = Compiled()
        let tail = reply[opening.upperBound...]
        let closing = tail.range(of: "```")
        let body = closing.map { tail[..<$0.lowerBound] } ?? tail[...]
        result.closed = closing != nil
        guard body.utf8.count <= maximumBytes else {
            result.error = "Drawing exceeds the command size limit."
            result.closed = true
            return result
        }
        var rows = body.split(separator: "\n", omittingEmptySubsequences: false)
        if !result.closed && !body.hasSuffix("\n") { rows = Array(rows.dropLast()) }
        var seen = Set<String>()
        var parts = 0, figures = 0
        var known = availableIDs ?? [:]
        for row in rows where !row.trimmingCharacters(in: .whitespaces).isEmpty {
            do {
                guard result.lines.count < maximumBeats,
                      let beat = try JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
                      let id = beat["id"] as? String, validID(id), seen.insert(id).inserted,
                      let say = beat["say"] as? String, !say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, say.count <= 400,
                      let commands = beat["ops"] as? [[String: Any]], commands.count <= maximumCommands else { throw Invalid.command }
                // Validate the whole beat before appending its speech or commands.
                var nextKnown = known
                for command in commands {
                    if command["op"] as? String == "startOver" { nextKnown.removeAll() }
                    var references = referencedIDs(command)
                    for key in ["target", "figure"] {
                        if let name = command[key] as? String { references.insert(name) }
                    }
                    if availableIDs != nil && references.contains(where: { nextKnown[$0] == nil }) { throw Invalid.command }
                    if let target = command["figure"] as? String, let kind = nextKnown[target], kind != "figure" { throw Invalid.command }
                    if command["op"] as? String == "call", let target = command["target"] as? String,
                       let kind = nextKnown[target], let method = command["method"] as? String {
                        let figureMethods: Set<String> = ["label","view","camera","sliderCrank","part","move"]
                        if figureMethods.contains(method) && kind != "figure" { throw Invalid.command }
                    }
                    if let name = command["id"] as? String {
                        nextKnown[name] = (command["kind"] as? String) ?? (command["op"] as? String) ?? "mark"
                    }
                }
                let statements = try commands.map { try statement($0, projection: projection) }
                var nextParts = parts, nextFigures = figures
                for command in commands {
                    if command["op"] as? String == "figure" { nextFigures += 1 }
                    if command["op"] as? String == "part" {
                        let options = command["options"] as? [String: Any] ?? [:]
                        let copies = (options["copies"] as? [String: Any])?["count"] as? Int ?? 1
                        let around = (options["around"] as? [String: Any])?["count"] as? Int ?? 1
                        let mirrors = (options["mirror"] as? [String])?.count ?? (options["mirror"] == nil ? 0 : 1)
                        guard mirrors <= 3 else { throw Invalid.command }
                        nextParts += copies * around * (1 << mirrors)
                    }
                }
                guard nextParts <= 256, nextFigures <= 4 else { throw Invalid.command }
                parts = nextParts
                figures = nextFigures
                known = nextKnown
                result.source += "step(\(result.lines.count + 1)); say(\(try json(say)));\n" + statements.joined(separator: "\n") + "\n"
                result.lines.append(say)
                result.rows.append(String(row))
                for command in commands {
                    if command["op"] as? String == "startOver" { result.inventory.removeAll(); result.resetsInventory = true }
                    if let name = command["id"] as? String {
                        result.inventory[name] = (command["kind"] as? String) ?? (command["op"] as? String) ?? "mark"
                    }
                }
            } catch {
                result.error = "Drawing beat \(result.lines.count + 1) contains an invalid or unsupported command."
                result.closed = true
                break
            }
        }
        return result
    }

    private static func referencedIDs(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            var ids = Set(object.values.flatMap { referencedIDs($0) })
            if let ref = object["ref"] as? String { ids.insert(ref) }
            return ids
        }
        if let array = value as? [Any] { return Set(array.flatMap { referencedIDs($0) }) }
        return []
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 48 && value.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45
        }
    }

    private static func reference(_ value: Any?) throws -> String {
        guard let name = value as? String, validID(name) else { throw Invalid.command }
        return "__hm[\(try json(name))]"
    }

    /// JSON literals plus explicit handle references. No callbacks, expressions,
    /// computed property names, code strings, or native action capabilities.
    private static func expression(_ value: Any, depth: Int = 0) throws -> String {
        guard depth <= 12 else { throw Invalid.command }
        if let object = value as? [String: Any] {
            guard object.count <= 40, forbiddenKeys.isDisjoint(with: object.keys) else { throw Invalid.command }
            if let ref = object["ref"] {
                var code = try reference(ref)
                if let field = object["field"] as? String {
                    guard fields.contains(field) else { throw Invalid.command }
                    code += ".\(field)"
                    if let add = object["add"] { code = "(\(code) + \(try number(add)))" }
                } else if object.count != 1 { throw Invalid.command }
                return code
            }
            return "{" + (try object.keys.sorted().map { key in
                // Limit repeats and tessellation before procedural mesh creation.
                if ["count", "teeth", "coils", "segments", "rows", "lumps"].contains(key) {
                    let limit = key == "count" ? 32.0 : 96.0
                    guard let n = object[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 1, n.doubleValue <= limit else { throw Invalid.command }
                }
                return "\(try json(key)):\(try expression(object[key]!, depth: depth + 1))"
            }).joined(separator: ",") + "}"
        }
        if let list = value as? [Any] {
            guard list.count <= 512 else { throw Invalid.command }
            return "[" + (try list.map { try expression($0, depth: depth + 1) }).joined(separator: ",") + "]"
        }
        if let string = value as? String {
            guard string.count <= 4096 else { throw Invalid.command }
            return try json(string)
        }
        if value is NSNull { return "null" }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return try number(n)
        }
        throw Invalid.command
    }

    private static func number(_ value: Any) throws -> String {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              abs(n.doubleValue) <= 1_000_000 else { throw Invalid.command }
        return n.stringValue
    }

    private static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else { throw Invalid.command }
        return result
    }

    private static func statement(_ command: [String: Any], projection: Projection) throws -> String {
        guard let op = command["op"] as? String else { throw Invalid.command }
        let code: String
        if drawingCalls.contains(op) && command["target"] == nil {
            guard let args = command["args"] as? [Any], args.count <= 8 else { throw Invalid.command }
            let coordinateCount: Int
            switch op {
            case "figure", "paper", "graph", "timeline", "ring", "frame", "target", "hover", "rect", "highlight": coordinateCount = 4
            case "circle", "underline": coordinateCount = 3
            case "ellipse": coordinateCount = 4
            case "point", "label", "text", "write", "sticky", "num", "check", "cross", "dot": coordinateCount = 2
            default: coordinateCount = 0
            }
            guard args.count >= coordinateCount else { throw Invalid.command }
            for value in args.prefix(coordinateCount) {
                if let ref = value as? [String: Any], ref["ref"] != nil,
                   let field = ref["field"] as? String, ["x","y","w","h"].contains(field) { continue }
                _ = try number(value)
            }
            if ["figure","paper","graph","timeline","ring","frame","target","hover","rect","highlight"].contains(op) {
                for value in args[2..<4] {
                    if let n = value as? NSNumber, n.doubleValue <= 0 { throw Invalid.command }
                }
            }
            var mapped = args
            func coordinate(_ value: Any, axis: Int, dimension: Bool = false) -> Any {
                let scale = axis == 0 ? projection.scaleX : projection.scaleY
                if var ref = value as? [String: Any] {
                    if let add = ref["add"] as? NSNumber { ref["add"] = add.doubleValue * scale }
                    return ref
                }
                guard let number = value as? NSNumber else { return value }
                let offset = dimension ? 0 : axis == 0 ? projection.offsetX : projection.offsetY
                return number.doubleValue * scale + offset
            }
            if coordinateCount >= 2 {
                mapped[0] = coordinate(args[0], axis: 0)
                mapped[1] = coordinate(args[1], axis: 1)
                for index in 2..<coordinateCount { mapped[index] = coordinate(args[index], axis: index == 3 ? 1 : 0, dimension: true) }
            }
            if ["line","curve","arrow","poly","trace","ink"].contains(op), let points = args.first as? [[Any]] {
                mapped[0] = points.map { point in
                    point.count == 2 ? [coordinate(point[0], axis: 0), coordinate(point[1], axis: 1)] : point
                }
            }
            if op == "connect" {
                for index in 0..<min(2,args.count) {
                    if let point = args[index] as? [Any], point.count == 2 {
                        mapped[index] = [coordinate(point[0], axis: 0), coordinate(point[1], axis: 1)]
                    }
                }
            }
            code = op + "(" + (try mapped.map { try expression($0) }).joined(separator: ",") + ")"
        } else if op == "part" {
            guard let kind = command["kind"] as? String, shapes.contains(kind),
                  let options = command["options"] as? [String: Any] else { throw Invalid.command }
            code = "\(try reference(command["figure"])).\(kind)(\(try expression(options)))"
        } else if op == "call" {
            guard let method = command["method"] as? String, methods.contains(method),
                  let args = command["args"] as? [Any], args.count <= 6 else { throw Invalid.command }
            code = "\(try reference(command["target"])).\(method)(" + (try args.map { try expression($0) }).joined(separator: ",") + ")"
        } else if op == "set" {
            guard let values = command["values"] as? [String: Any], !values.isEmpty,
                  Set(values.keys).isSubset(of: properties), command["id"] == nil else { throw Invalid.command }
            for (key, value) in values {
                if key == "pos" || key == "rot" {
                    guard let vector = value as? [Any], vector.count == 3 else { throw Invalid.command }
                    for item in vector { _ = try number(item) }
                } else if key == "show" {
                    guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw Invalid.command }
                } else if key == "color" {
                    guard let color = value as? String, !color.isEmpty, color.count <= 80 else { throw Invalid.command }
                } else {
                    _ = try number(value)
                    let n = (value as! NSNumber).doubleValue
                    guard n >= 0, n <= (key == "glow" ? 1 : 100) else { throw Invalid.command }
                }
            }
            return try values.keys.sorted().map { key in
                "\(try reference(command["target"])).\(key) = \(try expression(values[key]!));"
            }.joined(separator: "\n")
        } else if edits.contains(op) {
            let args = command["args"] as? [Any] ?? []
            guard args.count <= 3 else { throw Invalid.command }
            let handle = try reference(command["target"])
            code = "editNamed(\(try json(op)), \(handle), \(try expression(args)))"
        } else if op == "startOver" {
            return "startOver(); __hm = Object.create(null);"
        } else { throw Invalid.command }
        if let name = command["id"] {
            let value = drawingCalls.contains(op) ? "named(\(try json(name)), () => \(code))" : code
            return "\(try reference(name)) = \(value);"
        }
        return code + ";"
    }
}
