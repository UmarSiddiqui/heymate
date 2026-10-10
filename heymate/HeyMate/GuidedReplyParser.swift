//
//  GuidedReplyParser.swift
//  HeyMate
//
//  Splits a Talk reply into guidance steps: each sentence run that ends in
//  a [POINT:] / [RECT:] / [SCRIBBLE:] tag becomes one step, so the buddy can
//  point at step one while saying step one, then move on. Also reads the
//  walkthrough tags ([PLAN:a|b|c], [STEP:n], [PLAN:done]) that let a
//  multi-turn walkthrough remember where the user is.
//

import CoreGraphics
import Foundation

nonisolated struct GuidanceStep: Equatable {
    /// The step's words with visual tags removed. May still carry [ACT:…]
    /// directives, which run after the step is spoken.
    let text: String
    /// Where to point or what to draw for this step; nil keeps whatever the
    /// previous step was pointing at.
    let pointing: PointingParseResult?

    /// What the user hears and reads: every control tag removed.
    var displayText: String {
        GuidedReplyParser.strippingControlTags(from: text)
    }

    var pointsSomewhere: Bool {
        guard let pointing else { return false }
        return pointing.coordinate != nil || pointing.visualGuidance != nil
    }
}

nonisolated enum WalkthroughDirective: Equatable {
    /// Start (or replace) a plan. Steps are short imperative phrases.
    case plan([String])
    /// The step being guided in this reply, 1-based.
    case step(Int)
    /// The plan is finished or abandoned.
    case done
}

