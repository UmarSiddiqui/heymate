//
//  DesignSystem.swift
//  HeyMate
//
//  Centralized design system. HeyMate lives in the notch, so every surface
//  is as quiet as the hardware around it: matte black in dark mode, clean
//  white in light, lit by one color — the buddy's theme color.
//
//  Palette: true neutrals with no hue cast, layered by lightness only, and
//  the user-picked buddy color as the single accent. Semantic colors stay
//  semantic. `warmth` is a decorative lilac kept for illustration — never
//  status, never chrome.
//
//  Type: Avenir Next carries the voice. See `DS.Fonts`.
//
//  All colors, button styles, and interaction states are defined here as
//  the single source of truth.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Backgrounds ──────────────────────────────────────────────
        // Matte neutrals, layered deepest to most elevated. No hue cast in
        // either mode: black is black, white is white, and elevation is
        // carried by lightness alone.

        /// The deepest background — used for the main app window fill.
        static let background = Color(light: "#FFFFFF", dark: "#0A0A0A")

        /// First elevation layer — used for cards, sidebar, top bar backgrounds.
        static let surface1 = Color(light: "#F7F7F8", dark: "#121213")

        /// Second elevation layer — used for input fields, elevated cards, chat bubbles.
        static let surface2 = Color(light: "#F0F0F2", dark: "#1A1A1C")

        /// Third elevation layer — used for hover backgrounds on interactive elements.
        static let surface3 = Color(light: "#E6E6E9", dark: "#232325")

        /// Fourth elevation layer — used for active/pressed states on interactive elements.
        static let surface4 = Color(light: "#DADADE", dark: "#2D2D30")

        // ── Borders ──────────────────────────────────────────────────

        /// Subtle border — used for card outlines, dividers, input field borders.
        static let borderSubtle = Color(light: "#E4E4E7", dark: "#262628")

        /// Strong border — used for focused inputs, hovered card outlines.
        static let borderStrong = Color(light: "#C9C9CF", dark: "#3E3E42")

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — main body text, titles, headings.
        static let textPrimary = Color(light: "#111113", dark: "#F5F5F7")

        /// Secondary text — descriptions, hints, muted labels.
        static let textSecondary = Color(light: "#52525A", dark: "#B3B3BA")

        /// Tertiary text — very muted, used for section labels, timestamps, disabled text.
        static let textTertiary = Color(light: "#8A8A93", dark: "#84848C")

        /// Text used on top of the accent fill, like the primary button label.
        static let textOnAccent: Color = .white

        // ── Tailwind Blue Scale ─────────────────────────────────────
        // Full Tailwind CSS v4 blue palette for consistent blue usage.
        //
        // Usage guide:
        //   50–100  → Very subtle tinted backgrounds (selected rows, hover fills on dark surfaces)
        //   200–300 → Light text/icons on dark backgrounds, disabled states
        //   400     → Bright accent text, links, icons, chat user bubbles
        //   500     → Mid-tone fills, badges, secondary buttons
        //   600     → Primary action fills (buttons, toggles) — main accent
        //   700     → Hover/pressed state for primary actions
        //   800–900 → Deep backgrounds, dark overlays, header bars
        //   950     → Deepest blue — near-black tinted backgrounds

        static let blue50  = Color(hex: "#eff6ff")
        static let blue100 = Color(hex: "#dbeafe")
        static let blue200 = Color(hex: "#bfdbfe")
        static let blue300 = Color(hex: "#93c5fd")
        static let blue400 = Color(hex: "#60a5fa")
        static let blue500 = Color(hex: "#3b82f6")
        static let blue600 = Color(hex: "#2563eb")
        static let blue700 = Color(hex: "#1d4ed8")
        static let blue800 = Color(hex: "#1e40af")
        static let blue900 = Color(hex: "#1e3a8a")
        static let blue950 = Color(hex: "#172554")

        // ── Accent (the buddy's color) ─────────────────────────────
        // The primary fill follows the onboarding theme color so the
        // notch, cursor, and buttons are all recognizably the same buddy.

        /// Accent fill — used for solid button backgrounds. Follows the
        /// onboarding theme color so the notch, cursor, and buttons match.
        static var accent: Color { AppTheme.color }

        /// Accent hover — slightly darker mix of the theme color.
        static var accentHover: Color { AppTheme.color.blendedWithBlack(fraction: 0.18) }

        /// Accent text — brighter mix for labels on dark surfaces.
        static var accentText: Color { AppTheme.color.blendedWithWhite(fraction: 0.28) }

        /// Very subtle accent tint — used for selected item backgrounds.
        static var accentSubtle: Color { AppTheme.color.opacity(0.10) }

        /// The buddy's soft ambient glow — used for hero washes, the
        /// composer focus ring, and the buddy mark's halo.
        static var accentGlow: Color { AppTheme.color.opacity(0.35) }

        // ── Warmth (decorative only) ────────────────────────────────
        // Nebula lilac, paired with the accent in the buddy's glow.
        // Never a status color, never text. If it is communicating state,
        // it is being misused.

        static let warmth = Color(hex: "#B9A9E8")

        /// Soft variant for gradient ends.
        static let warmthSoft = Color(hex: "#B9A9E8").opacity(0.55)

        /// The app icon's indigo halo. Brand identity only — never UI state.
        static let brandGlow = Color(hex: "#5E54FF")

        // ── Semantic Colors ──────────────────────────────────────────

        /// Destructive/error actions — delete buttons, error messages, close button hover.
        static let destructive = Color(hex: "#E5484D")        // Radix Red 9

        /// Destructive hover state.
        static let destructiveHover = Color(hex: "#F2555A")   // Radix Red 10

        /// Destructive used for text on dark backgrounds (brighter for readability).
        static let destructiveText = Color(light: "#CD2B31", dark: "#FF6369")    // Radix Red 11

        /// Success — checkmarks, granted status, completion indicators.
        /// Independent green so success states are visually distinct from the accent.
        static let success = Color(light: "#18794E", dark: "#34D399")      // Tailwind Emerald 400

        /// Warning — caution messages, manual verification failure explanations.
        static let warning = Color(hex: "#FFB224")            // Radix Amber 9

        /// Warning text — brighter variant for text on dark backgrounds.
        static let warningText = Color(light: "#AB6400", dark: "#F1A10D")        // Radix Amber 11

        /// Info/feature highlight — used for prompt card headers, code highlights.
        /// Lighter than accentText so informational elements are visually distinct
        /// from interactive accent-colored elements.
        static let info = Color(light: "#0D74CE", dark: "#70B8FF")               // Radix Blue 9

        /// Inline code text color — slightly brighter blue for monospace code snippets.
        static let codeText = Color(light: "#1859C4", dark: "#9DC2FF")           // Radix Blue 11 variant

        // ── Overlay Cursor ───────────────────────────────────────────

        /// The cursor/bubble color used in OverlayWindow — same as the
        /// onboarding theme so the buddy matches the notch rim.
        static var overlayCursorBlue: Color { AppTheme.color }

        // ── Floating Button Gradient ─────────────────────────────────

        /// The floating session button gradient colors (unchanged from original —
        /// this gradient is intentionally distinct from the rest of the palette
        /// to make the floating button stand out as a "jewel" on the desktop).
        static let floatingGradientPurple = Color(hex: "#8F46EB")
        static let floatingGradientPink = Color(hex: "#E84D9E")
        static let floatingGradientOrange = Color(hex: "#FF8C33")

        // ── Chat Bubbles ───────────────────────────────────────────

        /// User message bubble background: a deep blend of the buddy's
        /// color, so the bubble is themed while white text stays readable
        /// across every swatch (a raw Mint or Amber fill would fail).
        static var helpChatUserBubble: Color {
            AppTheme.color.blendedWithBlack(fraction: 0.34)
        }

        /// Slightly lighter variant for hover/pressed states on user bubbles.
        static var helpChatUserBubbleHover: Color {
            AppTheme.color.blendedWithBlack(fraction: 0.22)
        }

        /// Footer/backdrop behind the chat surface.
        static let helpChatBackdrop = Color(light: "#FFFFFF", dark: "#0A0A0A")

        // ── Disabled State ───────────────────────────────────────────
        // Following Material Design 3's disabled pattern:
        // Container: onSurface at 12% opacity
        // Content: onSurface at 38% opacity

        /// Disabled button/container background.
        static var disabledBackground: Color {
            textPrimary.opacity(0.12)
        }

        /// Disabled text/icon color.
        static var disabledText: Color {
            textPrimary.opacity(0.38)
        }

        // ── Hairlines ────────────────────────────────────────────────

        /// Dividers between bars and sections. Quieter than
        /// `borderSubtle`, which outlines things you can click.
        static var hairline: Color { borderSubtle.opacity(0.6) }

        // ── Controls ─────────────────────────────────────────────────
        // Matte, not tinted: an "on" switch is ink on paper — black in
        // light mode, white in dark — so settings read calm and the
        // buddy's accent stays reserved for the one action that matters.

        /// Switch track when on.
        static var switchTrackOn: Color { textPrimary }

        /// Switch track when off.
        static var switchTrackOff: Color { surface4 }

        /// Switch knob sitting on the "on" track.
        static var switchKnobOn: Color { background }

        /// Switch knob sitting on the "off" track.
        static let switchKnobOff = Color(light: "#FFFFFF", dark: "#B3B3BA")

        /// The selected item in a rail or a segmented control.
        static var selectionFill: Color { surface3 }

        /// Keyboard focus ring on custom controls.
        static var focusRing: Color { textPrimary.opacity(0.55) }

        /// The brief wash on a settings row that search just jumped to.
        static var revealHighlight: Color { textPrimary.opacity(0.06) }

        /// Under a settings card. Barely there in light mode; dark mode
        /// relies on the lighter card fill instead.
        static let cardShadow = Color(light: "#000000", dark: "#000000").opacity(0.045)

        /// Laid over frosted chrome (the settings rail, the condensed title
        /// bar) so the blur stays matte and on-palette instead of picking up
        /// the colors behind it.
        static var chromeTint: Color { surface1.opacity(0.55) }
        static var condensedBarTint: Color { background.opacity(0.6) }

        // ── Status ───────────────────────────────────────────────────
        // One mapping per kind of state. Every dot, pill, and label that
        // reports status reads from here, so "listening" is the same color
        // on the notch pill, the header, and the app icon badge.

        /// The buddy's voice state, matching the notch pill: green at rest,
        /// the buddy's own color while it hears or speaks, amber while it
        /// works. Listening is deliberately *not* amber — macOS already
        /// draws its orange mic dot right beside the notch.
        static func voiceStatus(_ state: CompanionVoiceState) -> Color {
            switch state {
            case .idle: return success
            case .listening, .responding: return accent
            case .processing: return warning
            }
        }

        /// An agent run's lifecycle. Waiting on you is amber, broken is red.
        static func agentStatus(_ status: AgentRunStatus) -> Color {
            switch status {
            case .queued, .cancelled: return textTertiary
            case .planning, .running: return accentText
            case .awaitingPlanApproval, .waitingForApproval: return warningText
            case .succeeded: return success
            case .failed: return destructiveText
            }
        }
    }

    // MARK: - Typography
    //
    // Avenir Next is HeyMate's voice: humanist, clear, and warm without
    // leaning playful or editorial. Monospaced technical content stays
    // native. A view should almost never set a raw font outside this scale.

    enum Fonts {
        /// Large page titles (desktop pages).
        static let pageTitle = Font.custom("Avenir Next", size: 25).weight(.semibold)

        /// Card titles and hero status lines.
        static let title = Font.custom("Avenir Next", size: 15).weight(.semibold)

        /// Smaller title for compact surfaces (notch card titles).
        static let titleCompact = Font.custom("Avenir Next", size: 13).weight(.semibold)

        /// Sentence-case section labels. Replaces tracked-out ALL-CAPS
        /// micro headers: warmer, and easier to read at a glance.
        static let sectionLabel = Font.custom("Avenir Next", size: 11).weight(.semibold)

        /// Emphasized content: row titles, bubble names.
        static let headline = Font.custom("Avenir Next", size: 13).weight(.semibold)

        /// Default content text.
        static let body = Font.custom("Avenir Next", size: 12)

        /// Roomier content text: composers, notes, settings rows.
        static let bodyLarge = Font.custom("Avenir Next", size: 13)

        /// Conversation text — chat bubbles and the message composer,
        /// where people read whole paragraphs.
        static let reading = Font.custom("Avenir Next", size: 15)

        /// The one big line on an empty state or a mate's home.
        static let hero = Font.custom("Avenir Next", size: 20).weight(.semibold)

        /// Supporting text: subtitles, hints, timestamps.
        static let caption = Font.custom("Avenir Next", size: 11)

        /// The floor. Badge counts, keycaps, tiny metadata. Never body copy.
        static let micro = Font.custom("Avenir Next", size: 10).weight(.medium)

        /// Status words the buddy reports ("Listening", "Ready").
        static let statusWord = Font.custom("Avenir Next", size: 11).weight(.semibold)

        /// Every capsule control label — buttons, chips, tabs, the status
        /// pill. One size so notch and window controls read as one family.
        static let control = Font.custom("Avenir Next", size: 12).weight(.semibold)

        /// Window-scale button labels (`DSPrimaryButtonStyle` and friends).
        static let controlLarge = Font.custom("Avenir Next", size: 13).weight(.semibold)

        /// Keycaps, badges, and tags that must stay legible at the floor.
        static let keycap = Font.custom("Avenir Next", size: 10).weight(.semibold)

        /// Numbers that tick — timers, elapsed time, counters. Tabular so
        /// the digits don't jitter.
        static let numeric = Font.system(size: 11, weight: .medium).monospacedDigit()

        /// Code blocks in chat replies. Monospaced so indentation lines up.
        static let code = Font.system(size: 13, design: .monospaced)

        /// Large tabular numbers — the timer face, battery percentage.
        static let numericLarge = Font.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()

        /// Identifiers a person may need to copy exactly — bundle ids,
        /// addresses, file paths.
        static let mono = Font.system(size: 12, design: .monospaced)

        /// Long-form editing — the behavior contract and other text files
        /// edited in place.
        static let editor = Font.custom("Avenir Next", size: 14)
    }

    // MARK: - Glyphs
    //
    // SF Symbols stay on SF so their optical weight matches macOS. Four
    // sizes cover every icon in the app; pick by role, not by eye.

    enum Glyph {
        /// Inline marks inside a label (the mic in a hint, the stop square).
        static let micro = Font.system(size: 9, weight: .bold)
        /// Chevrons, row accessories, icons beside caption text.
        static let small = Font.system(size: 11, weight: .semibold)
        /// Icon buttons and toolbar actions — the default.
        static let regular = Font.system(size: 13, weight: .medium)
        /// Tile and door icons.
        static let large = Font.system(size: 15, weight: .medium)
    }

    // MARK: - Control Metrics
    //
    // Heights from the macOS HIG. Every clickable thing in the notch and
    // the window lands on one of these, so rows line up across surfaces.

    enum ControlSize {
        /// Inline link-style actions.
        static let small: CGFloat = 24
        /// Icon buttons, capsule buttons, chips. The default.
        static let regular: CGFloat = 28
        /// Window-scale buttons and hero composers.
        static let large: CGFloat = 32
    }

    // MARK: - Settings Metrics
    //
    // One unhurried rhythm for every settings page: an 18pt row inset, a
    // 52pt row floor, 36pt between sections, and a narrow reading column,
    // so a page reads as a few calm groups rather than a dense form.
    // Trailing controls share widths so their edges line up down a page.

    enum SettingsLayout {
        /// The section rail beside the settings content.
        static let railWidth: CGFloat = 224
        /// Reading measure of the settings column.
        static let contentMaxWidth: CGFloat = 640
        /// Page gutters.
        static let pageHorizontalPadding: CGFloat = 40
        static let pageVerticalPadding: CGFloat = 40
        /// Gap between sections on a page.
        static let sectionSpacing: CGFloat = 36
        /// Gap between a section's header, card, and footer.
        static let sectionInnerSpacing: CGFloat = 10
        /// Row insets inside a section card.
        static let rowHorizontalPadding: CGFloat = 18
        static let rowVerticalPadding: CGFloat = 14
        /// The shortest a row may be.
        static let rowMinHeight: CGFloat = 52
        /// Leading icon column, so titles align whether or not a row has one.
        static let rowIconWidth: CGFloat = 20
        /// Gap between a row's text and its trailing control.
        static let rowAccessorySpacing: CGFloat = 20
        /// Trailing menu pickers.
        static let pickerWidth: CGFloat = 210
        /// Trailing segmented controls.
        static let segmentedWidth: CGFloat = 200
        /// Text and secure fields in a row.
        static let fieldMinWidth: CGFloat = 240
        /// The switch control.
        static let switchWidth: CGFloat = 32
        static let switchHeight: CGFloat = 18
        static let switchKnobInset: CGFloat = 2
        /// Accent swatches.
        static let swatchSide: CGFloat = 22
        /// The radio circle on a pick-one row.
        static let radioSide: CGFloat = 16
        /// How long a row stays highlighted after search jumps to it.
        static let revealHighlightSeconds: Double = 1.6
        /// Section cards: pebble corners, a hairline, and a shadow soft
        /// enough to lift the card without drawing a box around it.
        static let cardCornerRadius: CGFloat = DS.CornerRadius.extraLarge
        static let cardShadowRadius: CGFloat = 18
        static let cardShadowY: CGFloat = 6
        /// Rail items.
        static let railItemHeight: CGFloat = 32
        /// How far a page scrolls before its title condenses into the
        /// frosted bar at the top.
        static let condensedTitleThreshold: CGFloat = 56
        static let condensedTitleBarHeight: CGFloat = 40
    }

    // MARK: - Spacing (for reference, not enforced)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii
    //
    // Friendlier means rounder. Corners lean generous and always use
    // `.continuous` so surfaces feel like pebbles, not boxes.

    enum CornerRadius {
        /// Small elements like tags, badges, and icon wells.
        static let small: CGFloat = 8
        /// Input fields, inset wells inside a card.
        static let medium: CGFloat = 10
        /// Rows and tiles — anything that sits in a list or grid.
        static let large: CGFloat = 12
        /// Cards — composer cards, agent cards, callouts.
        static let extraLarge: CGFloat = 16
        /// Hero surfaces (the buddy card, the composer).
        static let hero: CGFloat = 20
        /// Pill-shaped buttons (the continue button).
        static let pill: CGFloat = .infinity
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Quick state changes — hover in/out, press feedback.
        static let fast: Double = 0.15
        /// Standard transitions — content reveal, button state changes.
        static let normal: Double = 0.25
        /// Slower, more dramatic — fade-ins, celebration screen elements.
        static let slow: Double = 0.4

        /// The buddy's default settle — a gentle spring with a hint of
        /// bounce. Used for state changes that should feel alive rather
        /// than mechanical.
        static let buddySpring = SwiftUI.Animation.spring(response: 0.42, dampingFraction: 0.78)

        /// Snappier spring for small controls (chips, dots, toggles).
        static let controlSpring = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.72)

        /// Moving between settings pages and sliding the rail selection.
        /// Critically damped, so nothing overshoots in a settings window.
        static let settingsPage = SwiftUI.Animation.spring(response: 0.36, dampingFraction: 0.9)

        /// Expanding and collapsing a disclosure inside a settings card.
        static let settingsDisclosure = SwiftUI.Animation.spring(response: 0.32, dampingFraction: 0.88)

        /// What settings motion becomes under Reduce Motion: a plain fade,
        /// with nothing sliding or lifting.
        static let reducedMotionFade = SwiftUI.Animation.easeInOut(duration: fast)
    }

    // MARK: - State Layer Opacities
    // Based on Material Design 3's state layer system.
    // A "state layer" overlays the button's content color at these opacities.

    enum StateLayer {
        /// Hover: subtle highlight to indicate interactivity.
        static let hover: Double = 0.08
        /// Focus: keyboard navigation indicator (slightly stronger than hover).
        static let focus: Double = 0.12
        /// Pressed: active press feedback (same strength as focus).
        static let pressed: Double = 0.12
        /// Dragged: strongest overlay (rarely used).
        static let dragged: Double = 0.16
    }
}

