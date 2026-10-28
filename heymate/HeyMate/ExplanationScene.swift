//
//  ExplanationScene.swift
//  HeyMate
//
//  A versioned scene a reply can stream: short narration beats, each with a
//  few allowlisted drawing operations. The model never sends code. A click
//  target only marks a control; it never clicks it. Coordinates stay tied
//  to the screenshot that produced them.
//

import CoreGraphics
import Foundation

struct ExplanationScene: Equatable {
    static let version = 1
    static let maximumBeats = 12
    static let maximumOperations = 8

    struct Beat: Equatable {
        let id: String
        let say: String
        let operations: [Operation]
    }

    enum Operation: Equatable {
        case ring(x: Double, y: Double, radius: Double, label: String?)
        case frame(x: Double, y: Double, width: Double, height: Double, label: String?)
        case pin(x: Double, y: Double, label: String?)
        case badge(number: Int, x: Double, y: Double, label: String?)
        case arrow(x1: Double, y1: Double, x2: Double, y2: Double, label: String?)
        case underline(x: Double, y: Double, width: Double)
        case highlight(x: Double, y: Double, width: Double, height: Double)
        case card(title: String, lines: [String])
        /// Marks a real control and waits. There is no operation that clicks.
        case clickTarget(x: Double, y: Double, label: String)
    }

    let beats: [Beat]
}

enum ExplanationSceneError: Equatable, Error {
    case wrongVersion
    case empty
    case tooManyBeats
    case duplicateBeatID
    case malformed
}

enum ExplanationSceneParser {

    static func parse(_ data: Data) -> Result<ExplanationScene, ExplanationSceneError> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scene = object["explanation"] as? [String: Any] else {
            return .failure(.malformed)
        }
        guard let version = scene["version"] as? Int else { return .failure(.malformed) }
        guard version == ExplanationScene.version else { return .failure(.wrongVersion) }
        guard let rawBeats = scene["beats"] as? [[String: Any]], !rawBeats.isEmpty else {
            return .failure(.empty)
        }
        guard rawBeats.count <= ExplanationScene.maximumBeats else { return .failure(.tooManyBeats) }
        var beats: [ExplanationScene.Beat] = []
        var seen: Set<String> = []
        for raw in rawBeats {
            guard let id = slug(raw["id"] as? String),
                  let say = trimmed(raw["say"] as? String, limit: 400),
                  let rawOps = raw["ops"] as? [[String: Any]],
                  rawOps.count <= ExplanationScene.maximumOperations,
                  let operations = operations(from: rawOps) else {
                return .failure(.malformed)
            }
            guard seen.insert(id).inserted else { return .failure(.duplicateBeatID) }
            beats.append(ExplanationScene.Beat(id: id, say: say, operations: operations))
        }
        return .success(ExplanationScene(beats: beats))
    }

    private static func operations(from rawOps: [[String: Any]]) -> [ExplanationScene.Operation]? {
        rawOps.compactMap { raw -> ExplanationScene.Operation? in
            guard let name = raw["op"] as? String else { return nil }
            switch name {
            case "ring":
                guard let x = number(raw["x"]), let y = number(raw["y"]), let radius = number(raw["r"]), radius > 0 else { return nil }
                return .ring(x: x, y: y, radius: radius, label: trimmed(raw["label"] as? String, limit: 40))
            case "frame":
                guard let x = number(raw["x"]), let y = number(raw["y"]),
                      let width = number(raw["w"]), let height = number(raw["h"]), width > 0, height > 0 else { return nil }
                return .frame(x: x, y: y, width: width, height: height, label: trimmed(raw["label"] as? String, limit: 40))
            case "pin":
                guard let x = number(raw["x"]), let y = number(raw["y"]) else { return nil }
                return .pin(x: x, y: y, label: trimmed(raw["label"] as? String, limit: 40))
            case "badge":
                guard let x = number(raw["x"]), let y = number(raw["y"]),
                      let numberValue = raw["n"] as? Int, (1...99).contains(numberValue) else { return nil }
                return .badge(number: numberValue, x: x, y: y, label: trimmed(raw["label"] as? String, limit: 40))
            case "arrow":
                guard let x1 = number(raw["x1"]), let y1 = number(raw["y1"]),
                      let x2 = number(raw["x2"]), let y2 = number(raw["y2"]) else { return nil }
                return .arrow(x1: x1, y1: y1, x2: x2, y2: y2, label: trimmed(raw["label"] as? String, limit: 40))
            case "underline":
                guard let x = number(raw["x"]), let y = number(raw["y"]), let width = number(raw["w"]), width > 0 else { return nil }
                return .underline(x: x, y: y, width: width)
            case "highlight":
                guard let x = number(raw["x"]), let y = number(raw["y"]),
                      let width = number(raw["w"]), let height = number(raw["h"]), width > 0, height > 0 else { return nil }
                return .highlight(x: x, y: y, width: width, height: height)
            case "card":
                guard let title = trimmed(raw["title"] as? String, limit: 60) else { return nil }
                let lines = ((raw["lines"] as? [String]) ?? []).prefix(5).compactMap { trimmed($0, limit: 120) }
                return .card(title: title, lines: lines)
            case "clickTarget":
                guard let x = number(raw["x"]), let y = number(raw["y"]),
                      let label = trimmed(raw["label"] as? String, limit: 40) else { return nil }
                return .clickTarget(x: x, y: y, label: label)
            default:
                return nil
            }
        }.nilIfShorter(than: rawOps.count)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func trimmed(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        return String(text.prefix(limit))
    }

    private static func slug(_ value: String?) -> String? {
        guard let value else { return nil }
        let folded = value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(folded).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        if collapsed.isEmpty { return nil }
        return String(collapsed.prefix(40))
    }
}

extension Array {
    fileprivate func nilIfShorter(than count: Int) -> Self? {
        self.count == count ? self : nil
    }
}

/// Plays beats in order. Cancelling a beat drops it and everything after it.
enum ExplanationScheduler {
    static func playableBeats(_ scene: ExplanationScene, cancelledAt beatID: String?) -> [ExplanationScene.Beat] {
        guard let beatID else { return scene.beats }
        guard let index = scene.beats.firstIndex(where: { $0.id == beatID }) else { return scene.beats }
        return Array(scene.beats.prefix(index))
    }
}

/// A drawing belongs to one screenshot. A newer capture makes the old point unusable.
enum AnnotationBinding {
    static func point(
        pixelX: Double,
        pixelY: Double,
        geometry: DisplayGeometry,
        stampedCaptureID: String,
        currentCaptureID: String
    ) -> CGPoint? {
        guard stampedCaptureID == currentCaptureID else { return nil }
        return ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: pixelX, y: pixelY),
            geometry: geometry
        )
    }
}
