import Combine
import Foundation
import Security

@MainActor
protocol AccountSessionStoring {
    func read() throws -> FirebaseAccountTokens?
    func save(_ tokens: FirebaseAccountTokens) throws
    func clear() throws
}

/// Dedicated service: never shares account tokens with connector credentials.
@MainActor
final class AccountKeychainStore: AccountSessionStoring {
    private let service = "com.heymate.account.firebase.v1"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "session"]
    }

    func read() throws -> FirebaseAccountTokens? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let tokens = try? JSONDecoder().decode(FirebaseAccountTokens.self, from: data) else {
            throw FirebaseAccountError.persistence
        }
        return tokens
    }

    func save(_ tokens: FirebaseAccountTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw FirebaseAccountError.persistence }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw FirebaseAccountError.persistence }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw FirebaseAccountError.persistence }
    }
}

@MainActor
final class HeyMateAccount: ObservableObject {
    static let shared = HeyMateAccount()
    enum Access: Equatable { case locked, verified, offlineGrace }
    @Published private(set) var access: Access = .locked
    @Published private(set) var session: FirebaseAccountTokens?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var preferenceMessage: String?
    @Published private(set) var resendAvailableAt = Date.distantPast
    var mayUseApp: Bool { access != .locked }
    var onAccessChange: ((Bool) -> Void)?
    var requestSignOut: (() -> Void)?

    private let client: any FirebaseAccountServing
    private let store: any AccountSessionStoring
    private let now: () -> Date
    private var offlineExpiryTask: Task<Void, Never>?

    init(client: (any FirebaseAccountServing)? = nil, store: (any AccountSessionStoring)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.client = client ?? FirebaseAccountClient()
        self.store = store ?? AccountKeychainStore()
        self.now = now
    }