// MARK: - The Buddy Mark (signature component)

/// The buddy itself, as a UI element: a soft squircle in the theme color's
/// tint with the cursor-rays glyph and an optional live state dot. Used
/// wherever the buddy is "present" — the sidebar header, the notch hero,
/// empty states, assistant chat bubbles. One character, one look, so the
/// app never feels like a patchwork of unrelated panels.
///
/// The breathing halo is a `repeatForever` implicit animation while the
/// buddy is active, which Core Animation runs on the render server — no
/// SwiftUI body re-evaluation, matching the pill's idle-cost rules.
struct BuddyMark: View {
    enum Size {
        case small, standard, hero

        var side: CGFloat {
            switch self {
            case .small: return 22
            case .standard: return 34
            case .hero: return 56
            }
        }

        var glyphSize: CGFloat { side * 0.42 }

        var cornerRadius: CGFloat { side * 0.30 }

        var dotSide: CGFloat { side * 0.26 }
    }

    /// What the buddy is doing. Drives the dot color; nil hides the dot.
    var state: CompanionVoiceState? = nil

    var color: Color = DS.Colors.accent

    @State private var isBreathingIn = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    init(size: Size = .standard, state: CompanionVoiceState? = nil, color: Color = DS.Colors.accent) {
        self.size = size
        self.state = state
        self.color = color
    }

