//
//  PointingTagParser.swift
//  leanring-buddy
//
//  Testable [POINT:] / [RECT:] / [SCRIBBLE:] parser plus a streaming sanitizer
//  that drops a half-arrived tag so TTS never speaks control syntax.
//  Overlay choreography stays in CompanionManager / VisualActionResolver.
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

    static func parse(_ responseText: String) -> PointingParseResult {
        if let rectangle = parseRectangle(from: responseText) {
            return rectangle
        }
        if let scribble = parseScribble(from: responseText) {
            return scribble
        }
        return parsePoint(from: responseText)
    }

    /// Drops a trailing partial `[POINT` / `[RECT` / `[SCRIBBLE` tag so
    /// streaming TTS does not speak control syntax mid-token.
    static func stripTrailingFragment(_ text: String) -> String {
        guard let openBracket = text.lastIndex(of: "[") else { return text }
        let fragment = text[openBracket...]
        guard !fragment.contains("]") else { return text }

        let upperFragment = fragment.uppercased()
        let visualPrefixes = ["[POINT", "[RECT", "[SCRIBBLE"]
        let isPartialVisualTag = visualPrefixes.contains { prefix in
            prefix.hasPrefix(upperFragment) || upperFragment.hasPrefix(prefix + ":")
        }
        guard isPartialVisualTag else { return text }
        return String(text[..<openBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts RECT/SCRIBBLE screenshot-pixel geometry into VisualAction
    /// drawings. POINT stays on the buddy-cursor path, not here.
    static func visualActions(
        from result: PointingParseResult,
        screenshotPixelWidth: Int,
        screenshotPixelHeight: Int
    ) -> [VisualAction] {
        guard let visualGuidance = result.visualGuidance,
              screenshotPixelWidth > 0,
              screenshotPixelHeight > 0 else {
            return []
        }

        let width = Double(screenshotPixelWidth)
        let height = Double(screenshotPixelHeight)
        let screenId: String? = result.screenNumber.map { "screen\($0)" }

        switch visualGuidance {
        case .rectangle(let rect):
            let normalized = [
                rect.origin.x / width,
                rect.origin.y / height,
                rect.size.width / width,
                rect.size.height / height
            ]
            let action = VisualAction(
                type: .highlight,
                screenId: screenId,
                x: nil,
                y: nil,
                points: nil,
                center: nil,
                radius: nil,
                rect: normalized,
                label: result.elementLabel,
                ttlMs: 6000
            )
            return VisualActionParser.validate(action).map { [$0] } ?? []
        case .scribble(let points):
            let normalized = points.map { point in
                [Double(point.x) / width, Double(point.y) / height]
            }
            let action = VisualAction(
                type: .polyline,
                screenId: screenId,
                x: nil,
                y: nil,
                points: normalized,
                center: nil,
                radius: nil,
                rect: nil,
                label: result.elementLabel,
                ttlMs: 6000
            )
            return VisualActionParser.validate(action).map { [$0] } ?? []
        }
    }

    private static func parsePoint(from responseText: String) -> PointingParseResult {
        // Coordinates may be negative: a model pointing at an element near
        // the captured image edge (e.g. a half-offscreen button) can emit a
        // slightly out-of-bounds value, and ScreenCoordinateMath clamps it
        // to the edge. Rejecting the sign would leave the tag unparsed —
        // spoken aloud as raw syntax.
        let pattern = #"\[POINT:(?:none|(-?\d+)\s*,\s*(-?\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(
                in: responseText,
                range: NSRange(responseText.startIndex..., in: responseText)
              ),
              let tagRange = Range(match.range, in: responseText) else {
            return PointingParseResult(
                spokenText: responseText,
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil,
                visualGuidance: nil
            )
        }

        let spokenText = String(responseText[..<tagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(
                spokenText: spokenText,
                coordinate: nil,
                elementLabel: "none",
                screenNumber: nil,
                visualGuidance: nil
            )
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: capturedLabel(in: responseText, match: match, index: 3),
            screenNumber: capturedScreenNumber(in: responseText, match: match, index: 4),
            visualGuidance: nil
        )
    }

    private static func parseRectangle(from responseText: String) -> PointingParseResult? {
        let pattern = #"\[RECT:(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(
                in: responseText,
                range: NSRange(responseText.startIndex..., in: responseText)
              ),
              let tagRange = Range(match.range, in: responseText),
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let widthRange = Range(match.range(at: 3), in: responseText),
              let heightRange = Range(match.range(at: 4), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]),
              let width = Double(responseText[widthRange]),
              let height = Double(responseText[heightRange]) else {
            return nil
        }

        let spokenText = String(responseText[..<tagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let label = capturedLabel(in: responseText, match: match, index: 5)
        return PointingParseResult(
            spokenText: spokenText,
            coordinate: nil,
            elementLabel: label,
            screenNumber: capturedScreenNumber(in: responseText, match: match, index: 6),
            visualGuidance: .rectangle(CGRect(x: x, y: y, width: width, height: height))
        )
    }

    private static func parseScribble(from responseText: String) -> PointingParseResult? {
        let pattern = #"\[SCRIBBLE:([^:\]]+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(
                in: responseText,
                range: NSRange(responseText.startIndex..., in: responseText)
              ),
              let tagRange = Range(match.range, in: responseText),
              let pointsRange = Range(match.range(at: 1), in: responseText) else {
            return nil
        }

        let points = responseText[pointsRange]
            .split(separator: ";")
            .compactMap { rawPair -> CGPoint? in
                let values = rawPair.split(separator: ",", maxSplits: 1).map {
                    Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard values.count == 2, let x = values[0], let y = values[1] else { return nil }
                return CGPoint(x: x, y: y)
            }
        guard points.count >= 2 else { return nil }

        let spokenText = String(responseText[..<tagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PointingParseResult(
            spokenText: spokenText,
            coordinate: nil,
            elementLabel: capturedLabel(in: responseText, match: match, index: 2),
            screenNumber: capturedScreenNumber(in: responseText, match: match, index: 3),
            visualGuidance: .scribble(points)
        )
    }

    private static func capturedLabel(
        in responseText: String,
        match: NSTextCheckingResult,
        index: Int
    ) -> String? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: responseText) else {
            return nil
        }
        let label = String(responseText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    private static func capturedScreenNumber(
        in responseText: String,
        match: NSTextCheckingResult,
        index: Int
    ) -> Int? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: responseText) else {
            return nil
        }
        return Int(responseText[range])
    }
}
