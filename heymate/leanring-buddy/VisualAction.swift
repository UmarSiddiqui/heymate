//
//  VisualAction.swift
//  leanring-buddy
//
//  Structured visual-action layer (master spec FR-4/FR-5): models may emit a
//  JSON "visualActions" block describing normalized 0…1 drawings instead of
//  (or alongside) the legacy [POINT:x,y:label:screenN] tag. The parser pulls
//  the JSON out of the response text so it is never spoken aloud; the
//  resolver converts normalized geometry into per-display overlay-local
//  points (top-left origin, y down — same convention as BlueCursorView).
//

import CoreGraphics
import Foundation

/// One drawing/pointing instruction from the model. All coordinates are
/// normalized 0…1 relative to the target display's size, top-left origin.
struct VisualAction: Equatable {
    enum Kind: String, CaseIterable {
        case point
        case arrow
        case circle
        case roundedRect
        case polygon
        case polyline
        case highlight
        case caption
        case clear
    }

    let type: Kind
    /// e.g. "screen1". Nil means the cursor screen.
    let screenId: String?
    /// point/caption anchor, normalized.
    let x: Double?
    let y: Double?
    /// polygon/polyline vertices, or arrow [start, end], normalized.
    let points: [[Double]]?
    /// circle center, normalized.
    let center: [Double]?
    /// circle radii [rx, ry] normalized.
    let radius: [Double]?
    /// roundedRect/highlight [x, y, w, h] normalized.
    let rect: [Double]?
    let label: String?
    /// Optional per-action lifetime in milliseconds.
    let ttlMs: Int?
}

enum VisualActionParser {

    /// Extracts a {"visualActions": [...]} JSON block from model output.
    /// Returns the response text with the block removed (safe to speak)
    /// plus the decoded, validated actions. Text that merely mentions the
    /// key but isn't valid JSON passes through untouched.
    static func extract(from responseText: String) -> (spokenText: String, actions: [VisualAction]) {
        guard let (json, blockRange) = jsonBlock(in: responseText) else {
            return (responseText, [])
        }

        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(WireEnvelope.self, from: data),
              let wireActions = wire.visualActions else {
            // Not parseable as an action block — leave the text alone.
            return (responseText, [])
        }

        var cleanedText = String(responseText[..<blockRange.lowerBound])
            + String(responseText[blockRange.upperBound...])
        cleanedText = cleanedText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let actions = wireActions.map { validate(decode($0)) }.compactMap { $0 }
        return (cleanedText, actions)
    }

    /// Locates the last balanced JSON object containing "visualActions".
    private static func jsonBlock(in text: String) -> (json: String, range: Range<String.Index>)? {
        guard let keyRange = text.range(of: #"\"visualActions\""#, options: .regularExpression) else {
            return nil
        }

        // Walk backwards from the key to the opening brace of its object.
        guard let openBrace = text[..<keyRange.lowerBound].lastIndex(of: "{") else {
            return nil
        }

        // Walk forward tracking brace depth to the matching close.
        var depth = 0
        var index = openBrace
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    let range = openBrace..<text.index(after: index)
                    return (String(text[range]), range)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private struct WireEnvelope: Decodable {
        let visualActions: [WireAction]?
    }

    private struct WireAction: Decodable {
        let type: String
        let screenId: String?
        let x: Double?
        let y: Double?
        let points: [[Double]]?
        let center: [Double]?
        let radius: [Double]?
        let rect: [Double]?
        let label: String?
        let ttlMs: Int?
    }

    private static func decode(_ action: WireAction) -> VisualAction {
        VisualAction(
            type: VisualAction.Kind(rawValue: action.type.lowercased()) ?? .point,
            screenId: action.screenId,
            x: action.x,
            y: action.y,
            points: action.points,
            center: action.center,
            radius: action.radius,
            rect: action.rect,
            label: action.label,
            ttlMs: action.ttlMs
        )
    }

    /// Clamps normalized values into 0…1 and drops malformed actions so a
    /// hallucinated shape can never render off-screen or crash the renderer.
    static func validate(_ action: VisualAction) -> VisualAction? {
        let clamped: (Double) -> Double = { min(max($0, 0), 1) }

        let points = action.points?.map { row in row.map(clamped) }
        let center = action.center?.map(clamped)
        let radius = action.radius?.map(clamped)
        let rect = action.rect?.map(clamped)

        let hasAnchor = action.x != nil && action.y != nil

        switch action.type {
        case .point, .caption:
            guard hasAnchor || (center?.count == 2) else { return nil }
        case .arrow, .polyline:
            guard let points, points.count >= 2, points.allSatisfy({ $0.count == 2 }) else { return nil }
        case .polygon:
            guard let points, points.count >= 3, points.allSatisfy({ $0.count == 2 }) else { return nil }
        case .circle:
            guard center?.count == 2, radius?.count == 2 else { return nil }
        case .roundedRect, .highlight:
            guard let rect, rect.count == 4, rect[2] > 0.001, rect[3] > 0.001 else { return nil }
        case .clear:
            break
        }

        return VisualAction(
            type: action.type,
            screenId: action.screenId,
            x: action.x.map(clamped),
            y: action.y.map(clamped),
            points: points,
            center: center,
            radius: radius,
            rect: rect,
            label: action.label,
            ttlMs: action.ttlMs
        )
    }
}

/// A validated visual action resolved into concrete overlay-local geometry
/// (points, y down, same coordinate space BlueCursorView positions in).
struct ResolvedAnnotation: Equatable, Identifiable {
    let id: UUID
    let kind: VisualAction.Kind
    /// AppKit global frame of the display this annotation belongs to.
    let screenFrame: CGRect
    let points: [CGPoint]
    let center: CGPoint
    let radius: CGSize
    let rect: CGRect
    let label: String?
    let expiresAt: Date
}

enum VisualActionResolver {

