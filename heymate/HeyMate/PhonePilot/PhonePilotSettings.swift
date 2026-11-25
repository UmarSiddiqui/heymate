import AppKit
import SwiftUI

struct PhonePilotSettings: View {
    @ObservedObject var worker: PhonePilotWorker
    @State private var confirmsUnpair = false

    var body: some View {
        SettingsSection("iPhone companion", footer: "HeyMate handles requests when this Mac is awake and online. Sensitive action approvals stay on the Mac.") {
            if worker.isPaired {
                SettingsRow("iPhone paired", subtitle: pairingSummary, systemImage: "iphone") {
                    Menu {
                        Button("Unpair iPhone…", role: .destructive) { confirmsUnpair = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("iPhone pairing options")
                }
                if worker.needsPairingUpgrade {
                    SettingsRow("Share your full workspace", subtitle: Self.workspaceAccess) {
                        Button("Enable workspace access") { worker.upgradePairing() }.dsCapsuleButtonStyle(.secondary)
                    }
                }
            } else if let code = worker.invitation, let expires = worker.expiresAt {
                HStack(alignment: .top, spacing: 16) {
                    if let image = SettingsPhoneAccessSection.qrImage(code) {
                        Image(nsImage: image).interpolation(.none).resizable()
                            .frame(width: 190, height: 190)
                            .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("iPhone workspace pairing QR code")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan in HeyMate for iPhone.").font(.headline)
                        Text("Keep this code private. It expires at \(expires.formatted(date: .omitted, time: .shortened)).")
                            .foregroundStyle(.secondary)
                        Button("Copy pairing code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                        Button("Cancel") { worker.disconnect() }
                    }
                }
                .settingsRowContentInsets()
                .padding(.vertical, 12)
            } else {
                SettingsRow("Pair iPhone", subtitle: Self.workspaceAccess, systemImage: "iphone") {
                    Button("Show pairing code", action: worker.invite)
                        .dsCapsuleButtonStyle(.secondary)
                }
            }
            if !worker.isPaired {
                SettingsRow("HeyMate for iPhone beta", subtitle: "Chat with your mates from your iPhone.") {
                    Link("Request beta access", destination: Self.betaURL)
                        .dsCapsuleButtonStyle(.secondary)
                }
            }
            if let problem = worker.problem {
                SettingsInlineHelp(problem, tone: .attention).settingsRowContentInsets()
            }
        }
        .settingsAnchor(.iphoneCompanion)
        .confirmationDialog("Unpair this iPhone?", isPresented: $confirmsUnpair) {
            Button("Unpair iPhone", role: .destructive) { worker.disconnect() }
        } message: {
            Text("This iPhone will need a new pairing code to access your HeyMate workspace.")
        }
    }

    private var pairingSummary: String {
        let access = worker.needsPairingUpgrade
            ? "Uses the earlier sharing settings."
            : "Workspace access enabled."
        guard let lastSync = worker.lastSuccessfulSync else { return access }
        return "\(access) Last successful sync \(lastSync.formatted(.relative(presentation: .named)))."
    }

    private static let betaURL = URL(string: "https://sayheymate.com/ios-beta")!
    private static let workspaceAccess = "This iPhone can access chats, profiles, routines, and questions for HeyMate and all active mates, including mates you add later, and send requests."
}
