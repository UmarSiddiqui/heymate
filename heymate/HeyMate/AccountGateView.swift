import AppKit
import GoogleSignInSwift
import SwiftUI

struct AccountGateView: View {
    @ObservedObject var account: HeyMateAccount

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().interpolation(.high).frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("HeyMate").font(.system(size: 19, weight: .semibold))
                        Text("A little company. A lot of help.")
                            .font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Meet your new mate.")
                        .font(.system(size: 31, weight: .semibold, design: .rounded)).tracking(-0.7)
                    Text("One quick sign-in. Then, make yourself at home.")
                        .font(.system(size: 14)).lineSpacing(3).foregroundStyle(DS.Colors.textSecondary)
                }.padding(.top, 12)

                VStack(alignment: .leading, spacing: 16) {
                    GoogleSignInButton(scheme: .light, style: .wide,
                                       state: account.busy ? .disabled : .normal) {
                        Task { await account.signInWithGoogle(using: GoogleAccountSignIn()) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Sign in with Google")
                    Text("New here or coming back? Same button. Google provides your name and email.")
                        .font(.system(size: 12)).lineSpacing(3).foregroundStyle(DS.Colors.textSecondary)
                }

                if account.busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in with Google…").font(.callout).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
                if let message = account.message {
                    Label(message, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(DS.Colors.textPrimary)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel(message)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    Label("No access to your Gmail inbox.", systemImage: "lock.shield")
                        .font(.system(size: 12, weight: .medium))
                    Text("Google and Firebase handle account sign-in. Chats, screenshots and files stay outside this account flow. Your AI provider sign-ins stay separate.")
                        .font(.system(size: 11)).lineSpacing(3).foregroundStyle(DS.Colors.textSecondary)
                    Link("Privacy notes", destination: URL(string: "https://getheymate.vercel.app/privacy")!)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(32)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
        .tint(DS.Colors.accent)
    }
}

@MainActor
final class AccountGateWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(account: HeyMateAccount) {
        if window == nil {
            let height = min(550, (NSScreen.main?.visibleFrame.height ?? 900) - 60)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: height),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "HeyMate account"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AccountGateView(account: account))
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

struct AccountPreferencesView: View {
    @ObservedObject var account: HeyMateAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account.session?.email ?? "HeyMate account").font(.headline).textSelection(.enabled)
            Text(account.access == .offlineGrace ? "Previously verified · offline access" : "Verified email")
                .foregroundStyle(.secondary)
            Toggle("Email me about HeyMate releases", isOn: Binding(
                get: { account.session?.pendingReleaseEmails ?? account.session?.releaseEmails ?? false },
                set: { value in Task { await account.updateReleaseEmails(value) } }))
            Text("Optional subscription preference. Release email delivery is not connected yet. Usage analytics is a separate choice below.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = account.preferenceMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
            if let message = account.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Refresh account & retry sync") { Task { await account.checkVerification() } }
                Button("Sign out & quit") { account.requestSignOut?() }
            }
            if account.busy { ProgressView().controlSize(.small) }
        }
        .disabled(account.busy)
        .padding(16)
    }
}
