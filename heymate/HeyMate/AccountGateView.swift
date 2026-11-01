import AppKit
import GoogleSignInSwift
import SwiftUI

struct AccountGateView: View {
    @ObservedObject var account: HeyMateAccount
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Text("Welcome to HeyMate")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 96)

            GoogleSignInButton(scheme: colorScheme == .dark ? .dark : .light, style: .wide,
                               state: account.busy ? .disabled : .normal) {
                Task { await account.signInWithGoogle(using: GoogleAccountSignIn()) }
            }
            .disabled(account.busy)
            .accessibilityLabel("Sign in with Google")
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if account.busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in with Google…").font(.callout).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
                if let message = account.message {
                    Text(message)
                        .font(.callout).foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel(message)
                }
            }
            .padding(16)
        }
        .background {
            AccountWelcomeBackground()
                .ignoresSafeArea()
        }
    }
}

private struct AccountWelcomeBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            // Keep the supplied artwork intact; show its matching half without stretching.
            let scale = max(geometry.size.width / 1376, geometry.size.height / 1536)
            let halfWidth = 1376 * scale
            let imageHeight = 1536 * scale

            Image("AccountWelcomeSky")
                .resizable()
                .frame(width: halfWidth * 2, height: imageHeight)
                .offset(x: (geometry.size.width - halfWidth) / 2 - (colorScheme == .dark ? halfWidth : 0),
                        y: (geometry.size.height - imageHeight) / 2)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
final class AccountGateWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(account: HeyMateAccount) {
        if window == nil {
            let height = min(440, (NSScreen.main?.visibleFrame.height ?? 900) - 60)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: height),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Welcome to HeyMate"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
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
