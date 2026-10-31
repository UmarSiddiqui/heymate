//
//  NotchPermissionFlow.swift
//  HeyMate
//
//  Missing permissions, asked for one at a time right in the notch: what
//  the switch is for, Allow, a live wait while System Settings is open,
//  a tick when it turns on, then the next one. The settings window only
//  opens when macOS insists on it.
//

import SwiftUI

struct NotchPermissionFlow: View {
    @ObservedObject var guide: PermissionGuide
    /// The full checklist, for anyone who wants every switch at once.
    var openChecklist: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The permission whose request is in flight or whose switch we wait on.
    @State private var asking: HeyMatePermission?
    /// Shown with a tick for a moment after its switch turns on.
    @State private var justGranted: HeyMatePermission?
    /// Turned on while this flow was showing, for the progress dots.
    @State private var grantedHere: [HeyMatePermission] = []
    /// "Later" hides a permission until the notch opens again.
    @State private var skipped: Set<HeyMatePermission> = []
    @State private var tickTask: Task<Void, Never>?

    /// Shortcut-breaking permissions first, as everywhere else.
    private var queue: [HeyMatePermission] {
        let off = HeyMatePermission.core.filter { !guide.isGranted($0) && !skipped.contains($0) }
        return off.filter(\.breaksShortcuts) + off.filter { !$0.breaksShortcuts }
    }

    var body: some View {
        Group {
            if let justGranted {
                grantedRow(justGranted)
            } else if let current = queue.first {
                askRow(current)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: queue.first)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: justGranted)
        .onChange(of: guide.granted) { old, new in
            guard let turnedOn = new.subtracting(old).first(where: HeyMatePermission.core.contains) else { return }
            if asking == turnedOn { asking = nil }
            guide.endCoaching(turnedOn, unlessGranted: true)
            grantedHere.append(turnedOn)
            justGranted = turnedOn
            tickTask?.cancel()
            tickTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                justGranted = nil
            }
        }
        .onDisappear { tickTask?.cancel() }
    }

    // MARK: Rows

    private func askRow(_ permission: HeyMatePermission) -> some View {
        let isWaiting = asking == permission
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: permission.systemImage)
                    .font(DS.Glyph.small)
                    .foregroundStyle(DS.Colors.warningText)
                    .frame(width: 16)
                Text("Turn on \(permission.title)")
                    .font(DS.Fonts.caption.weight(.semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                progressDots
                Button(action: openChecklist) {
                    Image(systemName: "chevron.right").font(DS.Glyph.micro)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Colors.textTertiary)
                .pointerCursor()
                .help("All permissions")
                .accessibilityLabel("Show all permissions")
            }
            HStack(spacing: 8) {
                if isWaiting && permission.isGrantedInSystemSettings {
                    ProgressView().controlSize(.mini)
                    Text("Switch HeyMate on in System Settings")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Skip") { skip(permission) }
                        .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                } else {
                    Text(permission.breaksShortcuts ? "Needed for ⌃⌥ to work." : permission.purpose)
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Later") { skip(permission) }
                        .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                    Button("Allow") { allow(permission) }
                        .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.small)
                        .disabled(isWaiting)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large).fill(DS.Colors.notchWellFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(permission.offText). Turn on \(permission.title)")
        .help(permission.settingsHint ?? permission.purpose)
    }

    private func grantedRow(_ permission: HeyMatePermission) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(DS.Glyph.small)
                .foregroundStyle(DS.Colors.textPrimary)
            Text(queue.isEmpty ? "All set. Hold ⌃⌥ and ask." : "\(permission.title) is on")
                .font(DS.Fonts.caption.weight(.semibold))
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer(minLength: 4)
            progressDots
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large).fill(DS.Colors.notchWellFill))
        .accessibilityElement(children: .combine)
    }

    /// One dot per permission this flow covers; filled once it's on.
    private var progressDots: some View {
        let total = grantedHere.count + queue.count
        return HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < grantedHere.count ? DS.Colors.textPrimary : DS.Colors.textTertiary.opacity(0.5))
                    .frame(width: 5, height: 5)
            }
        }
        .opacity(total > 1 ? 1 : 0)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func allow(_ permission: HeyMatePermission) {
        asking = permission
        Task { @MainActor in
            await guide.request(permission)
            // A one-time prompt has its answer now; only System Settings
            // switches keep us waiting.
            if !permission.isGrantedInSystemSettings || guide.isGranted(permission) {
                if asking == permission { asking = nil }
            }
        }
    }

    private func skip(_ permission: HeyMatePermission) {
        if asking == permission { asking = nil }
        guide.endCoaching(permission)
        skipped.insert(permission)
    }
}