    let size: Size

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .fill(color.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                        .stroke(color.opacity(0.28), lineWidth: 1)
                )
                .shadow(
                    color: color.opacity(isBreathingIn ? 0.45 : 0.22),
                    radius: isBreathingIn ? 10 : 5
                )

            Image(systemName: "cursorarrow.rays")
                .font(.system(size: size.glyphSize, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size.side, height: size.side)
        .overlay(alignment: .bottomTrailing) {
            if let state {
                Circle()
                    .fill(dotColor(for: state))
                    .frame(width: size.dotSide, height: size.dotSide)
                    .overlay(Circle().stroke(DS.Colors.background, lineWidth: size.side * 0.06))
                    .shadow(color: dotColor(for: state).opacity(0.7), radius: 3)
                    .offset(x: size.side * 0.05, y: size.side * 0.05)
            }
        }
        .onAppear {
            // Breathing is only for a *live* buddy (a state dot is showing).
            // Static marks — chat avatars, empty-state heroes — stay still,
            // so a transcript full of them doesn't thrum.
            guard state != nil, !accessibilityReduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                isBreathingIn = true
            }
        }
        .accessibilityHidden(true)
    }

    private func dotColor(for state: CompanionVoiceState) -> Color {
        DS.Colors.voiceStatus(state)
    }
}

