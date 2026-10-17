import AppKit
import JavaScriptCore
import SwiftUI

/// One small, offline JavaScriptCore context supplies upstream geometry and motion.
/// Drawing is native SwiftUI Canvas: no web views, DOM, network or bitmap frames.
@MainActor
final class BlobatarNativeRenderer {
    static let shared = BlobatarNativeRenderer()
    private let context: JSContext?
    private var figures: [String: BlobatarFigure] = [:]

    init() {
        let context = JSContext()
        if let url = Bundle.main.url(forResource: "BlobatarRuntime", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            context?.evaluateScript(source)
        }
        self.context = context
    }

    var isAvailable: Bool { context?.objectForKeyedSubscript("HeyMateBlobatar")?.isObject == true }

    func figure(seed: String, options: [String: Any]) -> BlobatarFigure? {
        let key = seed + String(describing: options.sorted { $0.key < $1.key })
        if let figure = figures[key] { return figure }
        guard let result = api?.invokeMethod("figure", withArguments: [seed, options])?.toDictionary(),
              let marks = result["marks"] as? [[String: Any]],
              let eyes = result["eyes"] as? [[String: Any]],
              let frames = result["eyeFrames"] as? [[String: Double]],
              let fill = result["fill"] as? [String: String],
              let head = fill["head"], let eye = fill["eye"] else { return nil }
        let bodyPaths = marks.compactMap(Self.path)
        let eyePaths = eyes.compactMap(Self.path)
        guard !bodyPaths.isEmpty, eyePaths.count == frames.count else { return nil }
        let figure = BlobatarFigure(body: bodyPaths, eyes: eyePaths, headColor: Self.color(head),
                                    eyeColor: Self.color(eye), face: Self.survey(body: bodyPaths, eyes: eyePaths, frames: frames))
        if figures.count >= 256 { figures.removeAll(keepingCapacity: true) }
        figures[key] = figure
        return figure
    }

    func frame(id: String, seed: String, options: [String: Any], expression: String,
               now: Double, animate: Bool, target: [String: Double]?, figure: BlobatarFigure) -> BlobatarFrame? {
        guard let result = api?.invokeMethod("frame", withArguments: [id, seed, options, expression, now,
            animate, target as Any? ?? NSNull(), figure.face])?.toDictionary(),
              let body = result["body"] as? [Double],
              let eyes = result["eyes"] as? [[Double]],
              eyes.count == figure.eyes.count else { return nil }
        return BlobatarFrame(body: Self.transform(body), eyes: eyes.map(Self.transform))
    }

    func forget(_ id: String) { _ = api?.invokeMethod("forget", withArguments: [id]) }
    private var api: JSValue? { context?.objectForKeyedSubscript("HeyMateBlobatar") }

    private static func transform(_ values: [Double]) -> CGAffineTransform {
        guard values.count == 6, values.allSatisfy(\.isFinite) else { return .identity }
        return CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
    }

    /// Blobatar's primitives only emit absolute M/L/C/Q/Z paths and circles.
    /// Reject unknown commands rather than silently changing upstream geometry.
    static func path(_ mark: [String: Any]) -> Path? {
        if mark["kind"] as? String == "circle",
           let x = mark["cx"] as? Double, let y = mark["cy"] as? Double, let r = mark["r"] as? Double {
            return Path(ellipseIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2))
        }
        guard let text = mark["d"] as? String,
              let regex = try? NSRegularExpression(pattern: #"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"#) else { return nil }
        let tokens = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
        var path = Path()
        var index = 0
        func numbers(_ count: Int) -> [Double]? {
            guard index + count <= tokens.count else { return nil }
            let values = tokens[index..<(index+count)].compactMap(Double.init)
            guard values.count == count, values.allSatisfy(\.isFinite) else { return nil }
            index += count
            return values
        }
        while index < tokens.count {
            let command = tokens[index]; index += 1
            switch command {
            case "M", "L":
                guard let p = numbers(2) else { return nil }
                let point = CGPoint(x: p[0], y: p[1])
                if command == "M" { path.move(to: point) } else { path.addLine(to: point) }
            case "C":
                guard let p = numbers(6) else { return nil }
                path.addCurve(to: CGPoint(x: p[4], y: p[5]), control1: CGPoint(x: p[0], y: p[1]), control2: CGPoint(x: p[2], y: p[3]))
            case "Q":
                guard let p = numbers(4) else { return nil }
                path.addQuadCurve(to: CGPoint(x: p[2], y: p[3]), control: CGPoint(x: p[0], y: p[1]))
            case "Z": path.closeSubpath()
            default: return nil
            }
        }
        return path
    }

    /// Same silhouette survey as upstream gaze: inscribe an ellipse, inset for
    /// eye extents, then keep resting eyes away from its limb. Runs once per look.
    private static func survey(body: [Path], eyes: [Path], frames: [[String: Double]]) -> [String: Any] {
        let bounds = body.reduce(CGRect.null) { $0.union($1.boundingRect) }
        let cx = bounds.midX, cy = bounds.midY
        var fit = 1.0
        for index in 0..<16 {
            let angle = Double(index) / 16 * .pi * 2
            func hit(_ t: Double) -> Bool {
                let point = CGPoint(x: cx + t * bounds.width / 2 * cos(angle), y: cy + t * bounds.height / 2 * sin(angle))
                return body.contains { $0.contains(point) }
            }
            if hit(1) { continue }
            var low = 0.0, high = 1.0
            for _ in 0..<12 {
                let middle = (low+high)/2
                if hit(middle) { low = middle } else { high = middle }
            }
            fit = min(fit, low)
        }
        let insetX = eyes.map { $0.boundingRect.width / 2 }.max() ?? 0
        let insetY = eyes.map { $0.boundingRect.height / 2 }.max() ?? 0
        var rx = max(1, bounds.width / 2 * fit - insetX)
        var ry = max(1, bounds.height / 2 * fit - insetY)
        let centres = frames.map { CGPoint(x: ($0["cx"] ?? cx) - cx, y: ($0["cy"] ?? cy) - cy) }
        let need = centres.map { hypot($0.x / rx, $0.y / ry) }.max() ?? 0
        if need > 0.85 { rx *= need / 0.85; ry *= need / 0.85 }
        return ["rx": rx, "ry": ry, "marks": centres.map { ["x": $0.x / rx, "y": $0.y / ry] }]
    }

    private static func color(_ hex: String) -> Color {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct BlobatarFigure {
    let body: [Path]
    let eyes: [Path]
    let headColor: Color
    let eyeColor: Color
    let face: [String: Any]

    /// Fit the actual silhouette, not upstream's padded 100-unit viewBox.
    /// A surface companion keeps a small safety margin below its resting edge.
    func fittingTransform(in size: CGSize, restsOnSurface: Bool = false) -> CGAffineTransform {
        let bounds = body.reduce(CGRect.null) { $0.union($1.boundingRect) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return .identity }
        let scale = min(size.width / bounds.width, size.height / bounds.height) * 0.94
        let x = (size.width - bounds.width * scale) / 2 - bounds.minX * scale
        let bottom = restsOnSurface ? size.height * 0.98 : (size.height + bounds.height * scale) / 2
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: bottom - bounds.maxY * scale)
    }
}

struct BlobatarFrame {
    let body: CGAffineTransform
    let eyes: [CGAffineTransform]
}
