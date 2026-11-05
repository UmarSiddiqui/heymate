//
//  OpenUIView.swift
//  HeyMate
//
//  Draws an OpenUI Lang block (see `OpenUILang.swift`) with HeyMate's own
//  matte components. The library is small on purpose: what a chat answer
//  needs to be quicker to read than prose, and nothing a reply could use to
//  look like the app's own chrome.
//
//  Components, with positional arguments:
//    Stack([children]) · Row([children]) · Card([children], "title")
//    Header("title", "subtitle") · TextContent("text", "body|muted|heading")
//    Callout("text", "info|success|warning|error", "title")
//    Table(["column", …], [["cell", …], …]) · Stat("label", "value", "detail", "tone")
//    KeyValue([["key", "value"], …]) · List(["item", …], ordered)
//    Steps(["step" or ["title", "detail"], …]) · Tags(["tag", …]) · Tag("text", "tone")
//    Progress("label", value, max) · CodeBlock("code", "language") · Divider()
//    Button("label", @ToAssistant("message") or @OpenUrl("https://…")) · Link("label", "https://…")
//
//  A name the library does not know shows its text, so a reply never goes
//  blank because the model reached for something else.
//

import SwiftUI

/// What a button in a reply asks the chat to do.
enum ChatReplyAction: Equatable {
    /// Send this text as the user's next message.
    case send(String)
    case open(URL)
}

private struct ChatReplyActionKey: EnvironmentKey {
    static let defaultValue: ((ChatReplyAction) -> Void)? = nil
}

extension EnvironmentValues {
    /// Set by a transcript that can send follow-ups. Without it, buttons
    /// that would send a message are shown disabled; links still open.
    var chatReplyAction: ((ChatReplyAction) -> Void)? {
        get { self[ChatReplyActionKey.self] }
        set { self[ChatReplyActionKey.self] = newValue }
    }
}

struct OpenUIView: View {
    let source: String

