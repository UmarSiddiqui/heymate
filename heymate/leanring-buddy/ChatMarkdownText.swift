//
//  ChatMarkdownText.swift
//  leanring-buddy
//
//  Renders an assistant reply that may carry light markdown: **bold**,
//  *italic*, `inline code`, links, and fenced code blocks. Silent-mode
//  replies are written to be read, so they use this formatting; voice
//  replies contain none of it and render exactly as plain text did.
//
//  Headings and tables are deliberately not supported — the reading prompt
//  asks the model not to produce them, and a chat bubble is too narrow.
//

import SwiftUI

nonisolated enum ChatMarkdownSegment: Equatable {
    case prose(String)
    case code(String)
}

nonisolated enum ChatMarkdownParser {

    /// Splits text on ``` fences. A fence still open at the end — common
    /// mid-stream — treats the rest as code, so a block does not flash as
    /// prose and then jump to code when its closing fence arrives.
    static func segments(from text: String) -> [ChatMarkdownSegment] {
        var segments: [ChatMarkdownSegment] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var isInsideCodeBlock = false

        func flushProse() {
            let prose = proseLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !prose.isEmpty { segments.append(.prose(prose)) }
            proseLines = []
        }

        func flushCode() {
            segments.append(.code(codeLines.joined(separator: "\n")))
            codeLines = []
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if isInsideCodeBlock {
                    flushCode()
                } else {
                    flushProse()
                }
                isInsideCodeBlock.toggle()
                continue
            }
            if isInsideCodeBlock {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }

        if isInsideCodeBlock {
            flushCode()
        } else {
            flushProse()
        }
        return segments
    }

    /// Inline markdown with line breaks kept. Falls back to the raw text if
    /// the markdown does not parse, so a stray asterisk never hides a reply.
    static func inlineAttributedString(from prose: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: prose, options: options)) ?? AttributedString(prose)
    }
}

struct ChatMarkdownText: View {
    let text: String

    var body: some View {
        let segments = ChatMarkdownParser.segments(from: text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(ChatMarkdownParser.inlineAttributedString(from: prose))
                        .font(DS.Fonts.reading)
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(DS.Fonts.code)
                            .foregroundColor(DS.Colors.textPrimary)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                }
            }
        }
        .textSelection(.enabled)
    }
}