// MARK: - Status Dot

/// The glowing dot every status readout uses — voice state, agent state,
/// connection state. One size and one glow so a row of them lines up.
struct DSStatusDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 3)
            .accessibilityHidden(true)
    }
}

// MARK: - Section Label

/// The friendly section header: sentence case, rounded, muted. Replaces
/// tracked-out ALL-CAPS micro text, which read as stern and generic.
struct DSSectionLabel: View {
    let title: String
    var accessory: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textSecondary)
            if let accessory {
                Text(accessory)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }
}

// MARK: - Card Surfaces

extension View {
    /// The standard warm card: `surface1` fill, subtle border, generous
    /// continuous corners. Desktop pages and notch content share it so the
    /// two surfaces cannot drift apart visually.
    func dsCard(cornerRadius: CGFloat = DS.CornerRadius.extraLarge) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }

    /// Translucent surfaces for content that floats over the nebula (the
    /// notch card, the Mate home). Four roles replace the dozen one-off
    /// fill-opacity / radius / stroke combinations the views used to pick
    /// by hand.
    func dsSurface(
        _ surface: DSSurface,
        cornerRadius: CGFloat? = nil,
        isHighlighted: Bool = false
    ) -> some View {
        let radius = cornerRadius ?? surface.defaultCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(surface.fill(isHighlighted: isHighlighted)))
            .overlay(
                shape.stroke(
                    surface.stroke(isHighlighted: isHighlighted),
                    lineWidth: surface.strokeWidth
                )
            )
            .contentShape(shape)
    }
}