    struct ScreenGeometryInfo {
        /// Stable id exposed to the model, e.g. "screen1".
        let id: String
        /// AppKit global frame of the display.
        let frame: CGRect
        let isCursorScreen: Bool
    }

    static let defaultTTL: TimeInterval = 6

    /// Converts normalized actions into per-screen annotations. Unknown
    /// screenIds fall back to the cursor screen; "clear" actions are handled
    /// by the caller (they remove prior annotations instead of rendering).
    static func resolve(
        _ actions: [VisualAction],
        screens: [ScreenGeometryInfo],
        now: Date = Date(),
        defaultTTL: TimeInterval = defaultTTL
    ) -> [ResolvedAnnotation] {
        let cursorScreen = screens.first(where: { $0.isCursorScreen }) ?? screens.first

        func screen(for action: VisualAction) -> ScreenGeometryInfo? {
            guard let screenId = action.screenId?.lowercased() else { return cursorScreen }
            if let exact = screens.first(where: { $0.id.lowercased() == screenId }) {
                return exact
            }
            // Accept "1", "screen 1", "SCREEN2" style variants.
            let digits = screenId.filter(\.isNumber)
            // Unknown ids fall back to the cursor screen rather than
            // silently dropping the model's visual.
            return screens.first(where: { $0.id.lowercased() == "screen\(digits)" }) ?? cursorScreen
        }

        func localPoint(_ pair: [Double], in frame: CGRect) -> CGPoint {
            CGPoint(x: CGFloat(pair[0]) * frame.width, y: CGFloat(pair[1]) * frame.height)
        }

        var resolved: [ResolvedAnnotation] = []

        for action in actions where action.type != .clear {
            guard let screen = screen(for: action) else { continue }
            let frame = screen.frame
            let ttl = action.ttlMs.map { TimeInterval($0) / 1000.0 } ?? defaultTTL
            let expiresAt = now.addingTimeInterval(max(ttl, 1))

            let annotationPoints = (action.points ?? []).map { localPoint($0, in: frame) }
            let annotationCenter: CGPoint
            if let center = action.center, center.count == 2 {
                annotationCenter = localPoint(center, in: frame)
            } else if let x = action.x, let y = action.y {
                annotationCenter = CGPoint(x: CGFloat(x) * frame.width, y: CGFloat(y) * frame.height)
            } else {
                annotationCenter = .zero
            }
            let annotationRadius: CGSize
            if let radius = action.radius, radius.count == 2 {
                annotationRadius = CGSize(width: CGFloat(radius[0]) * frame.width,
                                         height: CGFloat(radius[1]) * frame.height)
            } else {
                annotationRadius = .zero
            }
            let annotationRect: CGRect
            if let rect = action.rect, rect.count == 4 {
                annotationRect = CGRect(
                    x: CGFloat(rect[0]) * frame.width,
                    y: CGFloat(rect[1]) * frame.height,
                    width: CGFloat(rect[2]) * frame.width,
                    height: CGFloat(rect[3]) * frame.height
                )
            } else {
                annotationRect = .zero
            }

            resolved.append(ResolvedAnnotation(
                id: UUID(),
                kind: action.type,
                screenFrame: frame,
                points: annotationPoints,
                center: annotationCenter,
                radius: annotationRadius,
                rect: annotationRect,
                label: action.label,
                expiresAt: expiresAt
            ))
        }

        return resolved
    }

    /// Applies an ordered action list to existing annotations — a "clear"
    /// removes everything rendered before it, later shapes draw on top.
    static func apply(
        _ actions: [VisualAction],
        to existing: [ResolvedAnnotation],
        screens: [ScreenGeometryInfo],
        now: Date = Date()
    ) -> [ResolvedAnnotation] {
        var result = existing
        for action in actions {
            if action.type == .clear {
                result.removeAll()
                continue
            }
            result.append(contentsOf: resolve([action], screens: screens, now: now))
        }
        return result
    }
}
