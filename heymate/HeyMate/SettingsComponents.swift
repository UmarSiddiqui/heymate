//
//  SettingsComponents.swift
//  HeyMate
//
//  The settings kit. Every settings page is built from these pieces and
//  nothing else, so a switch, a menu, or a "Remove" button looks and
//  behaves the same on every page:
//
//    SettingsPage        page title, subtitle, scrolling column, search reveal
//    SettingsSection     sentence-case header, one matte card, optional footer
//    SettingsRow         title + help text + trailing control (the base row)
//    SettingsToggleRow   a row whose control is the HeyMate switch
//    SettingsPickerRow   a row whose control is a HeyMate menu
//    SettingsDestructiveRow  a red action that always asks first
//    SettingsSecretKeyRow    paste / replace / remove a stored key
//    SettingsStatusBadge, SettingsInlineHelp, SettingsNotice
//    DSSwitchToggleStyle, DSSegmentedControl, DSMenuPicker
//
//  Built only on DS tokens. HIG structure — grouped rows, label left and
//  control right, help text under the label, destructive actions last and
//  confirmed — drawn in HeyMate's own matte style rather than Form chrome.
//

import AppKit
import SwiftUI

// MARK: - Reveal highlight plumbing

/// The row search just jumped to, as its anchor id. A plain value in the
/// environment so rows can read it without an environment object that
/// would crash if a row were ever placed outside a settings page.
private nonisolated struct SettingsHighlightedItemKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    nonisolated var settingsHighlightedItemID: String? {
        get { self[SettingsHighlightedItemKey.self] }
        set { self[SettingsHighlightedItemKey.self] = newValue }
    }
}

private struct SettingsAnchorModifier: ViewModifier {
    let item: SettingsItem?
    @Environment(\.settingsHighlightedItemID) private var highlightedItemID

    @ViewBuilder
    func body(content: Content) -> some View {
        if let item {
            let isHighlighted = highlightedItemID == item.rawValue
            content
                .background(
                    Rectangle()
                        .fill(isHighlighted ? DS.Colors.revealHighlight : Color.clear)
                        .allowsHitTesting(false)
                )
                .animation(.easeOut(duration: DS.Animation.normal), value: isHighlighted)
                .id(item.rawValue)
        } else {
            content
        }
    }
}

extension View {
    /// Makes this view the scroll target and highlight surface for a
    /// searchable setting.
    func settingsAnchor(_ item: SettingsItem?) -> some View {
        modifier(SettingsAnchorModifier(item: item))
    }
}

// MARK: - Page

/// One settings section's page: title, subtitle, and the sections below at
/// the settings reading measure. Once the title scrolls away, it condenses
/// into a frosted bar the content slides under. Scrolls to and highlights
/// the row search picked.
struct SettingsPage<Content: View>: View {
    let tab: DesktopSettingsTab
    @ObservedObject var navigation: SettingsNavigationModel
    @ViewBuilder var content: () -> Content

    @State private var isTitleCondensed = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private static var scrollSpace: String { "settingsPageScroll" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
                    header
                        // A preference read from inside the ScrollView never reached
                        // onPreferenceChange here, so the bar never showed.
                        .onGeometryChange(for: Bool.self) { geometry in
                            geometry.frame(in: .named(Self.scrollSpace)).minY
                                < -DS.SettingsLayout.condensedTitleThreshold
                        } action: { shouldCondense in
                            guard shouldCondense != isTitleCondensed else { return }
                            withAnimation(accessibilityReduceMotion ? DS.Animation.reducedMotionFade : .easeOut(duration: DS.Animation.fast)) {
                                isTitleCondensed = shouldCondense
                            }
                        }
                    content()
                }
                .frame(maxWidth: DS.SettingsLayout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, DS.SettingsLayout.pageHorizontalPadding)
                .padding(.vertical, DS.SettingsLayout.pageVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onAppear { reveal(navigation.revealRequest, with: proxy) }
            .onChange(of: navigation.revealRequest) { _, request in
                reveal(request, with: proxy)
            }
        }
        .overlay(alignment: .top) {
            condensedTitleBar
        }
        .environment(\.settingsHighlightedItemID, navigation.highlightedItem?.rawValue)
        .background(DS.Colors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tab.title)
                .font(DS.Fonts.pageTitle)
                .tracking(-0.5)
                .foregroundColor(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(tab.subtitle)
                .font(DS.Fonts.bodyLarge)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, DS.Spacing.xs)
    }

    /// The title, small and centered on frosted glass, once the big one has
    /// scrolled away. Content blurs beneath it rather than being cut off.
    private var condensedTitleBar: some View {
        Text(tab.title)
            .font(DS.Fonts.headline)
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: DS.SettingsLayout.condensedTitleBarHeight)
            // Tint above the blur, so the bar stays matte.
            .background(DS.Colors.condensedBarTint)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DS.Colors.hairline)
                    .frame(height: 1)
            }
            .opacity(isTitleCondensed ? 1 : 0)
            .offset(y: isTitleCondensed || accessibilityReduceMotion ? 0 : -6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Waits one layout pass so a page that just appeared has its rows,
    /// then scrolls and hands the highlight back to the model.
    private func reveal(_ request: SettingsNavigationModel.RevealRequest?, with proxy: ScrollViewProxy) {
        guard let request, request.item.tab == tab else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            withAnimation(accessibilityReduceMotion ? nil : DS.Animation.settingsPage) {
                proxy.scrollTo(request.item.rawValue, anchor: .center)
            }
            navigation.didReveal(request)
        }
    }
}