nonisolated struct GuidedReply: Equatable {
    let steps: [GuidanceStep]
    let walkthroughDirectives: [WalkthroughDirective]

    /// The reply as one passage, visual and walkthrough tags removed.
    /// Other directives ([ACT], [WORK], handoffs) stay for their own parsers.
    var spokenText: String {
        steps.map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// First step that points or draws, for paths that can show only one.
    var firstPointing: PointingParseResult? {
        steps.first(where: \.pointsSomewhere)?.pointing
    }

    var pointingStepCount: Int {
        steps.filter(\.pointsSomewhere).count
    }
}

nonisolated enum GuidedReplyParser {

    private static let visualTagPattern = #"\[(?:POINT|RECT|SCRIBBLE):[^\]]*\]"#
    private static let walkthroughTagPattern = #"\[(?:PLAN|STEP):([^\]]*)\]"#
    private static let anyControlTagPattern = #"\[[A-Z]+:[^\]]*\]"#
    private static let controlTagPrefixes = ["[POINT", "[RECT", "[SCRIBBLE", "[PLAN", "[STEP", "[ACT", "[WORK", "[ASK"]

    static func parse(_ responseText: String) -> GuidedReply {
        let (withoutWalkthrough, directives) = extractWalkthroughDirectives(from: responseText)
        return GuidedReply(
            steps: steps(from: withoutWalkthrough),
            walkthroughDirectives: directives
        )
    }

    /// Text safe to show while a reply is still streaming: complete tags
    /// removed anywhere, and a half-arrived tag at the end dropped.
    static func streamingDisplayText(_ partialText: String) -> String {
        var text = strippingControlTags(from: partialText)
        if let openBracket = text.lastIndex(of: "["), !text[openBracket...].contains("]") {
            let fragment = text[openBracket...].uppercased()
            let isPartialTag = controlTagPrefixes.contains { prefix in
                prefix.hasPrefix(fragment) || fragment.hasPrefix(prefix)
            }
            if isPartialTag {
                text = String(text[..<openBracket])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func strippingControlTags(from text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: anyControlTagPattern,
            with: "",
            options: .regularExpression
        )
        return collapsingWhitespace(stripped)
    }

    // MARK: - Steps

    private static func steps(from text: String) -> [GuidanceStep] {
        guard let regex = try? NSRegularExpression(pattern: visualTagPattern) else {
            return [GuidanceStep(text: collapsingWhitespace(text), pointing: nil)]
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else {
            let trimmed = collapsingWhitespace(text)
            return trimmed.isEmpty ? [] : [GuidanceStep(text: trimmed, pointing: nil)]
        }

        var steps: [GuidanceStep] = []
        var segmentStart = text.startIndex
        for match in matches {
            guard let tagRange = Range(match.range, in: text) else { continue }
            // The tag closes the segment, so the existing trailing-tag parser
            // reads it exactly as it reads a single-point reply.
            var segment = String(text[segmentStart..<tagRange.upperBound])
            segment = movingLeadingDirectives(of: segment, into: &steps)
            let parsed = PointingTagParser.parse(segment)
            let words = collapsingWhitespace(
                parsed.spokenText.replacingOccurrences(
                    of: visualTagPattern,
                    with: "",
                    options: .regularExpression
                )
            )
            let pointsSomewhere = parsed.coordinate != nil || parsed.visualGuidance != nil
            if words.isEmpty, pointsSomewhere, let last = steps.last, !last.pointsSomewhere {
                // A tag with no words of its own belongs to the step before it.
                steps[steps.count - 1] = GuidanceStep(text: last.text, pointing: parsed)
            } else if !words.isEmpty || pointsSomewhere {
                steps.append(GuidanceStep(text: words, pointing: pointsSomewhere ? parsed : nil))
            }
            segmentStart = tagRange.upperBound
        }

        let trailing = collapsingWhitespace(
            movingLeadingDirectives(of: String(text[segmentStart...]), into: &steps)
        )
        if !trailing.isEmpty {
            steps.append(GuidanceStep(text: trailing, pointing: nil))
        }
        return distributingBunchedTags(steps)
    }

    /// Models often write "back goes back, reload reloads, and the star
    /// bookmarks. [POINT:back] [POINT:reload] [POINT:star]". When a step's
    /// words split into exactly as many sentences or clauses as the tags
    /// bunched after it, give each tag its own part so the caption and
    /// voice follow the buddy.
    private static func distributingBunchedTags(_ steps: [GuidanceStep]) -> [GuidanceStep] {
        var result: [GuidanceStep] = []
        var index = 0
        while index < steps.count {
            let head = steps[index]
            var runEnd = index + 1
            while runEnd < steps.count,
                  steps[runEnd].pointsSomewhere,
                  steps[runEnd].displayText.isEmpty,
                  !steps[runEnd].text.contains("[") {
                runEnd += 1
            }
            let partCount = runEnd - index
            guard partCount > 1, head.pointsSomewhere,
                  let parts = splitInto(partCount, head.text) else {
                result.append(head)
                index += 1
                continue
            }
            for (offset, part) in parts.enumerated() {
                result.append(GuidanceStep(text: part, pointing: steps[index + offset].pointing))
            }
            index = runEnd
        }
        return result
    }

    private static func splitInto(_ count: Int, _ text: String) -> [String]? {
        // Directives inside the text make a split ambiguous; leave it whole.
        guard !text.contains("[") else { return nil }
        let separators = [#"(?<=[.!?])\s+"#, #"(?:,|;)\s+"#]
        for separator in separators {
            let parts = text.replacingOccurrences(of: separator, with: "\u{1F}", options: .regularExpression)
                .split(separator: "\u{1F}")
                .map { collapsingWhitespace(String($0)) }
                .filter { !$0.isEmpty }
            if parts.count == count {
                return parts
            }
        }
        return nil
    }

    /// "[POINT:…:send] [ACT:click:Send] now type…" — an [ACT] written right
    /// after a tag acts on that step, not the next one.
    private static func movingLeadingDirectives(of segment: String, into steps: inout [GuidanceStep]) -> String {
        guard let last = steps.last,
              let range = segment.range(of: #"^\s*(?:\[[A-Z]+:[^\]]*\]\s*)+"#, options: .regularExpression) else {
            return segment
        }
        let leading = segment[range].trimmingCharacters(in: .whitespacesAndNewlines)
        // A visual tag here has no words of its own; leave it for the
        // caller, which attaches it to the previous step.
        guard leading.range(of: visualTagPattern, options: .regularExpression) == nil else {
            return segment
        }
        steps[steps.count - 1] = GuidanceStep(text: last.text + " " + leading, pointing: last.pointing)
        return String(segment[range.upperBound...])
    }

    // MARK: - Walkthrough tags

    private static func extractWalkthroughDirectives(from text: String) -> (String, [WalkthroughDirective]) {
        guard let regex = try? NSRegularExpression(pattern: walkthroughTagPattern) else {
            return (text, [])
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        var directives: [WalkthroughDirective] = []
        for match in regex.matches(in: text, range: nsRange) {
            guard let wholeRange = Range(match.range, in: text),
                  let bodyRange = Range(match.range(at: 1), in: text) else { continue }
            let body = text[bodyRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if text[wholeRange].uppercased().hasPrefix("[STEP") {
                if let number = Int(body), number >= 1 {
                    directives.append(.step(number))
                }
            } else if body.lowercased() == "done" || body.lowercased() == "none" {
                directives.append(.done)
            } else {
                let planSteps = body.split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !planSteps.isEmpty {
                    directives.append(.plan(Array(planSteps.prefix(20))))
                }
            }
        }
        let remaining = regex.stringByReplacingMatches(in: text, range: nsRange, withTemplate: "")
        return (remaining, directives)
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([.,!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
