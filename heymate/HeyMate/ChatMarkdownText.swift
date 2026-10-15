//
//  ChatMarkdownText.swift
//  HeyMate
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

/// Word-by-word reveal for a reply that just arrived (see `CueWordReveal`).
/// Hidden words keep their place with a clear color, so the bubble is laid
/// out at its final size from the first frame and nothing reflows.
nonisolated enum ChatWordReveal {

    /// A reply as rendered: prose blocks (body or heading) and code blocks.
    enum Block: Equatable {
        case body(String)
        case heading(String)
        case code(String)
    }

    static func blocks(from text: String) -> [Block] {
        ChatMarkdownParser.segments(from: text).flatMap { segment -> [Block] in
            switch segment {
            case .prose(let prose):
                return ChatMarkdownParser.proseBlocks(from: prose).map { block in
                    switch block {
                    case .body(let body): return .body(body)
                    case .heading(let title): return .heading(title)
                    }
                }
            case .code(let code):
                return [.code(code)]
            }
        }
    }

    /// Words a block counts for. A code block appears whole, as one step.
    static func wordCount(of block: Block) -> Int {
        switch block {
        case .body(let text), .heading(let text):
            return wordCount(in: String(ChatMarkdownParser.inlineAttributedString(from: text).characters))
        case .code:
            return 1
        }
    }

    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func totalWords(in text: String) -> Int {
        blocks(from: text).reduce(0) { $0 + wordCount(of: $1) }
    }

    /// How many words of each block show when `visibleWords` of the whole
    /// reply are showing; nil for a block that shows in full.
    static func budgets(for blocks: [Block], visibleWords: Int?) -> [Int?] {
        guard var remaining = visibleWords else { return blocks.map { _ in nil } }
        return blocks.map { block in
            let count = wordCount(of: block)
            defer { remaining = max(remaining - count, 0) }
            return remaining >= count ? nil : remaining
        }
    }

    /// Character offset where word number `count + 1` starts, or nil when
    /// the text has `count` words or fewer.
    static func hiddenStartOffset(afterWords count: Int, in text: String) -> Int? {
        var words = 0
        var isInsideWord = false
        for (offset, character) in text.enumerated() {
            if character.isWhitespace {
                isInsideWord = false
            } else if !isInsideWord {
                isInsideWord = true
                words += 1
                if words > count { return offset }
            }
        }
        return nil
    }

    /// The text with everything after its first `count` words made clear.
    static func hidingWords(after count: Int, in attributed: AttributedString) -> AttributedString {
        guard let offset = hiddenStartOffset(afterWords: count, in: String(attributed.characters)) else {
            return attributed
        }
        var result = attributed
        let start = result.characters.index(result.startIndex, offsetBy: offset)
        result[start..<result.endIndex].foregroundColor = Color.clear
        return result
    }
}

struct ChatMarkdownText: View {
    let text: String
    /// While a reply reveals word by word, how many words show; nil shows
    /// everything.
    var visibleWordCount: Int? = nil

    var body: some View {
        let blocks = ChatWordReveal.blocks(from: text)
        let budgets = ChatWordReveal.budgets(for: blocks, visibleWords: visibleWordCount)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                let budget = budgets[index]
                switch block {
                case .body(let body):
                    Text(revealed(ChatMarkdownParser.inlineAttributedString(from: body), budget: budget))
                        .font(DS.Fonts.reading)
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let title):
                    Text(revealed(ChatMarkdownParser.inlineAttributedString(from: title), budget: budget))
                        .font(DS.Fonts.reading.weight(.semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
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
                    .opacity(budget == 0 ? 0 : 1)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func revealed(_ attributed: AttributedString, budget: Int?) -> AttributedString {
        guard let budget else { return attributed }
        return ChatWordReveal.hidingWords(after: budget, in: attributed)
    }
}