/// Roles for `dsSurface`. Pick by what the thing *is*, not how dark it
/// should look.
enum DSSurface {
    /// A content card: composer, agent job, form group.
    case card
    /// A clickable row or tile. Lifts when highlighted (hovered).
    case row
    /// A recessed well inside a card: plan preview, code, empty slot.
    case inset
    /// A callout tinted by meaning — warning, suggestion, the buddy's hero.
    case tinted(Color)

    var defaultCornerRadius: CGFloat {
        switch self {
        case .card, .tinted: return DS.CornerRadius.extraLarge
        case .row: return DS.CornerRadius.large
        case .inset: return DS.CornerRadius.medium
        }
    }

    func fill(isHighlighted: Bool) -> Color {
        switch self {
        case .card: return DS.Colors.surface2.opacity(0.72)
        case .row: return DS.Colors.surface2.opacity(isHighlighted ? 0.9 : 0.62)
        case .inset: return DS.Colors.surface3.opacity(0.5)
        case .tinted(let tint): return tint.opacity(isHighlighted ? 0.14 : 0.09)
        }
    }

    func stroke(isHighlighted: Bool) -> Color {
        switch self {
        case .card: return DS.Colors.borderSubtle
        case .row: return isHighlighted ? DS.Colors.borderStrong : DS.Colors.borderSubtle
        case .inset: return .clear
        case .tinted(let tint): return tint.opacity(isHighlighted ? 0.42 : 0.28)
        }
    }

