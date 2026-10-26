import Foundation
import Testing
@testable import HeyMate

struct MateAgentMigrationTests {
    @Test func retiredSelectionMigratesWithoutImportingItsProfileOrCredentials() throws {
        let name = "PiMigration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("hermes", forKey: MateEngine.preferenceKey)
        defaults.set("/private/prior-profile", forKey: "hermesProfilePath")
        #expect(MateEngine.selected(defaults: defaults) == .pi)
        MateEngine.migrateRetiredSelection(defaults: defaults)
        #expect(defaults.string(forKey: MateEngine.preferenceKey) == nil)
        #expect(defaults.string(forKey: "hermesProfilePath") == "/private/prior-profile")
        #expect(defaults.object(forKey: MateAgentEngineConfiguration.profilePathKey) == nil)
        defaults.set("native", forKey: MateEngine.preferenceKey)
        MateEngine.migrateRetiredSelection(defaults: defaults)
        #expect(MateEngine.selected(defaults: defaults) == .pi)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEYMATE_PI_TEST_LAUNCHER"] != nil))
    func realHarnessAttestsAndRoundTripsNativeSessionsWithoutAModelRequest() async throws {
        let launcher = try #require(ProcessInfo.processInfo.environment["HEYMATE_PI_TEST_LAUNCHER"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PiNative-\(UUID())")
        let profile = root.appendingPathComponent("profile")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try MateAgentSetupController.createProfile(at: profile)
        let backend = MateAgentServeBackend()
        defer { backend.stop(); try? FileManager.default.removeItem(at: root) }
        let configuration = try MateAgentEngineConfiguration(executablePath: launcher, profilePath: profile.path)
            .resolveLaunchConfiguration()
        let identity = try await backend.start(configuration: configuration)
        #expect(identity.version == "1.0.0")
        let session = try backend.openSession()
        let created = try await session.create(workspace: workspace)
        session.close()
        let resumed = try backend.openSession()
        let restored = try await resumed.resume(storedID: created.storedID, workspace: workspace)
        #expect(restored.storedID == created.storedID)
        #expect(!resumed.hasPriorWorkInProgress)
        resumed.close()
        #expect(await backend.shutdown())
    }
}
