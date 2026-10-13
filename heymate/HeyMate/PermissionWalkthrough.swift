//
//  PermissionWalkthrough.swift
//  HeyMate
//
//  First-run permissions, one at a time. Each page says what HeyMate can do
//  with the permission and what it never does, then asks. A granted page
//  ticks over to a check and moves on by itself; "Not now" moves on too, so
//  nothing here blocks setup. The full list stays one tap away ("See all")
//  and in Settings › Privacy & Data.
//
//      microphone → speech → accessibility → input monitoring
//                 → screen recording → done (optional extras)
//
//  Asking still goes through PermissionGuide, so a page never prompts on
//  its own: only the Allow button asks.
//

import AppKit
import SwiftUI

/// Which pages the walkthrough shows, worked out once when it opens so
/// pages don't vanish under the person as they grant things.
enum PermissionWalkthroughPlan {
    /// Core permissions still off, quick system prompts first and the ones
    /// that need System Settings last.
    static func steps(alreadyGranted: Set<HeyMatePermission>) -> [HeyMatePermission] {
        HeyMatePermission.allowAllOrder(includeExtras: false).filter { !alreadyGranted.contains($0) }
    }
}

extension HeyMatePermission {
    /// What HeyMate never does with this, said next to the Allow button.
    var privacyNote: String {
        switch self {
        case .microphone: return "Only while you hold the shortcut. Nothing is recorded or kept."
        case .speech: return "Used to turn your words into text, nothing else."
        case .accessibility: return "Only acts when you ask it to. You can stop it any time."
        case .inputMonitoring: return "Listens for the shortcut only. Your typing is never read."
        case .screenRecording: return "Only when you press the shortcut. Screenshots are never stored."
        case .notifications: return "Only for things you asked HeyMate to do."
        case .calendar: return "Read when you ask about your schedule. Never shared."
        case .reminders: return "Read when you ask about your reminders. Never shared."
        case .contacts: return "Looked up when you mention someone. Never shared."
        }
    }
}

struct PermissionWalkthrough: View {
    @ObservedObject var guide: PermissionGuide = .shared
    /// Called from the last page's Continue.
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var steps: [HeyMatePermission]?
    @State private var index = 0
    /// The Allow button was pressed on a permission macOS only grants in
    /// System Settings; the page now waits for the switch.
    @State private var isWaitingInSettings = false
    @State private var isAsking = false
    @State private var isShowingFullList = false
    @State private var isAskingExtras = false

