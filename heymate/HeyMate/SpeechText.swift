//
//  SpeechText.swift
//  HeyMate
//
//  Turns a reply into words a voice can say. Models still write markdown now
//  and then, and every voice reads a stray * as "asterisk", so each TTSClient
//  runs its text through here first: emphasis, bullets, headers, fences,
//  tables and link syntax go, URLs shrink to their site, and list lines end
//  as sentences so the voice pauses between them.
//

import Foundation

enum SpeechText {
    static func sanitize(_ text: String) -> String {
        var text = text

        // Fences go, the words inside stay.
        text = replacing(#"(?m)^[ \t]*(```|~~~)[^\n]*$"#, in: text, with: "")
        // ![alt](url) and [text](url) say only their words.
        text = replacing(#"!?\[([^\]\n]*)\]\([^)\n]*\)"#, in: text, with: "$1")
        // A bare URL is said as its site: "github.com", not every slash.
        text = replacing(#"https?://(?:www\.)?([^\s/?#)\]]+)[^\s)\]]*"#, in: text, with: "$1")

        // Line starts: headers, quotes, bullets. Rules and table borders go whole.
        text = replacing(#"(?m)^[ \t]*([-*_=][ \t]*){3,}$"#, in: text, with: "")
        text = replacing(#"(?m)^[ \t]*\|?[ \t]*:?-{2,}:?[ \t]*(\|[ \t]*:?-{2,}:?[ \t]*)*\|?[ \t]*$"#, in: text, with: "")
        text = replacing(#"(?m)^[ \t]*#{1,6}[ \t]+"#, in: text, with: "")
        text = replacing(#"(?m)^[ \t]*(>[ \t]?)+"#, in: text, with: "")
        text = replacing(#"(?m)^[ \t]*[-*+•][ \t]+(\[[ xX]\][ \t]+)?"#, in: text, with: "")
        // Table cells read as a list.
        text = replacing(#"(?m)^[ \t]*\|(.*)\|[ \t]*$"#, in: text, with: "$1")
        text = replacing(#"[ \t]*\|[ \t]*"#, in: text, with: ", ")

        // Symbols worth saying as words.
        text = replacing(#"(\d)[ \t]*\*[ \t]*(\d)"#, in: text, with: "$1 times $2")
        text = replacing(#"#(\d)"#, in: text, with: "number $1")
        text = replacing(#"[ \t]*&[ \t]*"#, in: text, with: " and ")

        // Whatever markdown is left is only noise to the ear.
        text = replacing(#"[*`#]+|~~"#, in: text, with: "")
        text = replacing(#"_+"#, in: text, with: " ")
        text = removingEmoji(text)

        // Each line ends as a sentence, so list items get their own pause.
        let lines = text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) }
            .filter { line in line.contains { $0.isLetter || $0.isNumber } }
            .map { line in
                guard let last = line.last, !".!?:;,".contains(last) else { return line }
                return line + "."
            }
        return lines.joined(separator: " ")
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    private static func removingEmoji(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            let isPictograph = properties.isEmojiPresentation
                || (properties.isEmoji && scalar.value > 0x2100)
            // Joiners and variation selectors only glue emoji together.
            let isEmojiGlue = scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value)
            if !isPictograph && !isEmojiGlue {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
