//
//  ComputerUseTagParser.swift
//  leanring-buddy
//
//  How the model asks for an action.
//
//  Same shape as the existing `[POINT:…]` pointing tags: the model writes
//  a bracketed directive inline in its reply, we lift it out before the
//  text is spoken or shown, and the runtime decides what to do with it.
//  Reusing that mechanism rather than switching the whole chat client to
//  tool-use keeps one parsing path for everything the model can ask the
//  app to do.
//
//  Grammar:
//      [ACT:click:Send]
//      [ACT:type:Hello there]
//      [ACT:key:cmd+s]
//      [ACT:open:Safari]
//      [ACT:scroll:down]
//      [ACT:find:submit button]
//
//  Anything unrecognized is left in the text rather than guessed at — a
//  malformed directive should look wrong to the user, not silently become
//  a different action.
//

import CoreGraphics
import Foundation

nonisolated enum ComputerUseTagParser {

    /// One parsed directive plus the exact substring it came from, so the
    /// caller can strip it out of the spoken text.
    struct ParsedAction: Equatable {
        let action: ComputerUseAction
        let rawTag: String
    }

    static let tagPrefix = "[ACT:"
    static let tagSuffix = "]"

    /// Pull every well-formed `[ACT:…]` directive out of `text`, in order.
    static func parseActions(in text: String) -> [ParsedAction] {
        var results: [ParsedAction] = []
        var searchRange = text.startIndex..<text.endIndex

        while let openRange = text.range(of: tagPrefix, range: searchRange) {
            guard let closeRange = text.range(
                of: tagSuffix,
                range: openRange.upperBound..<text.endIndex
            ) else { break }

            let bodyText = String(text[openRange.upperBound..<closeRange.lowerBound])
            let rawTag = String(text[openRange.lowerBound..<closeRange.upperBound])
            if let action = action(fromTagBody: bodyText) {
                results.append(ParsedAction(action: action, rawTag: rawTag))
            }
            searchRange = closeRange.upperBound..<text.endIndex
        }
        return results
    }

    /// Remove every directive this parser understands, leaving the prose.
    /// Unrecognized `[ACT:…]` text is deliberately left alone.
    static func strippingActionTags(from text: String) -> String {
        var stripped = text
        for parsed in parseActions(in: text) {
            stripped = stripped.replacingOccurrences(of: parsed.rawTag, with: "")
        }
        return stripped
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `verb:argument`. The argument may itself contain colons (a typed
    /// sentence, a URL), so only the FIRST colon separates them.
    static func action(fromTagBody bodyText: String) -> ComputerUseAction? {
        guard let separatorIndex = bodyText.firstIndex(of: ":") else {
            // Argument-less verbs.
            switch bodyText.trimmingCharacters(in: .whitespaces).lowercased() {
            case "screenshot": return .screenshot(displayIndex: nil)
            case "read", "window": return .readFocusedWindow
            default: return nil
            }
        }

        let verb = String(bodyText[bodyText.startIndex..<separatorIndex])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let argument = String(bodyText[bodyText.index(after: separatorIndex)...])
            .trimmingCharacters(in: .whitespaces)
        guard !argument.isEmpty else { return nil }

        switch verb {
        case "click", "press":
            return .clickElement(label: argument)
        case "type":
            return .typeText(argument)
        case "key":
            return .pressKeyCombination(argument)
        case "open":
            return .openApplication(name: argument)
        case "switch", "activate":
            return .activateApplication(name: argument)
        case "find":
            return .listActionableElements(matching: argument)
        case "scroll":
            return scrollAction(forDirection: argument)
        default:
            return nil
        }
    }

    /// Scroll distance in pixels for one directive. Roughly three lines of
    /// text, which is what "scroll down a bit" means to a person.
    static let scrollStepInPixels = 120

    static func scrollAction(forDirection direction: String) -> ComputerUseAction? {
        switch direction.lowercased() {
        case "up": return .scroll(deltaX: 0, deltaY: scrollStepInPixels)
        case "down": return .scroll(deltaX: 0, deltaY: -scrollStepInPixels)
        case "left": return .scroll(deltaX: scrollStepInPixels, deltaY: 0)
        case "right": return .scroll(deltaX: -scrollStepInPixels, deltaY: 0)
        default: return nil
        }
    }
}