// MARK: - Section

/// A group of related rows on one matte card, with a sentence-case header
/// above and optional help text below.
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    /// A small trailing control in the header ("Check again").
    var headerAccessory: AnyView?
    @ViewBuilder var content: () -> Content

    init(
        _ title: String? = nil,
        footer: String? = nil,
        headerAccessory: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.headerAccessory = headerAccessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionInnerSpacing) {
            if title != nil || headerAccessory != nil {
                HStack(alignment: .center, spacing: DS.Spacing.sm) {
                    if let title {
                        Text(title)
                            .font(DS.Fonts.sectionLabel)
                            .foregroundColor(DS.Colors.textTertiary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 0)
                    if let headerAccessory {
                        headerAccessory
                    }
                }
                .padding(.horizontal, DS.Spacing.xs)
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: DS.SettingsLayout.cardCornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: DS.SettingsLayout.cardCornerRadius, style: .continuous)
                    .fill(DS.Colors.surface1)
                    .shadow(
                        color: DS.Colors.cardShadow,
                        radius: DS.SettingsLayout.cardShadowRadius,
                        y: DS.SettingsLayout.cardShadowY
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.SettingsLayout.cardCornerRadius, style: .continuous)
                    .stroke(DS.Colors.hairline, lineWidth: 1)
            )
            .accessibilityElement(children: .contain)

            if let footer {
                SettingsInlineHelp(footer)
                    .padding(.horizontal, DS.Spacing.xs)
            }
        }
    }
}

/// The hairline between rows in a section, inset to the text column.
struct SettingsDivider: View {
    var leadingInset: CGFloat = DS.SettingsLayout.rowHorizontalPadding

    var body: some View {
        Rectangle()
            .fill(DS.Colors.hairline)
            .frame(height: 1)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// The base row: an optional icon, a title with help text under it, and a
/// trailing control. Every other row is this with a particular control.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var item: SettingsItem?
    @ViewBuilder var accessory: () -> Accessory
    private var brand: AgentBrain?

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        item: SettingsItem? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.item = item
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.SettingsLayout.rowAccessorySpacing) {
            SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage, brand: brand)
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
        }
        .settingsRowInsets()
        .accessibilityElement(children: .contain)
        .settingsAnchor(item)
    }

    /// Uses `brain`'s logo for the row icon when there is one.
    func brandMark(_ brain: AgentBrain?) -> Self {
        var row = self
        row.brand = brain
        return row
    }
}

extension SettingsRow where Accessory == EmptyView {
    /// A row with no control — a readout or a title over help text.
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, item: SettingsItem? = nil) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, item: item) { EmptyView() }
    }
}

