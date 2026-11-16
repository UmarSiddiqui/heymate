//
//  MateSettingsKit.swift
//  HeyMate
//
//  Small pieces the agent settings panes share: the context every pane gets,
//  the search anchor and reveal highlight, a text-field row, and a link row.
//  Everything else comes from SettingsComponents, so a switch here looks and
//  behaves like one in the app settings window.
//

import SwiftUI

/// What a pane needs: the mate (always read live), the manager, and how to
/// leave for a desktop page or close the sheet.
struct MateSettingsContext {
    let mateID: UUID
    let fallback: Mate
    let companionManager: CompanionManager
    let openDesktopSection: (DesktopSection) -> Void
    let close: () -> Void
    let onSave: (String, String, String, String?) -> String?
    let onDelete: () -> Void

    @MainActor var mate: Mate { companionManager.mates.first { $0.id == mateID } ?? fallback }
}

private struct MateSettingsAnchorModifier: ViewModifier {
    let anchor: String
    @Environment(\.settingsHighlightedItemID) private var highlighted

    func body(content: Content) -> some View {
        content
            .background(
                Rectangle()
                    .fill(highlighted == anchor ? DS.Colors.revealHighlight : Color.clear)
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: DS.Animation.normal), value: highlighted == anchor)
            .id(anchor)
    }
}

extension View {
    /// Scroll target and highlight surface for one searchable agent setting.
    func mateSettingsAnchor(_ anchor: String) -> some View {
        modifier(MateSettingsAnchorModifier(anchor: anchor))
    }
}

/// A title over help text, with a full-width field under it inside the card.
struct MateSettingsFieldRow: View {
    let title: String
    var subtitle: String?
    let placeholder: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 1...1

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SettingsRowLabel(title: title, subtitle: subtitle)
            TextField(placeholder, text: $text, axis: lines.upperBound > 1 ? .vertical : .horizontal)
                .lineLimit(lines)
                .settingsFieldChrome()
                .padding(.vertical, lines.upperBound > 1 ? 6 : 0)
                .accessibilityLabel(title)
                .accessibilityHint(subtitle ?? "")
        }
        .padding(.horizontal, DS.SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, DS.SettingsLayout.rowVerticalPadding)
    }
}

/// A plain link out of the sheet ("Everything HeyMate remembers").
struct MateSettingsLinkRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.md) {
                SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .settingsRowInsets()
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
    }
}

/// Runs `save` once typing settles, so a field saves as it's changed
/// without writing on every keystroke. Flush runs it at once.
@MainActor
final class MateSettingsDebouncer {
    private var task: Task<Void, Never>?
    private var pending: (() -> Void)?

    func schedule(after delay: Duration = .milliseconds(600), _ save: @escaping () -> Void) {
        task?.cancel()
        pending = save
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        let save = pending
        pending = nil
        save?()
    }
}

/// Minute-of-day choices in half-hour steps, for quiet hours.
enum MateSettingsClock {
    static var halfHours: [DSMenuOption<Int>] {
        stride(from: 0, to: MateQuietHours.minutesPerDay, by: 30).map {
            DSMenuOption(value: $0, title: MateQuietHours.clockText($0))
        }
    }

    /// Adds `value` when it isn't on a half hour, so a saved time always shows.
    static func options(including value: Int) -> [DSMenuOption<Int>] {
        var options = halfHours
        if !options.contains(where: { $0.value == value }) {
            options.append(DSMenuOption(value: value, title: MateQuietHours.clockText(value)))
            options.sort { $0.value < $1.value }
        }
        return options
    }
}
