import Foundation
import Testing
@testable import HeyMate

@MainActor
private final class MemoryAccountStore: AccountSessionStoring {
    var tokens: FirebaseAccountTokens?
    var fails = false
    func read() throws -> FirebaseAccountTokens? {
        if fails { throw FirebaseAccountError.persistence }
        return tokens
    }
    func save(_ tokens: FirebaseAccountTokens) throws {
        if fails { throw FirebaseAccountError.persistence }
        self.tokens = tokens
    }
    func clear() throws {
        if fails { throw FirebaseAccountError.persistence }
        tokens = nil
    }
}

@MainActor
private final class AccountServiceFixture: FirebaseAccountServing {
    var result = FirebaseAccountTokens(uid: "test-user", email: "tester@example.invalid", refreshToken: "refresh", idToken: "id")
    var refreshError: Error?
    var preferenceError: Error?
    var subscribed = true
    var writes: [Bool] = []
    var verificationEmails = 0
    var googleToken: String?
    func authenticateGoogle(idToken: String) async throws -> FirebaseAccountTokens { googleToken = idToken; return result }
    func authenticate(email: String, password: String, create: Bool) async throws -> FirebaseAccountTokens { result }
    func refresh(_ tokens: FirebaseAccountTokens) async throws -> FirebaseAccountTokens {
        if let refreshError { throw refreshError }
        var updated = result
        updated.pendingReleaseEmails = tokens.pendingReleaseEmails
        updated.releaseEmails = tokens.releaseEmails
        return updated
    }
    func sendVerification(_ tokens: FirebaseAccountTokens) async throws { verificationEmails += 1 }
    func sendPasswordReset(email: String) async throws {}
    func readReleaseEmails(_ tokens: FirebaseAccountTokens) async throws -> Bool {
        if let preferenceError { throw preferenceError }
        return subscribed
    }
    func writeReleaseEmails(_ value: Bool, tokens: FirebaseAccountTokens) async throws {
        if let preferenceError { throw preferenceError }
        writes.append(value)
    }
}

@MainActor
struct HeyMateAccountTests {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func unverifiedSignupCannotUnlockAndSurvivesRestart() async {
        let client = AccountServiceFixture(), store = MemoryAccountStore()
        let account = HeyMateAccount(client: client, store: store, now: { self.instant })
        await account.authenticate(email: "tester@example.invalid", password: "example-test-password", create: true, releaseEmails: true)
        #expect(!account.mayUseApp)
        #expect(store.tokens?.verifiedAt == nil)
        #expect(store.tokens?.pendingReleaseEmails == true)
        #expect(client.verificationEmails == 1)
        #expect(client.writes.isEmpty)
        let restarted = HeyMateAccount(client: client, store: store, now: { self.instant })
        await restarted.restore()
        #expect(!restarted.mayUseApp)
        await restarted.resendVerification()
        #expect(client.verificationEmails == 2)
        await restarted.resendVerification()
        #expect(client.verificationEmails == 2)
    }

    @Test func serverVerificationUnlocksAndSyncsExplicitConsent() async {
        let client = AccountServiceFixture(), store = MemoryAccountStore()
        let account = HeyMateAccount(client: client, store: store)
        await account.authenticate(email: "tester@example.invalid", password: "password", create: true, releaseEmails: false)
        client.result.verifiedAt = instant
        await account.checkVerification()
        #expect(account.access == .verified)
        #expect(client.writes == [false])
        #expect(store.tokens?.pendingReleaseEmails == nil)
        #expect(store.tokens?.verifiedAt == instant)
    }

    @Test func signInPreservesCloudSubscriptionRatherThanFormDefault() async {
        let client = AccountServiceFixture(), store = MemoryAccountStore()
        client.result.verifiedAt = instant
        let account = HeyMateAccount(client: client, store: store)
        await account.authenticate(email: "tester@example.invalid", password: "password", create: false, releaseEmails: false)
        #expect(account.session?.releaseEmails == true)
        #expect(client.writes.isEmpty)
    }

    @Test func offlineGraceRequiresRecentServerVerification() async {
        let client = AccountServiceFixture(), store = MemoryAccountStore()
        client.refreshError = URLError(.notConnectedToInternet)
        var tokens = client.result
        tokens.verifiedAt = instant.addingTimeInterval(-3600)
        store.tokens = tokens
        let account = HeyMateAccount(client: client, store: store, now: { self.instant })
        await account.restore()
        #expect(account.access == .offlineGrace)
        #expect(store.tokens?.verifiedAt == tokens.verifiedAt)
        tokens.verifiedAt = instant.addingTimeInterval(-7 * 86400 - 1)
        store.tokens = tokens
        let expired = HeyMateAccount(client: client, store: store, now: { self.instant })
        await expired.restore()
        #expect(!expired.mayUseApp)
        tokens.verifiedAt = nil
        store.tokens = tokens
        let unverified = HeyMateAccount(client: client, store: store, now: { self.instant })
        await unverified.restore()
        #expect(!unverified.mayUseApp)
    }

