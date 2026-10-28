//
//  NoteMarkdownView.swift
//  HeyMate
//
//  A note the agent keeps with ReferenceRenderer's note tools, shown as a page: its
//  title, the answer line with its one big number, the plan boxes (the one
//  it is on now marked), options it ruled out crossed through with the
//  reason, tables and text. HeyMate's own SwiftUI; read-only, and it
//  updates as the agent writes.
//

import SwiftUI

struct NoteMarkdownView: View {
    let markdown: String

    /// The first line worth showing in the list: the answer, else the first plain line.
    static func previewLine(_ markdown: String) -> String? {
        let lines = markdown.split(separator: "\n").map(String.init)
        if let answer = lines.first(where: { $0.hasPrefix("> ") }) { return clean(String(answer.dropFirst(2))) }
        return lines.first { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(clean)
    }

    /// The note language's markers ({now}, {out}, {big="…"}) are for the page, not the words.
    static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: #"\s*\{[a-z]+(?:="[^"]*")?(?:\s+[a-z]+="[^"]*")*\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func attribute(_ line: String, _ key: String) -> String? {
        guard let range = line.range(of: #"\#(key)="([^"]*)""#, options: .regularExpression) else { return nil }
        return String(line[range]).components(separatedBy: "\"").dropFirst().first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                    row(String(raw))
                }
            }
            .padding(DS.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed.hasPrefix("# ") {
            Text(Self.clean(String(trimmed.dropFirst(2)))).font(.system(size: 22, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
        } else if trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
            Text(Self.clean(trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                .font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).padding(.top, DS.Spacing.sm)
        } else if trimmed.hasPrefix("> ") {
            answer(trimmed)
        } else if let box = trimmed.range(of: #"^[-*]\s+\[([ xX])\]\s+"#, options: .regularExpression) {
            let done = trimmed[box].contains { $0 == "x" || $0 == "X" }
            let now = trimmed.contains("{now}")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.square.fill" : (now ? "arrow.right.square" : "square"))
                    .foregroundColor(done || now ? DS.Colors.accent : DS.Colors.textTertiary)
                Text(Self.clean(String(trimmed[box.upperBound...])))
                    .foregroundColor(done ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                    .fontWeight(now ? .semibold : .regular)
            }
        } else if trimmed.hasPrefix("|") {
            if !trimmed.replacingOccurrences(of: #"[|\s:-]"#, with: "", options: .regularExpression).isEmpty {
                let out = trimmed.contains("{out}")
                HStack(spacing: DS.Spacing.md) {
                    ForEach(Array(trimmed.split(separator: "|").map { Self.clean(String($0)) }.filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, cell in
                        Text(cell).strikethrough(out).frame(minWidth: 80, alignment: .leading)
                    }
                }
                .font(.system(size: 13)).foregroundColor(out ? DS.Colors.textTertiary : DS.Colors.textPrimary)
            }
        } else if trimmed.contains("{out}") {
            // An option ruled out: crossed through, its reason after the dash.
            let parts = Self.clean(trimmed.replacingOccurrences(of: #"^[-*]\s+"#, with: "", options: .regularExpression))
                .components(separatedBy: " — ")
            HStack(spacing: 6) {
                Text(parts[0]).strikethrough().foregroundColor(DS.Colors.textTertiary)
                if parts.count > 1 { Text(parts.dropFirst().joined(separator: " — ")).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary) }
            }
        } else {
            Text((try? AttributedString(markdown: Self.clean(line), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(Self.clean(line)))
                .foregroundColor(DS.Colors.textPrimary)
        }
    }

    /// The answer line: the line itself, its one big number or name, and a short aside.
    private func answer(_ line: String) -> some View {
        HStack(alignment: .center, spacing: DS.Spacing.md) {
            if let big = Self.attribute(line, "big") {
                Text(big).font(.system(size: 28, weight: .bold)).foregroundColor(DS.Colors.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.clean(String(line.dropFirst(2)))).font(.system(size: 15, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                if let aside = Self.attribute(line, "note") {
                    Text(aside).font(.system(size: 12)).foregroundColor(DS.Colors.accent)
                }
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.accent.opacity(0.08)))
    }
}