/// The title and help text column of a row.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    /// An engine whose logo replaces `systemImage`.
    var brand: AgentBrain?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.md) {
            if let brand {
                AgentBrandMark(brain: brand, size: 18)
                    .frame(width: DS.SettingsLayout.rowIconWidth)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(DS.Glyph.regular)
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: DS.SettingsLayout.rowIconWidth)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DS.Fonts.bodyLarge)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension View {
    /// The shared row padding and minimum height.
    func settingsRowInsets() -> some View {
        self
            .padding(.horizontal, DS.SettingsLayout.rowHorizontalPadding)
            .padding(.vertical, DS.SettingsLayout.rowVerticalPadding)
            .frame(minHeight: DS.SettingsLayout.rowMinHeight)
    }

    /// Insets for content that sits under a row inside the same card (a
    /// field, a list, a notice) so it lines up with the row's text.
    func settingsRowContentInsets() -> some View {
        self
            .padding(.horizontal, DS.SettingsLayout.rowHorizontalPadding)
            .padding(.bottom, DS.SettingsLayout.rowVerticalPadding)
    }
}

/// A row whose control is the HeyMate switch. VoiceOver hears one toggle
/// named by the title, with the help text as its hint.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var item: SettingsItem?
    @Binding var isOn: Bool

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        item: SettingsItem? = nil,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.item = item
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage)
        }
        .toggleStyle(DSSwitchToggleStyle())
        .accessibilityHint(subtitle ?? "")
        .settingsRowInsets()
        .settingsAnchor(item)
    }
}

/// One option in a pick-one list (which AI answers you). The whole leading
/// area selects it; the trailing accessory holds that option's own action
/// ("Sign in"). VoiceOver hears a selectable item with its status.
struct SettingsChoiceRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var status: (text: String, tone: SettingsStatusTone)?
    let systemImage: String
    let isSelected: Bool
    var item: SettingsItem?
    let select: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    /// Shows this engine's real mark in place of `systemImage`.
    private var brand: AgentBrain?

    init(
        _ title: String,
        subtitle: String? = nil,
        status: (text: String, tone: SettingsStatusTone)? = nil,
        systemImage: String,
        isSelected: Bool,
        item: SettingsItem? = nil,
        select: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.item = item
        self.select = select
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.SettingsLayout.rowAccessorySpacing) {
            Button(action: select) {
                HStack(alignment: .center, spacing: DS.Spacing.md) {
                    SettingsRadioMark(isSelected: isSelected)
                    Group {
                        if let brand {
                            AgentBrandMark(brain: brand, size: 18)
                        } else {
                            Image(systemName: systemImage)
                                .font(DS.Glyph.regular)
                        }
                    }
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(width: DS.SettingsLayout.rowIconWidth)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(isSelected ? DS.Fonts.headline : DS.Fonts.bodyLarge)
                            .foregroundColor(DS.Colors.textPrimary)
                        if let status {
                            HStack(spacing: 5) {
                                if status.tone == .progress {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    DSStatusDot(color: status.tone.dotColor)
                                }
                                Text(status.text)
                                    .font(DS.Fonts.caption)
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else if let subtitle {
                            Text(subtitle)
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor(isEnabled: !isSelected)
            .accessibilityLabel(title)
            .accessibilityValue(status?.text ?? subtitle ?? "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(isSelected ? "" : "Use \(title)")

            accessory()
        }
        .settingsRowInsets()
        .background(isSelected ? DS.Colors.surface2 : Color.clear)
        .settingsAnchor(item)
    }
}

extension SettingsChoiceRow {
    /// Uses `brain`'s logo for the row icon; `systemImage` stays the fallback.
    func brandMark(_ brain: AgentBrain) -> Self {
        var row = self
        row.brand = brain
        return row
    }
}

extension SettingsChoiceRow where Accessory == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        isSelected: Bool,
        item: SettingsItem? = nil,
        select: @escaping () -> Void
    ) {
        self.init(
            title,
            subtitle: subtitle,
            status: nil,
            systemImage: systemImage,
            isSelected: isSelected,
            item: item,
            select: select
        ) { EmptyView() }
    }
}

/// The radio circle for a pick-one row. Ink, not accent: matte by design.
struct SettingsRadioMark: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(isSelected ? DS.Colors.textPrimary : DS.Colors.borderStrong, lineWidth: 1.5)
            if isSelected {
                Circle()
                    .fill(DS.Colors.textPrimary)
                    .padding(4)
            }
        }
        .frame(width: DS.SettingsLayout.radioSide, height: DS.SettingsLayout.radioSide)
        .accessibilityHidden(true)
    }
}

