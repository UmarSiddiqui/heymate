//
//  PointingTagParser.swift
//  HeyMate
//
//  Reads the visual tag a reply can end with — [POINT:x,y:label:screenN],
//  [RECT:x,y,w,h:label:screenN] or [SCRIBBLE:x,y;x,y;...:label:screenN] —
//  and splits it from the words to speak. Also trims a tag that is still
//  arriving mid-stream so text-to-speech never reads control syntax aloud.
//  Moving the cursor and drawing stay in CompanionManager.
//

import CoreGraphics
import Foundation

nonisolated struct PointingParseResult: Equatable {
    let spokenText: String
    let coordinate: CGPoint?
    let elementLabel: String?
    let screenNumber: Int?
    let visualGuidance: VisualGuidanceTag?
}

nonisolated enum VisualGuidanceTag: Equatable {
    case rectangle(CGRect)
    case scribble([CGPoint])
}

nonisolated enum PointingTagParser {

    // Each tag may end with `:label` (can't start with whitespace or hold
    // ':' or ']') and `:screenN`. Coordinates may be negative: a model
    // pointing at something cut off by the image edge can overshoot a
    // little, and the screen math clamps it; refusing the sign would leave
    // the tag unparsed and spoken aloud. Compiled once, since parsing runs
    // on every streamed chunk of a reply.
    private static let pointTag = regex(
        #"\[POINT:(?:none|(-?\d+)\s*,\s*(-?\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#
    )
    private static let rectTag = regex(
        #"\[RECT:(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]\s*$"#
    )
    private static let scribbleTag = regex(
        #"\[SCRIBBLE:([^:\]]+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]\s*$"#
    )

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo should fail loudly in tests.
        try! NSRegularExpression(pattern: pattern)
    }

    static func parse(_ text: String) -> PointingParseResult {
        parseRectangle(text) ?? parseScribble(text) ?? parsePoint(text)
    }

    /// Drops a trailing, still-open `[POINT` / `[RECT` / `[SCRIBBLE` tag.
    static func stripTrailingFragment(_ text: String) -> String {
        guard let open = text.lastIndex(of: "["), !text[open...].contains("]") else { return text }
        let fragment = text[open...].uppercased()
        let isVisualTag = ["[POINT", "[RECT", "[SCRIBBLE"].contains { tag in
            tag.hasPrefix(fragment) || fragment.hasPrefix(tag + ":")
        }
        return isVisualTag ? String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    /// Turns RECT and SCRIBBLE geometry (screenshot pixels) into drawings in
    /// normalized coordinates. POINT moves the cursor and is not drawn.
    static func visualActions(
        from result: PointingParseResult,
        screenshotPixelWidth: Int,
        screenshotPixelHeight: Int
    ) -> [VisualAction] {
        guard let guidance = result.visualGuidance, screenshotPixelWidth > 0, screenshotPixelHeight > 0 else {
            return []
        }
        let width = Double(screenshotPixelWidth)
        let height = Double(screenshotPixelHeight)

        var rect: [Double]?
        var points: [[Double]]?
        let type: VisualAction.Kind
        switch guidance {
        case .rectangle(let r):
            type = .highlight
            rect = [Double(r.minX) / width, Double(r.minY) / height, Double(r.width) / width, Double(r.height) / height]
        case .scribble(let path):
            type = .polyline
            points = path.map { [Double($0.x) / width, Double($0.y) / height] }
        }

        let action = VisualAction(
            type: type,
            screenId: result.screenNumber.map { "screen\($0)" },
            x: nil,
            y: nil,
            points: points,
            center: nil,
            radius: nil,
            rect: rect,
            label: result.elementLabel,
            ttlMs: 6000
        )
        return VisualActionParser.validate(action).map { [$0] } ?? []
    }

    // MARK: - Tags

    private static func parsePoint(_ text: String) -> PointingParseResult {
        guard let tag = Match(pointTag, in: text) else {
            return PointingParseResult(spokenText: text, coordinate: nil, elementLabel: nil,
                                       screenNumber: nil, visualGuidance: nil)
        }
        guard let x = tag.double(1), let y = tag.double(2) else {
            // [POINT:none]: the model chose not to point.
            return PointingParseResult(spokenText: tag.spokenText, coordinate: nil, elementLabel: "none",
                                       screenNumber: nil, visualGuidance: nil)
        }
        return PointingParseResult(spokenText: tag.spokenText, coordinate: CGPoint(x: x, y: y),
                                   elementLabel: tag.label(3), screenNumber: tag.int(4), visualGuidance: nil)
    }

    private static func parseRectangle(_ text: String) -> PointingParseResult? {
        guard let tag = Match(rectTag, in: text),
              let x = tag.double(1), let y = tag.double(2),
              let width = tag.double(3), let height = tag.double(4) else { return nil }
        return PointingParseResult(spokenText: tag.spokenText, coordinate: nil, elementLabel: tag.label(5),
                                   screenNumber: tag.int(6),
                                   visualGuidance: .rectangle(CGRect(x: x, y: y, width: width, height: height)))
    }

    private static func parseScribble(_ text: String) -> PointingParseResult? {
        guard let tag = Match(scribbleTag, in: text), let path = tag.string(1) else { return nil }
        let points = path.split(separator: ";").compactMap { pair -> CGPoint? in
            let values = pair.split(separator: ",", maxSplits: 1)
                .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return values.count == 2 ? CGPoint(x: values[0], y: values[1]) : nil
        }
        guard points.count >= 2 else { return nil }
        return PointingParseResult(spokenText: tag.spokenText, coordinate: nil, elementLabel: tag.label(2),
                                   screenNumber: tag.int(3), visualGuidance: .scribble(points))
    }

    /// One tag match and typed access to its capture groups.
    private nonisolated struct Match {
        let text: String
        let result: NSTextCheckingResult
        let spokenText: String

        init?(_ regex: NSRegularExpression, in text: String) {
            guard let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(result.range, in: text) else { return nil }
            self.text = text
            self.result = result
            spokenText = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func string(_ group: Int) -> String? {
            guard group < result.numberOfRanges, let range = Range(result.range(at: group), in: text) else { return nil }
            return String(text[range])
        }

        func double(_ group: Int) -> Double? { string(group).flatMap(Double.init) }
        func int(_ group: Int) -> Int? { string(group).flatMap(Int.init) }

        func label(_ group: Int) -> String? {
            guard let label = string(group)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                return nil
            }
            return label
        }
    }
}