    var strokeWidth: CGFloat {
        switch self {
        case .card, .row: return 0.5
        case .inset: return 0
        case .tinted: return 0.7
        }
    }
}

// MARK: - Capsule Buttons

/// The compact capsule button for dense surfaces — the notch, cards, row
/// actions. Replaces the half-dozen hand-rolled `Text().background(Capsule())`
/// buttons that each picked their own font, padding, and fill.
struct DSCapsuleButtonStyle: ButtonStyle {
    enum Role {
        /// The one action a card is asking for. Accent fill.
        case primary
        /// Supporting action. Neutral fill.
        case secondary
        /// Low-emphasis action. No fill until hovered.
        case quiet
        /// Destroys something. Red tint.
        case destructive
    }

    var role: Role = .secondary
    var height: CGFloat = DS.ControlSize.regular

    func makeBody(configuration: Configuration) -> some View {
        DSCapsuleButtonBody(configuration: configuration, role: role, height: height)
    }
}

private struct DSCapsuleButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let role: DSCapsuleButtonStyle.Role
    let height: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(DS.Fonts.control)
            .lineLimit(1)
            .foregroundColor(foreground)
            .padding(.horizontal, height >= DS.ControlSize.regular ? 12 : 9)
            .frame(minHeight: height)
            .background(Capsule(style: .continuous).fill(background))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 && isEnabled }
            .pointerCursor(isEnabled: isEnabled)
    }

    private var foreground: Color {
        switch role {
        case .primary: return DS.Colors.textOnAccent
        case .secondary: return DS.Colors.textPrimary.opacity(0.9)
        case .quiet: return isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary
        case .destructive: return DS.Colors.destructiveText
        }
    }

    private var background: Color {
        let isActive = isHovered || configuration.isPressed
        switch role {
        case .primary: return isActive ? DS.Colors.accentHover : DS.Colors.accent
        case .secondary: return isActive ? DS.Colors.surface4 : DS.Colors.surface3
        case .quiet: return isActive ? DS.Colors.surface3.opacity(0.7) : .clear
        case .destructive: return DS.Colors.destructive.opacity(isActive ? 0.24 : 0.12)
        }
    }
}

extension View {
    /// Applies the compact capsule button style. See `DSCapsuleButtonStyle`.
    func dsCapsuleButtonStyle(
        _ role: DSCapsuleButtonStyle.Role = .secondary,
        height: CGFloat = DS.ControlSize.regular
    ) -> some View {
        self.buttonStyle(DSCapsuleButtonStyle(role: role, height: height))
    }
}

// MARK: - Button Styles

/// Primary button — the main call-to-action per screen.
/// Accent-colored background with white text. One per view maximum.
/// Used for: "start"/"resume", "let's go", "continue", "verify completion".
struct DSPrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false

    @State private var isHovered = false

    // Whether the hover glow shadow is active. Builds up gradually (0.6s)
    // on hover entry, fades out faster (0.3s) on exit.
    @State private var isHoverGlowActive = false

    // Continuously toggles while hovered to drive a gentle breathing pulse
    // in the glow shadow. Creates a living, organic feel — like the button
    // is softly glowing, not just statically lit.
    @State private var isGlowBreathingIn = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.controlLarge)
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .frame(minHeight: DS.ControlSize.large)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            // Hover glow — builds up gradually, then gently breathes while hovered.
            // The breathing oscillates opacity and radius on a slow 2.5s loop,
            // creating a candle-flame-like "alive" quality rather than a static highlight.
            .shadow(
                color: DS.Colors.accent.opacity(
                    isHoverGlowActive ? (isGlowBreathingIn ? 0.32 : 0.18) : 0
                ),
                radius: isHoverGlowActive ? (isGlowBreathingIn ? 16 : 10) : 0
            )
            // Press: snap down to 0.97. No hover swell — these sit in rows.
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                // Background color — fast snap so the button feels responsive
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }

                // Glow — builds up gradually on entry, fades faster on exit
                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverGlowActive = hovering
                }

                // Breathing glow loop — gentle pulse while hovered.
                // The 2.5s cycle keeps it feeling organic, not mechanical.
                if hovering {
                    withAnimation(
                        .easeInOut(duration: 2.5)
                        .repeatForever(autoreverses: true)
                    ) {
                        isGlowBreathingIn = true
                    }
                } else {
                    // Override the repeating animation with a finite one to stop cleanly
                    withAnimation(.easeOut(duration: 0.3)) {
                        isGlowBreathingIn = false
                    }
                }

                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            // Pressed: brighten slightly beyond hover
            return DS.Colors.accentHover.blendedWithWhite(fraction: DS.StateLayer.pressed)
        } else if isHovered {
            return DS.Colors.accentHover
        } else {
            return DS.Colors.accent
        }
    }
}

/// Secondary button — supporting actions, less visual weight than primary.
/// Surface-colored background with primary text. Used for: action buttons
/// (download, open link), embedded element buttons.
struct DSSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.controlLarge)
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.horizontal, isFullWidth ? 0 : 14)
            .frame(minHeight: DS.ControlSize.large)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