    var body: some View {
        if let root = OpenUILangParser.parse(source).root {
            OpenUINode(value: root, depth: 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }
}

private struct OpenUINode: View {
    let value: OpenUIValue
    let depth: Int

    var body: some View {
        switch value {
        case .component(let component):
            OpenUIComponentView(component: component, depth: depth)
        case .array(let items):
            OpenUIChildren(items: items, depth: depth)
        case .string, .number, .bool:
            OpenUIInlineText(text: value.text ?? "")
        default:
            EmptyView()
        }
    }
}

private struct OpenUIChildren: View {
    let items: [OpenUIValue]
    let depth: Int
    var spacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                OpenUINode(value: item, depth: depth + 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OpenUIComponentView: View {
    let component: OpenUIComponent
    let depth: Int

    private var first: String { component.arg(0)?.text ?? "" }

    var body: some View {
        // Deep nesting is a loop or a runaway reply; stop drawing it.
        if depth > 12 {
            EmptyView()
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch component.name {
        case "Stack", "Column":
            OpenUIChildren(items: component.arg(0)?.array ?? [], depth: depth)
        case "Row", "Grid", "Buttons":
            OpenUIRow(items: component.arg(0)?.array ?? [], depth: depth)
        case "Card":
            OpenUICard(title: component.arg(1)?.text, items: component.arg(0)?.array ?? [component.arg(0)].compactMap { $0 }, depth: depth)
        case "Header":
            VStack(alignment: .leading, spacing: 2) {
                OpenUIInlineText(text: first, font: DS.Fonts.title)
                if let subtitle = component.arg(1)?.text {
                    OpenUIInlineText(text: subtitle, font: DS.Fonts.body, color: DS.Colors.textSecondary)
                }
            }
        case "TextContent", "Text":
            OpenUITextContent(text: first, variant: component.arg(1)?.text ?? "body")
        case "Callout":
            OpenUICallout(text: first, tone: OpenUITone(component.arg(1)?.text), title: component.arg(2)?.text)
        case "Table":
            OpenUITable(columns: OpenUIPlainText.texts(component.arg(0)), rows: OpenUIPlainText.cells(component.arg(1)))
        case "Stat":
            OpenUIStat(label: first, value: component.arg(1)?.text ?? "",
                       detail: component.arg(2)?.text, tone: component.arg(3)?.text.map(OpenUITone.init))
        case "KeyValue":
            OpenUIKeyValue(rows: OpenUIPlainText.cells(component.arg(0)))
        case "List":
            OpenUIList(items: OpenUIPlainText.texts(component.arg(0)), isOrdered: component.arg(1)?.bool ?? false)
        case "Steps":
            OpenUISteps(items: component.arg(0)?.array ?? [])
        case "Tags":
            OpenUITags(items: OpenUIPlainText.texts(component.arg(0)).map { ($0, OpenUITone.neutral) })
        case "Tag":
            OpenUITags(items: [(first, OpenUITone(component.arg(1)?.text))])
        case "Progress":
            OpenUIProgressBar(label: first, fraction: OpenUIProgress.fraction(component),
                              percent: OpenUIProgress.percentText(component))
        case "CodeBlock", "Code":
            ChatCodeBlock(code: first)
        case "Divider", "Separator":
            Rectangle().fill(DS.Colors.hairline).frame(height: 1).padding(.vertical, 2)
        case "Button":
            OpenUIButton(label: first, action: component.arg(1), isPrimary: component.arg(2)?.text == "primary")
        case "Link":
            OpenUIButton(label: first, action: component.arg(1).map { .action(OpenUIComponent(name: "OpenUrl", args: [$0])) },
                         isPrimary: false)
        default:
            // Unknown: show what it says rather than nothing.
            OpenUIChildren(items: component.args.filter { !$0.isNull }, depth: depth)
        }
    }
}

// MARK: - Tone

private enum OpenUITone {
    case neutral, info, success, warning, error

    init(_ name: String?) {
        switch name?.lowercased() {
        case "info", "note", "tip": self = .info
        case "success", "positive", "good", "up": self = .success
        case "warning", "caution", "warn": self = .warning
        case "error", "danger", "negative", "bad", "down": self = .error
        default: self = .neutral
        }
    }

    var color: Color {
        switch self {
        case .neutral: return DS.Colors.textSecondary
        case .info: return DS.Colors.info
        case .success: return DS.Colors.success
        case .warning: return DS.Colors.warningText
        case .error: return DS.Colors.destructiveText
        }
    }

    var symbol: String {
        switch self {
        case .neutral, .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

// MARK: - Pieces

private struct OpenUIInlineText: View {
    let text: String
    var font: Font = DS.Fonts.reading
    var color: Color = DS.Colors.textPrimary

    var body: some View {
        Text(ChatMarkdownParser.inlineAttributedString(from: text))
            .font(font)
            .foregroundColor(color)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct OpenUITextContent: View {
    let text: String
    let variant: String

    var body: some View {
        switch variant.lowercased() {
        case "heading", "title":
            OpenUIInlineText(text: text, font: DS.Fonts.reading.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        case "muted", "secondary", "caption":
            OpenUIInlineText(text: text, font: DS.Fonts.body, color: DS.Colors.textSecondary)
        default:
            OpenUIInlineText(text: text)
        }
    }
}

/// The shared well every block sits in: a step lighter than the reply,
/// with a hairline edge.
private struct OpenUIWell: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .strokeBorder(DS.Colors.hairline, lineWidth: 1)
            )
    }
}

private struct OpenUICard: View {
    let title: String?
    let items: [OpenUIValue]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            OpenUIChildren(items: items, depth: depth)
        }
        .modifier(OpenUIWell())
    }
}

private struct OpenUIRow: View {
    let items: [OpenUIValue]
    let depth: Int

    private var isAllStats: Bool {
        !items.isEmpty && items.allSatisfy {
            if case .component(let component) = $0 { return component.name == "Stat" }
            return false
        }
    }

    var body: some View {
        if isAllStats {
            // Stats share the row evenly, wrapping into a grid when narrow.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        OpenUINode(value: item, depth: depth + 1)
                            .frame(minWidth: 128, maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10, alignment: .topLeading)],
                          alignment: .leading, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        OpenUINode(value: item, depth: depth + 1)
                    }
                }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) { children }
                VStack(alignment: .leading, spacing: 8) { children }
            }
        }
    }

    @ViewBuilder private var children: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            OpenUINode(value: item, depth: depth + 1)
        }
    }
}