    /// Pages slide and settle on this spring.
    private static let pageSpring = Animation.spring(response: 0.42, dampingFraction: 0.84)
    /// How long a granted page shows its check before moving on.
    private static let grantedHold: Duration = .milliseconds(750)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isShowingFullList {
                PermissionChecklist(compact: true)
                footer(primaryTitle: guide.allGranted(HeyMatePermission.core) ? "Continue" : "Continue for now", primary: onFinish)
            } else if let steps {
                progressRow(steps)
                ZStack(alignment: .topLeading) {
                    if index < steps.count {
                        stepPage(steps[index])
                            .id(steps[index])
                            .transition(pageTransition)
                    } else {
                        donePage
                            .transition(pageTransition)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            guide.startWatching()
            if steps == nil {
                steps = PermissionWalkthroughPlan.steps(alreadyGranted: guide.granted)
            }
        }
        .onDisappear { guide.stopWatching() }
        .task(id: currentGranted) {
            guard currentGranted else { return }
            try? await Task.sleep(for: Self.grantedHold)
            guard !Task.isCancelled else { return }
            advance()
        }
    }

    // MARK: Steps

    private var current: HeyMatePermission? {
        guard let steps, index < steps.count else { return nil }
        return steps[index]
    }

    private var currentGranted: Bool {
        current.map(guide.isGranted) ?? false
    }

    private func advance() {
        isWaitingInSettings = false
        withAnimation(accessibilityReduceMotion ? DS.Animation.reducedMotionFade : Self.pageSpring) {
            index += 1
        }
    }

    private func allow(_ permission: HeyMatePermission) {
        guard !isAsking else { return }
        isAsking = true
        Task {
            await guide.request(permission)
            isAsking = false
            guard !guide.isGranted(permission), current == permission else { return }
            if permission.isGrantedInSystemSettings {
                // macOS sends the person to System Settings; the poll in
                // PermissionGuide notices the switch and the page moves on.
                withAnimation(.easeOut(duration: DS.Animation.normal)) { isWaitingInSettings = true }
            } else {
                // Declined in the system prompt. Respect it and move on.
                advance()
            }
        }
    }

    private var pageTransition: AnyTransition {
        if accessibilityReduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 28).combined(with: .opacity).combined(with: .softBlur),
            removal: .offset(x: -28).combined(with: .opacity).combined(with: .softBlur)
        )
    }

    // MARK: Progress

    /// One dot per page: green once granted, a stretched accent dot for the
    /// page you are on.
    private func progressRow(_ steps: [HeyMatePermission]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.element) { offset, permission in
                    let isCurrent = offset == index
                    Capsule(style: .continuous)
                        .fill(dotColor(permission, isCurrent: isCurrent, isPast: offset < index))
                        .frame(width: isCurrent ? 16 : 6, height: 6)
                }
            }
            .animation(accessibilityReduceMotion ? nil : DS.Animation.controlSpring, value: index)
            .animation(.easeOut(duration: DS.Animation.normal), value: guide.granted)
            .accessibilityElement()
            .accessibilityLabel(index < steps.count ? "Step \(index + 1) of \(steps.count)" : "All steps done")

            Spacer(minLength: 8)
            Button("See all") {
                withAnimation(.easeInOut(duration: DS.Animation.normal)) { isShowingFullList = true }
            }
            .buttonStyle(.plain)
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textTertiary)
            .pointerCursor()
            .help("Show every permission in one list")
        }
    }

    private func dotColor(_ permission: HeyMatePermission, isCurrent: Bool, isPast: Bool) -> Color {
        if guide.isGranted(permission) { return DS.Colors.success }
        if isCurrent { return DS.Colors.accent }
        return isPast ? DS.Colors.textTertiary.opacity(0.6) : DS.Colors.surface4
    }

    // MARK: Pages

    private func stepPage(_ permission: HeyMatePermission) -> some View {
        let isOn = guide.isGranted(permission)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                PermissionBadge(systemImage: permission.systemImage, isGranted: isOn, isWaiting: isWaitingInSettings)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title)
                        .font(DS.Fonts.title)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(isOn ? permission.onText : "So " + lowercasedFirst(permission.onText))
                        .font(DS.Fonts.caption)
                        .foregroundColor(isOn ? DS.Colors.success : DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.textTertiary)
                Text(permission.privacyNote)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isWaitingInSettings && !isOn {
                settingsWaitNote(permission)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !isOn {
                footer(
                    primaryTitle: isWaitingInSettings ? "Open Settings again" : (isAsking ? "Asking…" : "Allow"),
                    primary: { allow(permission) },
                    secondaryTitle: isWaitingInSettings ? "Skip" : "Not now",
                    secondary: advance
                )
            }
        }
    }

    private func settingsWaitNote(_ permission: HeyMatePermission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Turn on HeyMate under \(permission.title) in System Settings. This moves on by itself.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if permission == .accessibility || permission == .screenRecording {
                NotchAppDropTile(
                    missingAccessibility: permission == .accessibility,
                    missingScreenRecording: permission == .screenRecording
                )
            }
        }
    }

    private var donePage: some View {
        let core = HeyMatePermission.core
        let onCount = core.filter(guide.isGranted).count
        let missingExtras = HeyMatePermission.extras.filter { !guide.isGranted($0) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                PermissionBadge(systemImage: "sparkles", isGranted: onCount == core.count, isWaiting: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(onCount == core.count ? "You're all set" : "\(onCount) of \(core.count) on")
                        .font(DS.Fonts.title)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(onCount == core.count
                        ? "HeyMate can hear, see, and help."
                        : "You can turn the rest on later in Settings › Privacy & Data.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !missingExtras.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(DS.Glyph.small)
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("Also useful: " + missingExtras.map(\.title).joined(separator: ", "))
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button(isAskingExtras ? "Asking…" : "Allow") {
                        isAskingExtras = true
                        Task {
                            for permission in missingExtras where !guide.isGranted(permission) {
                                await guide.request(permission)
                            }
                            isAskingExtras = false
                        }
                    }
                    .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                    .disabled(isAskingExtras)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .dsSurface(.row)
            }

            footer(primaryTitle: "Continue", primary: onFinish)
        }
    }

    // MARK: Pieces

    private func footer(
        primaryTitle: String,
        primary: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondary: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Button(primaryTitle, action: primary)
                .dsCapsuleButtonStyle(.primary)
                .disabled(isAsking)
            if let secondaryTitle, let secondary {
                Button(secondaryTitle, action: secondary)
                    .dsCapsuleButtonStyle(.quiet)
            }
            Spacer(minLength: 0)
            Button("Why?") {
                if let url = URL(string: SupportLinks.permissionsPageURLString) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textTertiary)
            .pointerCursor()
            .help("Why HeyMate asks for these permissions")
        }
        .padding(.top, 2)
    }

    private func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // "HeyMate can…" keeps its capital; anything else reads mid-sentence.
        return text.hasPrefix("HeyMate") ? text : first.lowercased() + text.dropFirst()
    }
}

/// The round icon at the top of each page. It breathes a soft ring while it
/// waits on you or System Settings, and pops into a green check when the
/// permission comes on.
private struct PermissionBadge: View {
    let systemImage: String
    let isGranted: Bool
    let isWaiting: Bool

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var ringPhase = false
    @State private var pop = false

    private let size: CGFloat = 44

    var body: some View {
        ZStack {
            if !isGranted && !accessibilityReduceMotion {
                Circle()
                    .stroke(DS.Colors.accent.opacity(0.55), lineWidth: 1.5)
                    .scaleEffect(ringPhase ? 1.45 : 1)
                    .opacity(ringPhase ? 0 : (isWaiting ? 0.9 : 0.6))
                    .animation(
                        .easeOut(duration: isWaiting ? 1.1 : 1.8).repeatForever(autoreverses: false),
                        value: ringPhase
                    )
            }
            Circle()
                .fill(isGranted ? DS.Colors.success.opacity(0.18) : DS.Colors.accent.opacity(0.16))
            Circle()
                .stroke(isGranted ? DS.Colors.success.opacity(0.45) : DS.Colors.accent.opacity(0.35), lineWidth: 1)
            Image(systemName: isGranted ? "checkmark" : systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(isGranted ? DS.Colors.success : DS.Colors.accentText)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .scaleEffect(pop ? 1.14 : 1)
        .animation(.easeOut(duration: DS.Animation.normal), value: isGranted)
        .onAppear { ringPhase = true }
        .onChange(of: isGranted) { _, granted in
            guard granted, !accessibilityReduceMotion else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { pop = true }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.7).delay(0.16)) { pop = false }
        }
        .accessibilityHidden(true)
    }
}

private struct SoftBlur: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

private extension AnyTransition {
    /// Pages blur slightly as they leave and come into focus as they land.
    static var softBlur: AnyTransition {
        .modifier(active: SoftBlur(radius: 5), identity: SoftBlur(radius: 0))
    }
}