/// A row whose control is a HeyMate menu.
struct SettingsPickerRow<Value: Hashable>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var item: SettingsItem?
    @Binding var selection: Value
    let options: [DSMenuOption<Value>]
    var placeholder: String = "Choose…"
    var width: CGFloat = DS.SettingsLayout.pickerWidth

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        item: SettingsItem? = nil,
        selection: Binding<Value>,
        options: [DSMenuOption<Value>],
        placeholder: String = "Choose…",
        width: CGFloat = DS.SettingsLayout.pickerWidth
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.item = item
        self._selection = selection
        self.options = options
        self.placeholder = placeholder
        self.width = width
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle, systemImage: systemImage, item: item) {
            DSMenuPicker(
                accessibilityTitle: title,
                selection: $selection,
                options: options,
                placeholder: placeholder,
                width: width
            )
        }
    }
}

/// A red action that always asks before it runs. Use for anything that
/// deletes, signs out, or cannot be undone.
struct SettingsDestructiveRow: View {
    let title: String
    var subtitle: String?
    var item: SettingsItem?
    let buttonTitle: String
    let confirmationTitle: String
    let confirmationMessage: String
    var confirmButtonTitle: String?
    var isEnabled = true
    let action: () -> Void

    @State private var isConfirming = false

    var body: some View {
        SettingsRow(title, subtitle: subtitle, item: item) {
            Button(buttonTitle) { isConfirming = true }
                .dsCapsuleButtonStyle(.destructive)
                .disabled(!isEnabled)
                .accessibilityHint(confirmationMessage)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(confirmButtonTitle ?? buttonTitle, role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }
}

/// Paste, replace, or remove a key kept in HeyMate's private secrets file.
/// A saved key is reported, never shown, and removing one always asks.
struct SettingsSecretKeyRow: View {
    let title: String
    var subtitle: String?
    var item: SettingsItem?
    let placeholder: String
    let isStored: Bool
    var isBusy = false
    let removalTitle: String
    let removalMessage: String
    let onSave: (String) -> Void
    let onRemove: () -> Void

    @State private var draft = ""
    @State private var isConfirmingRemoval = false

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title, subtitle: subtitle) {
                if isBusy {
                    SettingsStatusBadge(text: "Checking…", tone: .progress)
                } else if isStored {
                    SettingsStatusBadge(text: "Saved", tone: .positive)
                } else {
                    SettingsStatusBadge(text: "Not set", tone: .neutral)
                }
            }

            HStack(spacing: DS.Spacing.sm) {
                SecureField(isStored ? "Paste a new key to replace the saved one" : placeholder, text: $draft)
                    .settingsFieldChrome()
                    .onSubmit(save)
                    .accessibilityLabel(title)

                Button(isStored ? "Replace" : "Save", action: save)
                    .dsCapsuleButtonStyle(.primary)
                    .disabled(trimmedDraft.isEmpty || isBusy)

                if isStored {
                    Button("Remove") { isConfirmingRemoval = true }
                        .dsCapsuleButtonStyle(.destructive)
                        .disabled(isBusy)
                }
            }
            .settingsRowContentInsets()
        }
        .settingsAnchor(item)
        .confirmationDialog(removalTitle, isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
    }

    private func save() {
        guard !trimmedDraft.isEmpty, !isBusy else { return }
        onSave(trimmedDraft)
        draft = ""
    }
}

// MARK: - Disclosure

/// A row that folds secondary detail away until it's wanted: the safety
/// rules, the full "what leaves this Mac" list, the engines most people
/// never use. The chevron turns and the content eases open.
struct SettingsDisclosureRow<Content: View>: View {
    let title: String
    var subtitle: String?
    var item: SettingsItem?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovered = false

    init(
        _ title: String,
        subtitle: String? = nil,
        item: SettingsItem? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.item = item
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(accessibilityReduceMotion ? DS.Animation.reducedMotionFade : DS.Animation.settingsDisclosure) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: DS.SettingsLayout.rowAccessorySpacing) {
                    SettingsRowLabel(title: title, subtitle: subtitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(DS.Glyph.small)
                        .foregroundColor(isHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .settingsRowInsets()
                .background(isHovered ? DS.Colors.surface2.opacity(0.6) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { isHovered = $0 }
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hide details" : "Show details")

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(
                    accessibilityReduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top))
                )
            }
        }
        .clipped()
        .settingsAnchor(item)
    }
}

