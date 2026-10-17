import Foundation
import Testing
@testable import HeyMate

@MainActor
struct NativeCredentialIsolationTests {
    @Test func disabledNativeCredentialAccessDoesNotReadMigrateOrRemoveLegacyValue() throws {
        let suite = "native-credential-isolation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("synthetic-test-credential", forKey: CompanionManager.legacyOpenCodeBasicAuthPasswordPreferenceKey)
        var reads = 0
        var writes = 0
        let password = CompanionManager.loadOpenCodeBasicAuthPassword(userDefaults: defaults,
            allowCredentialAccess: false, readSecret: { _ in reads += 1; return nil },
            writeSecret: { _, _ in writes += 1; return true })
        #expect(password.isEmpty)
        #expect(reads == 0)
        #expect(writes == 0)
        #expect(defaults.string(forKey: CompanionManager.legacyOpenCodeBasicAuthPasswordPreferenceKey) == "synthetic-test-credential")
    }

    @Test func allowedNativeMigrationKeepsExistingProductionOrdering() throws {
        let suite = "native-credential-migration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("synthetic-test-credential", forKey: CompanionManager.legacyOpenCodeBasicAuthPasswordPreferenceKey)
        var migrated: String?
        let password = CompanionManager.loadOpenCodeBasicAuthPassword(userDefaults: defaults,
            allowCredentialAccess: true, readSecret: { _ in nil }, writeSecret: { value, identifier in
                #expect(identifier == CompanionManager.openCodeBasicAuthPasswordKeychainIdentifier)
                migrated = value
                return true
            })
        #expect(password == "synthetic-test-credential")
        #expect(migrated == password)
        #expect(defaults.object(forKey: CompanionManager.legacyOpenCodeBasicAuthPasswordPreferenceKey) == nil)
    }

    @Test func hostedManagerCredentialPolicyBlocksRealKeychainAccess() {
        #expect(HeyMateDataDirectory.isUnitTestHost)
        #expect(!CompanionManager.nativeCredentialAccessAllowed)
    }
}
