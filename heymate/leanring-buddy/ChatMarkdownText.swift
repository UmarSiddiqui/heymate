//
//  ChatMarkdownText.swift
//  leanring-buddy
//
//  Renders an assistant reply that may carry light markdown: **bold**,
//  *italic*, `inline code`, links, and fenced code blocks. Silent-mode
//  replies are written to be read, so they use this formatting; voice
//  replies contain none of it and render exactly as plain text did.
//
//  Headings render as a short bold line: the reading prompt asks for none,
//  but agent and job replies use them, and raw "## Findings" read as noise.
//  Tables are not supported; a chat column is too narrow.
//

import SwiftUI

nonisolated enum ChatMarkdownSegment: Equatable {
    case prose(String)
    case code(String)
}

nonisolated enum ChatProseBlock: Equatable {
    case body(String)
    case heading(String)
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

    /// Splits prose into runs of body text and single heading lines
    /// ("# ", "## ", ... up to six), with the hashes removed.
    static func proseBlocks(from prose: String) -> [ChatProseBlock] {
        var blocks: [ChatProseBlock] = []
        var bodyLines: [String] = []

        func flushBody() {
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !body.isEmpty { blocks.append(.body(body)) }
            bodyLines = []
        }

        for line in prose.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flushBody()
                let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { blocks.append(.heading(title)) }
            } else {
                bodyLines.append(line)
            }
        }
        flushBody()
        return blocks
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
                    ForEach(Array(ChatMarkdownParser.proseBlocks(from: prose).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .body(let body):
                            Text(ChatMarkdownParser.inlineAttributedString(from: body))
                                .font(DS.Fonts.reading)
                                .foregroundColor(DS.Colors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        case .heading(let title):
                            Text(ChatMarkdownParser.inlineAttributedString(from: title))
                                .font(DS.Fonts.reading.weight(.semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
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