// MARK: - Frosted chrome

/// AppKit's real behind-window blur, for the settings rail: the desktop
/// shows through, softly, the way a macOS sidebar should. A matte tint on
/// top (`DS.Colors.chromeTint`) keeps it on-palette.
struct DSVisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

// MARK: - Status, help, notices

/// How a status reads: good, needs you, broken, plain, or working.
enum SettingsStatusTone: Equatable {
    case positive
    case attention
    case critical
    case neutral
    case progress

    var dotColor: Color {
        switch self {
        case .positive: return DS.Colors.success
        case .attention: return DS.Colors.warning
        case .critical: return DS.Colors.destructive
        case .neutral, .progress: return DS.Colors.textTertiary
        }
    }

    var textColor: Color {
        switch self {
        case .positive: return DS.Colors.success
        case .attention: return DS.Colors.warningText
        case .critical: return DS.Colors.destructiveText
        case .neutral, .progress: return DS.Colors.textSecondary
        }
    }

    var symbolName: String {
        switch self {
        case .positive: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .neutral, .progress: return "info.circle"
        }
    }
}

/// A small status pill: dot (or spinner) and a word or two.
struct SettingsStatusBadge: View {
    let text: String
    var tone: SettingsStatusTone = .neutral

    var body: some View {
        HStack(spacing: 6) {
            if tone == .progress {
                ProgressView()
                    .controlSize(.mini)
            } else {
                DSStatusDot(color: tone.dotColor)
            }
            Text(text)
                .font(DS.Fonts.statusWord)
                .foregroundColor(tone.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .frame(minHeight: DS.ControlSize.small - 2)
        .background(Capsule(style: .continuous).fill(tone.dotColor.opacity(0.10)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Help text under a row or a section. Tinted when it is a warning.
struct SettingsInlineHelp: View {
    let text: String
    var tone: SettingsStatusTone = .neutral

    init(_ text: String, tone: SettingsStatusTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if tone != .neutral && tone != .progress {
                Image(systemName: tone.symbolName)
                    .font(DS.Glyph.small)
                    .foregroundColor(tone.dotColor)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(DS.Fonts.caption)
                .foregroundColor(tone == .neutral ? DS.Colors.textTertiary : tone.textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A callout inside a section: a warning with the one action that fixes
/// it, an error, or a note that something is in progress.
struct SettingsNotice: View {
    let text: String
    var tone: SettingsStatusTone = .attention
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.md) {
            Group {
                if tone == .progress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: tone.symbolName)
                        .font(DS.Glyph.regular)
                        .foregroundColor(tone.dotColor)
                }
            }
            .accessibilityHidden(true)

            Text(text)
                .font(DS.Fonts.caption)
                .foregroundColor(tone == .neutral ? DS.Colors.textSecondary : tone.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm + 2)
        .dsSurface(.tinted(tone.dotColor), cornerRadius: DS.CornerRadius.medium)
        .accessibilityElement(children: .combine)
    }
}

/// A plain line for an empty list inside a section.
struct SettingsEmptyRow: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(DS.Glyph.regular)
                    .foregroundColor(DS.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .settingsRowInsets()
    }
}

// MARK: - Fields

extension View {
    /// The well every settings text field sits in.
    func settingsFieldChrome(isMonospaced: Bool = false) -> some View {
        self
            .textFieldStyle(.plain)
            .font(isMonospaced ? DS.Fonts.mono : DS.Fonts.body)
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .frame(minWidth: DS.SettingsLayout.fieldMinWidth, minHeight: DS.ControlSize.regular)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }
}

// MARK: - Switch

/// HeyMate's switch: a matte ink track instead of the system's tinted one.
/// The label sits on the left and the switch on the right, like a row; only
/// the switch itself is clickable, as on macOS. VoiceOver sees a native
/// toggle.
struct DSSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: DS.SettingsLayout.rowAccessorySpacing) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            DSSwitch(isOn: configuration.$isOn)
        }
        .accessibilityRepresentation {
            // The system style here, or this style would represent itself
            // forever.
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }
}

/// The bare switch, for places with their own label.
struct DSSwitch: View {
    @Binding var isOn: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var knobDiameter: CGFloat {
        DS.SettingsLayout.switchHeight - DS.SettingsLayout.switchKnobInset * 2
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? DS.Colors.switchTrackOn : DS.Colors.switchTrackOff)
                Circle()
                    .fill(isOn ? DS.Colors.switchKnobOn : DS.Colors.switchKnobOff)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .padding(DS.SettingsLayout.switchKnobInset)
            }
            .frame(width: DS.SettingsLayout.switchWidth, height: DS.SettingsLayout.switchHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .pointerCursor(isEnabled: isEnabled)
        .animation(accessibilityReduceMotion ? nil : DS.Animation.controlSpring, value: isOn)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Segmented control

struct DSSegment<Value: Hashable> {
    let value: Value
    let title: String
    var isEnabled = true
    /// Why the segment can't be picked, or what it means. Shown on hover
    /// and read by VoiceOver.
    var help: String?
}

/// A matte segmented control: a recessed track with the selected segment
/// raised in the page color.
struct DSSegmentedControl<Value: Hashable>: View {
    let accessibilityTitle: String
    @Binding var selection: Value
    let segments: [DSSegment<Value>]
    var width: CGFloat? = DS.SettingsLayout.segmentedWidth

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                segmentButton(segment)
            }
        }
        .padding(2)
        .frame(width: width)
        .background(Capsule(style: .continuous).fill(DS.Colors.surface2))
        .overlay(Capsule(style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
    }

    private func segmentButton(_ segment: DSSegment<Value>) -> some View {
        let isSelected = segment.value == selection
        return Button {
            selection = segment.value
        } label: {
            Text(segment.title)
                .font(DS.Fonts.control)
                .foregroundColor(
                    isSelected
                        ? DS.Colors.textPrimary
                        : (segment.isEnabled ? DS.Colors.textSecondary : DS.Colors.disabledText)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, DS.Spacing.sm)
                .frame(maxWidth: .infinity, minHeight: DS.ControlSize.small)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? DS.Colors.background : Color.clear)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(isSelected ? DS.Colors.borderStrong : Color.clear, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!segment.isEnabled)
        .pointerCursor(isEnabled: segment.isEnabled && !isSelected)
        .help(segment.help ?? segment.title)
        .accessibilityLabel(segment.title)
        .accessibilityHint(segment.help ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeOut(duration: DS.Animation.fast), value: isSelected)
    }
}

// MARK: - Menu picker

struct DSMenuOption<Value: Hashable> {
    let value: Value
    let title: String
    /// Draws a separator above this option.
    var startsGroup = false
}

/// HeyMate's popup menu: a matte well with the current choice and an
/// up-down chevron, opening a menu with a checkmark on the current item.
struct DSMenuPicker<Value: Hashable>: View {
    let accessibilityTitle: String
    @Binding var selection: Value
    let options: [DSMenuOption<Value>]
    var placeholder: String = "Choose…"
    var width: CGFloat? = DS.SettingsLayout.pickerWidth

    @Environment(\.isEnabled) private var isEnabled

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? placeholder
    }

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                if option.startsGroup {
                    Divider()
                }
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            DSMenuLabel(title: currentTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: width)
        .opacity(isEnabled ? 1 : 0.45)
        .pointerCursor(isEnabled: isEnabled)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(currentTitle)
    }
}

/// The closed state of a HeyMate menu.
struct DSMenuLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(title)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Spacing.xs)
            Image(systemName: "chevron.up.chevron.down")
                .font(DS.Glyph.micro)
                .foregroundColor(DS.Colors.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: DS.ControlSize.regular)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
    }
}

// MARK: - Small controls

/// A refresh glyph that becomes a spinner while its work runs.
struct SettingsRefreshButton: View {
    let isRefreshing: Bool
    let accessibilityTitle: String
    let action: () -> Void

    var body: some View {
        Group {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing")
            } else {
                Button(action: action) {
                    Image(systemName: "arrow.clockwise")
                        .font(DS.Glyph.small)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: DS.ControlSize.small, height: DS.ControlSize.small)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(accessibilityTitle)
                .accessibilityLabel(accessibilityTitle)
            }
        }
        .frame(width: DS.ControlSize.small, height: DS.ControlSize.small)
    }
}