    func restore() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            session = try store.read()
            guard session != nil else { return }
            try await refreshSession()
        } catch { handle(error, allowOffline: true) }
    }

    func authenticate(email: String, password: String, create: Bool, releaseEmails: Bool) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            var tokens = try await client.authenticate(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, create: create)
            // Sign-in loads existing cloud consent; it must never overwrite it
            // with a fresh form's default unchecked value.
            if create { tokens.pendingReleaseEmails = releaseEmails }
            try store.save(tokens)
            session = tokens
            if tokens.verifiedAt != nil {
                await syncPreferences()
                setAccess(.verified)
            } else {
                setAccess(.locked)
                try await sendVerificationEmail()
            }
        } catch { handle(error, allowOffline: false) }
    }

    func signInWithGoogle(using google: any GoogleAccountSigningIn) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let googleToken = try await google.idToken()
            let tokens = try await client.authenticateGoogle(idToken: googleToken)
            guard tokens.verifiedAt != nil else { throw FirebaseAccountError.unverified }
            try store.save(tokens)
            session = tokens
            // Existing subscriptions survive; new accounts default to no release mail.
            await syncPreferences()
            setAccess(.verified)
        } catch is CancellationError {
            // Cancelling the account picker leaves the gate available to retry.
        } catch { handle(error, allowOffline: false) }
    }

    func checkVerification() async {
        guard !busy, session != nil else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await refreshSession()
            if !mayUseApp { message = FirebaseAccountError.unverified.localizedDescription }
        } catch { handle(error, allowOffline: true) }
    }

    private func refreshSession() async throws {
        guard let previous = session else { return }
        let updated = try await client.refresh(previous)
        try store.save(updated)
        session = updated
        if updated.verifiedAt != nil {
            await syncPreferences()
            setAccess(.verified)
            message = nil
        } else {
            setAccess(.locked)
        }
    }

    func resendVerification() async {
        guard !busy, session != nil, now() >= resendAvailableAt else { return }
        busy = true
        defer { busy = false }
        do {
            guard let tokens = session else { return }
            let updated = try await client.refresh(tokens)
            try store.save(updated)
            session = updated
            if updated.verifiedAt != nil {
                await syncPreferences()
                setAccess(.verified)
            } else { try await sendVerificationEmail() }
        } catch { handle(error, allowOffline: false) }
    }

    private func sendVerificationEmail() async throws {
        guard let tokens = session else { return }
        try await client.sendVerification(tokens)
        resendAvailableAt = now().addingTimeInterval(60)
        message = "Verification email sent. Check your inbox and spam folder, open the link, then return here."
    }

    func resetPassword(email: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.sendPasswordReset(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
            message = "If this email has an account, a password reset link has been sent."
        } catch { handle(error, allowOffline: false) }
    }

    func updateReleaseEmails(_ value: Bool) async {
        guard !busy, mayUseApp, var tokens = session else { return }
        busy = true
        defer { busy = false }
        do {
            // Durable intent first: a failed request is retried after restart.
            tokens.pendingReleaseEmails = value
            try store.save(tokens)
            session = tokens
            try await refreshSession()
        } catch {
            preferenceMessage = FirebaseAccountError.consent.localizedDescription
            handle(error, allowOffline: true)
        }
    }

    private func syncPreferences() async {
        guard var tokens = session else { return }
        do {
            if let pending = tokens.pendingReleaseEmails {
                try await client.writeReleaseEmails(pending, tokens: tokens)
                tokens.releaseEmails = pending
                tokens.pendingReleaseEmails = nil
            } else {
                tokens.releaseEmails = try await client.readReleaseEmails(tokens)
            }
            try store.save(tokens)
            session = tokens
            preferenceMessage = nil
        } catch {
            preferenceMessage = FirebaseAccountError.consent.localizedDescription
        }
    }

    /// Clears this Mac's session only; other Macs and cloud accounts survive.
    @discardableResult
    func signOut() -> Bool {
        guard !busy else { return false }
        do {
            try store.clear()
            session = nil
            message = nil
            preferenceMessage = nil
            setAccess(.locked)
            return true
        } catch { message = FirebaseAccountError.persistence.localizedDescription; return false }
    }

    private func setAccess(_ value: Access) {
        offlineExpiryTask?.cancel()
        offlineExpiryTask = nil
        let wasAllowed = mayUseApp
        access = value
        if value == .offlineGrace, let verifiedAt = session?.verifiedAt {
            let remaining = max(1, verifiedAt.addingTimeInterval(7 * 86400).timeIntervalSince(now()) + 1)
            offlineExpiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                guard let self, self.access == .offlineGrace else { return }
                self.message = "Offline access expired. Connect and sign in again to continue."
                self.setAccess(.locked)
            }
        }
        if wasAllowed != mayUseApp { onAccessChange?(mayUseApp) }
    }

    private func handle(_ error: Error, allowOffline: Bool) {
        if error as? FirebaseAccountError == .expired {
            // Known revocation always wins over offline grace.
            _ = try? store.clear()
            session = nil
            setAccess(.locked)
        } else if allowOffline, let error = error as? URLError,
                  [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code),
                  session?.permitsOfflineUse(at: now()) == true {
            setAccess(.offlineGrace)
            message = "Offline access: your email was previously verified. Connect within 7 days of your last verification to renew this session."
            return
        } else if allowOffline { setAccess(.locked) }
        // Never show raw provider responses, URLs containing keys, or tokens.
        message = (error as? FirebaseAccountError)?.localizedDescription
            ?? "Could not reach Firebase. Check your connection and try again."
    }
}

#if DEBUG
// Isolated visual fixtures: no real Keychain, usable tokens, or network configuration.
extension HeyMateAccount {
    static func designPreview(verification: Bool) -> HeyMateAccount {
        let account = HeyMateAccount(client: FirebaseAccountClient(configuration: nil),
                                     store: AccountDesignPreviewStore())
        if verification {
            account.session = FirebaseAccountTokens(uid: "design-preview", email: "you@example.com",
                refreshToken: "", idToken: "", verifiedAt: nil)
        }
        return account
    }
}

@MainActor
private final class AccountDesignPreviewStore: AccountSessionStoring {
    func read() throws -> FirebaseAccountTokens? { nil }
    func save(_ tokens: FirebaseAccountTokens) throws { }
    func clear() throws { }
}
#endif