private struct OpenUICallout: View {
    let text: String
    let tone: OpenUITone
    let title: String?

    var body: some View {
        let tint = tone == .neutral ? DS.Colors.textSecondary : tone.color
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: tone.symbol)
                .font(DS.Glyph.regular)
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title).font(DS.Fonts.headline).foregroundColor(DS.Colors.textPrimary)
                }
                OpenUIInlineText(text: text, font: DS.Fonts.bodyLarge)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(tint.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
    }
}

private struct OpenUITable: View {
    let columns: [String]
    let rows: [[String]]
    @State private var isHovered = false

    private var width: Int { max(columns.count, rows.map(\.count).max() ?? 0) }

    /// A column whose every cell reads as a number lines up on the right.
    private func isNumeric(_ column: Int) -> Bool {
        let cells = rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }.filter { !$0.isEmpty }
        return !cells.isEmpty && cells.allSatisfy { cell in
            cell.range(of: #"^[\s$€£¥+\-−]*[\d.,]+\s*(%|[kKmMbB]|x)?$"#, options: .regularExpression) != nil
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                if !columns.isEmpty {
                    GridRow {
                        ForEach(0..<width, id: \.self) { index in
                            Text(index < columns.count ? columns[index] : "")
                                .font(DS.Fonts.sectionLabel)
                                .foregroundColor(DS.Colors.textSecondary)
                                .gridColumnAlignment(isNumeric(index) ? .trailing : .leading)
                                .padding(.vertical, 9)
                        }
                    }
                    Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<width, id: \.self) { index in
                            Text(ChatMarkdownParser.inlineAttributedString(from: index < row.count ? row[index] : ""))
                                .font(isNumeric(index) ? DS.Fonts.bodyLarge.monospacedDigit() : DS.Fonts.bodyLarge)
                                .foregroundColor(index == 0 ? DS.Colors.textPrimary : DS.Colors.textPrimary.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 260, alignment: isNumeric(index) ? .trailing : .leading)
                                .padding(.vertical, 8)
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Rectangle().fill(DS.Colors.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(DS.Colors.hairline, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            // Tab-separated, so it pastes into Numbers or Sheets as cells.
            ChatCopyButton(label: "Copy table") {
                OpenUIPlainText.tabSeparated(columns: columns, rows: rows)
            }
            .padding(4)
            .opacity(isHovered ? 1 : 0)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
    }
}

private struct OpenUIStat: View {
    let label: String
    let value: String
    let detail: String?
    let tone: OpenUITone?

    private var detailTone: OpenUITone {
        if let tone { return tone }
        guard let detail = detail?.trimmingCharacters(in: .whitespaces) else { return .neutral }
        if detail.hasPrefix("+") || detail.hasPrefix("↑") { return .success }
        if detail.hasPrefix("-") || detail.hasPrefix("−") || detail.hasPrefix("↓") { return .error }
        return .neutral
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
            Text(value)
                .font(DS.Fonts.numericLarge)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(DS.Fonts.caption.weight(.medium))
                    .foregroundColor(detailTone.color)
                    .lineLimit(2)
            }
        }
        .textSelection(.enabled)
        .modifier(OpenUIWell(padding: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct OpenUIKeyValue: View {
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.first ?? "")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                    OpenUIInlineText(text: row.dropFirst().joined(separator: " "), font: DS.Fonts.bodyLarge)
                }
            }
        }
        .textSelection(.enabled)
        .modifier(OpenUIWell(padding: 12))
    }
}

private struct OpenUIList: View {
    let items: [String]
    let isOrdered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(isOrdered ? "\(index + 1)." : "•")
                        .font(DS.Fonts.reading)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(minWidth: 14, alignment: .trailing)
                    OpenUIInlineText(text: item)
                }
            }
        }
    }
}

private struct OpenUISteps: View {
    let items: [OpenUIValue]