/// Tertiary/ghost button — low-emphasis actions with subtle hover background.
/// Transparent at rest, shows surface fill on hover. Used for: navigation
/// links, sidebar items, medium-low emphasis actions.
struct DSTertiaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.controlLarge)
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.accentHover
                    : isHovered
                        ? DS.Colors.accentText
                        : DS.Colors.textSecondary
            )
            .padding(.horizontal, 12)
            .frame(minHeight: DS.ControlSize.large)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return Color.clear
        }
    }
}

/// Text button — the lowest-emphasis button style. No background on any
/// state, not even hover. Only the text color changes. Used for: "restart",
/// "skip", "cancel", and other truly minimal inline actions where a
/// background would add too much visual weight.
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 13

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.custom("Avenir Next", size: fontSize).weight(.medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Outlined button — medium emphasis, used where a border helps define
/// the button's bounds. Used for: display selector, copy prompt.
struct DSOutlinedButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.controlLarge)
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.horizontal, isFullWidth ? 0 : 14)
            .frame(minHeight: DS.ControlSize.large)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return DS.Colors.surface1
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle
        }
    }
}

/// Destructive button — for dangerous/irreversible actions (close session, delete).
/// Red-tinted background that intensifies on hover and press.
struct DSDestructiveButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.controlLarge)
            .foregroundColor(
                isHovered || configuration.isPressed
                    ? .white
                    : DS.Colors.destructiveText
            )
            .padding(.horizontal, 14)
            .frame(minHeight: DS.ControlSize.large)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.destructive.opacity(0.40)
        } else if isHovered {
            return DS.Colors.destructive.opacity(0.30)
        } else {
            return DS.Colors.destructive.opacity(0.10)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.destructive.opacity(0.40)
        } else {
            return DS.Colors.destructive.opacity(0.15)
        }
    }
}

/// Icon-only button — compact circular button for utility actions.
/// Used for: close button (x), send message, small toolbar actions.
/// A borderless icon button for toolbars and message actions: no chrome at
/// rest, a soft fill on hover, and the whole square clickable rather than
/// just the glyph's pixels. `isActive` keeps the fill on for toggles.
struct DSToolbarIconButtonStyle: ButtonStyle {
    var size: CGFloat = DS.ControlSize.regular
    var isActive = false
    /// Fill for the active state when it should read as "on" (a mode, a
    /// live mic) rather than merely selected. Glyph turns `textOnAccent`.
    var activeFill: Color?
    var isDestructiveOnHover = false

    func makeBody(configuration: Configuration) -> some View {
        DSToolbarIconButtonBody(
            configuration: configuration,
            size: size,
            isActive: isActive,
            activeFill: activeFill,
            isDestructiveOnHover: isDestructiveOnHover
        )
    }
}

private struct DSToolbarIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let size: CGFloat
    let isActive: Bool
    let activeFill: Color?
    let isDestructiveOnHover: Bool

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
    }

    var body: some View {
        configuration.label
            .foregroundColor(foreground)
            .frame(width: size, height: size)
            .background(shape.fill(fill))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 && isEnabled }
            .pointerCursor(isEnabled: isEnabled)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
    }

    private var fill: Color {
        if isActive, let activeFill { return activeFill.opacity(configuration.isPressed ? 0.85 : 1) }
        if configuration.isPressed { return DS.Colors.surface3 }
        if isActive { return DS.Colors.surface3 }
        if isHovered { return DS.Colors.surface2 }
        return .clear
    }

    private var foreground: Color {
        if isActive && activeFill != nil { return DS.Colors.textOnAccent }
        if isHovered && isDestructiveOnHover { return DS.Colors.destructiveText }
        if isHovered || isActive { return DS.Colors.textPrimary }
        return DS.Colors.textSecondary
    }
}

extension View {
    /// Borderless icon button with a full-size hit area. See `DSToolbarIconButtonStyle`.
    func dsToolbarIconButtonStyle(
        size: CGFloat = DS.ControlSize.regular,
        isActive: Bool = false,
        activeFill: Color? = nil,
        isDestructiveOnHover: Bool = false
    ) -> some View {
        buttonStyle(DSToolbarIconButtonStyle(
            size: size,
            isActive: isActive,
            activeFill: activeFill,
            isDestructiveOnHover: isDestructiveOnHover
        ))
    }
}

struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isDestructiveOnHover: Bool = false
    var tooltipText: String? = nil

    /// Controls horizontal alignment of the tooltip relative to the button.
    /// Use `.leading` for buttons near the left edge of the window (tooltip extends right),
    /// `.trailing` for buttons near the right edge (tooltip extends left),
    /// and `.center` for buttons in the middle.
    var tooltipAlignment: Alignment = .center

    @State private var isHovered = false
    @State private var isTooltipVisible = false
    @State private var tooltipShowWorkItem: DispatchWorkItem? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundColor(iconColor(isPressed: configuration.isPressed))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(circleBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Circle()
                    .stroke(circleBorderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .contentShape(Circle())
            // Cursor change via AppKit cursor rects — more reliable than NSCursor.push/pop
            // because cursor rects are managed at the window level and don't conflict
            // with SwiftUI's internal cursor handling.
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
                // Show the tooltip after a delay (like native tooltips), hide immediately
                tooltipShowWorkItem?.cancel()
                if hovering {
                    let workItem = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isTooltipVisible = true
                        }
                    }
                    tooltipShowWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        isTooltipVisible = false
                    }
                }
            }
            // Custom styled tooltip — positioned above the button with enough gap
            // to not overlap the button. Horizontally aligned based on tooltipAlignment
            // so tooltips near window edges don't clip outside the visible area.
            // Uses .allowsHitTesting(false) so the tooltip doesn't interfere
            // with the button's hover state.
            .overlay(
                Group {
                    if isTooltipVisible, let text = tooltipText, !text.isEmpty {
                        Text(text)
                            .font(DS.Fonts.caption.weight(.medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(DS.Colors.surface3.opacity(0.85))
                            )
                            .overlay(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.20), lineWidth: 0.8)

                                    RoundedRectangle(cornerRadius: 6)
                                        .trim(from: 0, to: 0.5)
                                        .stroke(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.10),
                                                    Color.white.opacity(0.02)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.8
                                        )
                                }
                            )
                            .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 8)
                            .shadow(color: Color.black.opacity(0.26), radius: 4, x: 0, y: 2)
                            .fixedSize()
                            .offset(y: -(size / 2 + 20))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                },
                alignment: tooltipAlignment
            )
    }

    private func iconColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return .white
        }
        if isPressed {
            return DS.Colors.textPrimary
        } else if isHovered {
            return DS.Colors.textPrimary
        } else {
            return DS.Colors.textSecondary
        }
    }

    private func circleBackgroundColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover {
            if isPressed {
                return DS.Colors.destructive.opacity(0.40)
            } else if isHovered {
                return DS.Colors.destructive.opacity(0.30)
            } else {
                return DS.Colors.surface2
            }
        }
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }

    private func circleBorderColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return DS.Colors.destructive.opacity(0.30)
        }
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle.opacity(0.5)
        }
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// Applies the primary button style (accent-colored CTA).
    func dsPrimaryButtonStyle(isFullWidth: Bool = false) -> some View {
        self.buttonStyle(DSPrimaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the secondary button style (surface-colored supporting action).
    func dsSecondaryButtonStyle(isFullWidth: Bool = false) -> some View {
        self.buttonStyle(DSSecondaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the tertiary/ghost button style (subtle hover background).
    func dsTertiaryButtonStyle() -> some View {
        self.buttonStyle(DSTertiaryButtonStyle())
    }

    /// Applies the text-only button style (no background ever, just color change).
    func dsTextButtonStyle(fontSize: CGFloat = 13) -> some View {
        self.buttonStyle(DSTextButtonStyle(fontSize: fontSize))
    }

    /// Applies the outlined button style (bordered, medium emphasis).
    func dsOutlinedButtonStyle(isFullWidth: Bool = false) -> some View {
        self.buttonStyle(DSOutlinedButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the destructive button style (red-tinted danger action).
    func dsDestructiveButtonStyle() -> some View {
        self.buttonStyle(DSDestructiveButtonStyle())
    }

    /// Applies the icon-only button style (compact circle).
    /// `tooltipAlignment` controls where the tooltip sits horizontally relative to the button:
    /// `.leading` for left-edge buttons, `.trailing` for right-edge buttons, `.center` for middle.
    func dsIconButtonStyle(size: CGFloat = 28, isDestructiveOnHover: Bool = false, tooltip: String? = nil, tooltipAlignment: Alignment = .center) -> some View {
        self.buttonStyle(DSIconButtonStyle(size: size, isDestructiveOnHover: isDestructiveOnHover, tooltipText: tooltip, tooltipAlignment: tooltipAlignment))
    }

    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}


// MARK: - Native Tooltip

/// Uses AppKit's `NSView.toolTip` to show a tooltip on hover.
/// SwiftUI's `.help()` conflicts with `.onHover` tracking areas, so
/// this bridges directly to AppKit's tooltip system which works independently.
private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}

// MARK: - Color Utilities

extension Color {
    /// A color that resolves to `light` or `dark` depending on the
    /// *view hierarchy's* effective appearance, not just the system
    /// setting — the notch panel forces `.darkAqua` regardless of the
    /// user's system appearance, so this makes DS tokens stay put there
    /// while the desktop window (which follows the system) switches.
    init(light: String, dark: String) {
        let dynamic = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        }
        self.init(nsColor: dynamic)
    }

    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// Returns a lighter version of this color by blending toward white.
    /// `fraction` is 0.0 (no change) to 1.0 (pure white).
    func blendedWithWhite(fraction: Double) -> Color {
        // Convert to NSColor to access RGB components for blending
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }

    /// Returns a darker version of this color by blending toward black.
    /// `fraction` is 0.0 (no change) to 1.0 (pure black).
    func blendedWithBlack(fraction: Double) -> Color {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }
        let keep = 1.0 - fraction
        return Color(
            red: nsColor.redComponent * keep,
            green: nsColor.greenComponent * keep,
            blue: nsColor.blueComponent * keep
        )
    }
}