    @Test func revokedSessionCannotUseOfflineGrace() async {
        let client = AccountServiceFixture(), store = MemoryAccountStore()
        client.result.verifiedAt = instant
        store.tokens = client.result
        client.refreshError = FirebaseAccountError.expired
        let account = HeyMateAccount(client: client, store: store, now: { self.instant })
        await account.restore()
        #expect(!account.mayUseApp)
        #expect(store.tokens == nil)
    }

    @Test func secureStorageFailureCannotUnlock() async {
        let client = AccountServiceFixture(), store = MemoryAccountStore()
        client.result.verifiedAt = instant
        store.fails = true
        let account = HeyMateAccount(client: client, store: store)
        await account.authenticate(email: "tester@example.invalid", password: "password", create: false, releaseEmails: false)
        #expect(!account.mayUseApp)
        #expect(account.session == nil)
    }

    @Test func failedPreferenceWriteRetainsDurableIntentAndRetries() async {
        let client = AccountServiceFixture(), store = MemoryAccountStore()
        client.result.verifiedAt = instant
        let account = HeyMateAccount(client: client, store: store)
        await account.authenticate(email: "tester@example.invalid", password: "password", create: false, releaseEmails: false)
        client.preferenceError = URLError(.notConnectedToInternet)
        await account.updateReleaseEmails(false)
        #expect(store.tokens?.pendingReleaseEmails == false)
        #expect(account.preferenceMessage != nil)
        #expect(account.mayUseApp)
        client.preferenceError = nil
        let restarted = HeyMateAccount(client: client, store: store)
        await restarted.restore()
        #expect(client.writes == [false])
        #expect(store.tokens?.pendingReleaseEmails == nil)
    }

    @Test func signOutClearsSessionAndRelocks() async {
        let client = AccountServiceFixture(), store = MemoryAccountStore()
        client.result.verifiedAt = instant
        let account = HeyMateAccount(client: client, store: store)
        await account.authenticate(email: "tester@example.invalid", password: "password", create: false, releaseEmails: false)
        store.fails = true
        #expect(!account.signOut())
        #expect(account.mayUseApp)
        store.fails = false
        #expect(account.signOut())
        #expect(store.tokens == nil)
        #expect(!account.mayUseApp)
    }
    @Test func googleUsesVerifiedServerIdentityAndPreservesSubscription() async {
        let client = AccountServiceFixture(), store = MemoryAccountStore()
        client.result.verifiedAt = instant
        client.result.displayName = "Test Mate"
        let account = HeyMateAccount(client: client, store: store)
        await account.signInWithGoogle(using: GoogleSignInFixture())
        #expect(account.mayUseApp)
        #expect(account.session?.displayName == "Test Mate")
        #expect(account.session?.releaseEmails == true)
        #expect(client.googleToken == "google-id-token")
        #expect(client.writes.isEmpty)
        #expect(client.verificationEmails == 0)
    }

    @Test func googleCannotUnlockWithoutVerificationOrDurableSession() async {
        let client = AccountServiceFixture(), store = MemoryAccountStore()
        let account = HeyMateAccount(client: client, store: store)
        await account.signInWithGoogle(using: GoogleSignInFixture())
        #expect(!account.mayUseApp)
        #expect(store.tokens == nil)
        client.result.verifiedAt = instant
        store.fails = true
        await account.signInWithGoogle(using: GoogleSignInFixture())
        #expect(!account.mayUseApp)
        #expect(account.session == nil)
    }

    @Test func cancelledGooglePickerLeavesGateRetryable() async {
        let client = AccountServiceFixture(), store = MemoryAccountStore()
        let account = HeyMateAccount(client: client, store: store)
        await account.signInWithGoogle(using: GoogleSignInFixture(cancel: true))
        #expect(!account.busy)
        #expect(!account.mayUseApp)
        #expect(account.message == nil)
        #expect(client.googleToken == nil)
        #expect(store.tokens == nil)
    }

}


@MainActor
private struct GoogleSignInFixture: GoogleAccountSigningIn {
    var cancel = false
    func idToken() async throws -> String {
        if cancel { throw CancellationError() }
        return "google-id-token"
    }
}