    private func parts(_ item: OpenUIValue) -> (String, String?) {
        if let pair = item.array { return (pair.first?.text ?? "", pair.dropFirst().first?.text) }
        return (item.text ?? "", nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let (title, detail) = parts(item)
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Text("\(index + 1)")
                            .font(DS.Fonts.keycap.monospacedDigit())
                            .foregroundColor(DS.Colors.textPrimary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(DS.Colors.surface3))
                            .overlay(Circle().strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
                        if index < items.count - 1 {
                            Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        OpenUIInlineText(text: title, font: DS.Fonts.reading.weight(.medium))
                        if let detail {
                            OpenUIInlineText(text: detail, font: DS.Fonts.body, color: DS.Colors.textSecondary)
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, index < items.count - 1 ? 14 : 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OpenUITags: View {
    let items: [(String, OpenUITone)]

    var body: some View {
        OpenUIFlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let tint = item.1 == .neutral ? DS.Colors.textPrimary : item.1.color
                Text(item.0)
                    .font(DS.Fonts.control)
                    .foregroundColor(tint)
                    .padding(.horizontal, 10)
                    .frame(height: DS.ControlSize.small)
                    .background(Capsule().fill(item.1 == .neutral ? DS.Colors.surface3 : tint.opacity(0.14)))
            }
        }
    }
}

private struct OpenUIProgressBar: View {
    let label: String
    let fraction: Double
    let percent: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(DS.Fonts.body).foregroundColor(DS.Colors.textSecondary)
                Spacer(minLength: 8)
                Text(percent).font(DS.Fonts.numeric).foregroundColor(DS.Colors.textPrimary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.surface3)
                    Capsule().fill(DS.Colors.accent).frame(width: max(6, proxy.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(percent)")
    }
}

private struct OpenUIButton: View {
    let label: String
    let action: OpenUIValue?
    let isPrimary: Bool
    @Environment(\.chatReplyAction) private var chatReplyAction

    private var replyAction: ChatReplyAction? {
        switch action {
        case .action(let component):
            let argument = component.arg(0)?.text ?? ""
            switch component.name {
            case "OpenUrl", "OpenURL", "Open":
                return URL(string: argument).flatMap { ["http", "https", "mailto"].contains($0.scheme?.lowercased() ?? "") ? .open($0) : nil }
            default:
                // @ToAssistant and anything else that carries words: send them.
                return argument.isEmpty ? .send(label) : .send(argument)
            }
        case .string(let text):
            return .send(text)
        default:
            return .send(label)
        }
    }

    /// Links always open; a message needs a transcript that can send it.
    private var isActionable: Bool {
        switch replyAction {
        case .open: return true
        case .send: return chatReplyAction != nil
        case nil: return false
        }
    }

    var body: some View {
        let resolved = replyAction
        Button {
            switch resolved {
            case .open(let url): NSWorkspace.shared.open(url)
            case .send(let text): chatReplyAction?(.send(text))
            case nil: break
            }
        } label: {
            HStack(spacing: 5) {
                Text(label)
                if case .open = resolved {
                    Image(systemName: "arrow.up.right").font(DS.Glyph.micro)
                }
            }
        }
        .buttonStyle(DSCapsuleButtonStyle(role: isPrimary ? .primary : .secondary))
        .disabled(!isActionable)
        .pointerCursor()
        .help(helpText(resolved))
    }

    private func helpText(_ action: ChatReplyAction?) -> String {
        switch action {
        case .open(let url): return url.absoluteString
        case .send(let text): return "Send “\(text)”"
        case nil: return label
        }
    }
}

/// Lays children out left to right, wrapping to a new line when full.
private struct OpenUIFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, x) in zip(row.indices, row.xs) {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Line { var indices: [Int] = []; var xs: [CGFloat] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [Line()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var line = lines[lines.count - 1]
            if !line.indices.isEmpty, line.width + spacing + size.width > width {
                let y = line.y + line.height + spacing
                lines.append(Line(y: y))
                line = lines[lines.count - 1]
            }
            let x = line.indices.isEmpty ? 0 : line.width + spacing
            line.indices.append(index)
            line.xs.append(x)
            line.width = x + size.width
            line.height = max(line.height, size.height)
            lines[lines.count - 1] = line
        }
        return lines.filter { !$0.indices.isEmpty }
    }
}
