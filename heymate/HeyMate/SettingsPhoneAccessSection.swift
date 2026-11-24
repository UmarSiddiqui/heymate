//
//  SettingsPhoneAccessSection.swift
//  HeyMate
//
//  Settings › Devices › Local browser access: the one switch for
//  RemoteAccessController, pairing (code + QR), paired phones with Revoke,
//  and the last few things a phone did. The copy says plainly what turning
//  it on exposes and that the connection is unencrypted.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsPhoneAccessSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var phone = RemoteAccessController.shared

    static let exposes = "A paired phone on the same Wi-Fi can see your Inbox and each mate's status, approve or skip proposals, answer questions, and send short messages. It can't approve actions, change settings, sign in, or see files or memory."

    static let honesty = "Plain, unencrypted HTTP on your local network: anyone else on the same Wi-Fi could read what crosses it and copy a paired phone's sign-in. Use it on networks you trust. Works on the same Wi-Fi, or over your own VPN such as Tailscale. Never reachable from the internet, and not while this Mac sleeps or HeyMate is closed. Turning it off unpairs every phone."

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        SettingsSection("Local browser access", footer: Self.honesty) {
            SettingsToggleRow(
                SettingsItem.phoneAccess.title,
                subtitle: Self.exposes,
                item: .phoneAccess,
                isOn: Binding(get: { phone.isEnabled }, set: { phone.setEnabled($0) })
            )
            if let problem = phone.problem {
                SettingsInlineHelp(problem, tone: .critical)
                    .settingsRowContentInsets()
            }
            if phone.isEnabled {
                SettingsDivider()
                SettingsRow("Address", subtitle: phone.pageURL ?? "Not on a local network. Join Wi-Fi to pair a browser.") {
                    Button("Pair a browser…") { phone.startPairing() }
                        .dsCapsuleButtonStyle(.secondary)
                        .disabled(phone.pageURL == nil)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    pairingPanel(now: context.date)
                }
                SettingsDivider()
                devicesList
                if !phone.log.isEmpty {
                    SettingsDivider()
                    recentActions
                }
            }
        }
        .settingsAnchor(.phoneAccess)
        .onAppear {
            phone.attach(companionManager)
            phone.refreshAddress()
        }
    }

    @ViewBuilder
    private func pairingPanel(now: Date) -> some View {
        if phone.pairing.isActive(now: now), let code = phone.pairing.code, let expires = phone.pairing.expiresAt {
            HStack(alignment: .top, spacing: DS.Spacing.lg) {
                if let url = phone.pairingURL, let image = Self.qrImage(url) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 132, height: 132)
                        .padding(DS.Spacing.sm)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("QR code to pair a browser")
                }
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("Pairing code")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("\(String(code.prefix(4))) \(String(code.dropFirst(4)))")
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .textSelection(.enabled)
                    Text("Single use. Expires in \(Self.countdown(expires.timeIntervalSince(now))).")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Scan with your phone's Camera app to open the browser, or open \(phone.pageURL ?? "the address above") and type the code. For the HeyMate iPhone app, use iPhone companion above.")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel") { phone.cancelPairing() }
                        .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                        .padding(.top, DS.Spacing.xs)
                }
            }
            .settingsRowContentInsets()
            .padding(.vertical, DS.Spacing.sm)
        } else if phone.pairing.isLockedOut(now: now) {
            SettingsInlineHelp("Pairing paused after too many wrong codes. Make a new code to try again.", tone: .attention)
                .settingsRowContentInsets()
        }
    }

    @ViewBuilder
    private var devicesList: some View {
        if phone.devices.isEmpty {
            SettingsRow("Paired browsers", subtitle: "None yet.") { EmptyView() }
        } else {
            ForEach(phone.devices) { device in
                SettingsRow(device.name, subtitle: "Paired \(Self.relative.localizedString(for: device.pairedAt, relativeTo: Date())) · last seen \(Self.relative.localizedString(for: device.lastSeenAt, relativeTo: Date()))", systemImage: "iphone") {
                    Button("Revoke") { phone.revoke(device.id) }
                        .dsCapsuleButtonStyle(.destructive, height: DS.ControlSize.small)
                        .accessibilityLabel("Unpair \(device.name)")
                }
            }
        }
    }

    private var recentActions: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Recent phone activity")
                .font(DS.Fonts.headline)
                .foregroundColor(DS.Colors.textPrimary)
            ForEach(phone.log.prefix(5)) { entry in
                Text("\(Self.relative.localizedString(for: entry.date, relativeTo: Date())) · \(entry.device): \(entry.action)")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
        .settingsRowContentInsets()
        .padding(.vertical, DS.Spacing.sm)
    }

    private static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
