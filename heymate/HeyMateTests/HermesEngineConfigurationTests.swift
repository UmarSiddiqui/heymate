import Foundation
import Testing
@testable import HeyMate

struct HermesEngineConfigurationTests {
    @Test func engineDefaultsToNativeWithoutChangingProviderPreferences() throws {
        let name = "HermesEngineConfigurationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("codex", forKey: "selectedAgentBrain")
        #expect(MateEngine.selected(defaults: defaults) == .native)
        defaults.set("hermes", forKey: MateEngine.preferenceKey)
        #expect(MateEngine.selected(defaults: defaults) == .hermes)
        #expect(defaults.string(forKey: "selectedAgentBrain") == "codex")
        defaults.set("unknown", forKey: MateEngine.preferenceKey)
        #expect(MateEngine.selected(defaults: defaults) == .native)
    }

    @Test func resolvesLoginShellExecutableAndIsolatedProfileWithoutWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("hermes")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var requestedName: String?
        let configuration = HermesEngineConfiguration(executablePath: "", profilePath: profile.path)
        let launch = try configuration.resolveLaunchConfiguration(resolving: { requestedName = $0; return executable }, loginPATH: { "/custom/bin" })
        #expect(requestedName == "hermes")
        #expect(launch.executableURL == executable)
        #expect(launch.profileDirectoryURL == profile)
        #expect(launch.environment == ["HERMES_HOME": profile.path, "PATH": "/custom/bin"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: profile.path).isEmpty)
    }

    @Test func missingExecutableFailsWithoutFallbackOrProfileCreation() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = HermesEngineConfiguration(executablePath: "", profilePath: missing.path)
        #expect(throws: HermesEngineConfiguration.ConfigurationError.executableMissing) {
            try configuration.resolveLaunchConfiguration(resolving: { _ in nil }, loginPATH: { "" })
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func rejectsSharedGlobalProfileIncludingSymlinkAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent(".hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: global)
        for profile in [global, alias] {
            let configuration = HermesEngineConfiguration(executablePath: "/bin/sh", profilePath: profile.path)
            #expect(throws: HermesEngineConfiguration.ConfigurationError.sharedGlobalProfile) {
                try configuration.resolveLaunchConfiguration(loginPATH: { "" }, homeDirectoryURL: root)
            }
        }
    }

    @Test(arguments: ["hermes", "~/bin/hermes"])
    func rejectsRelativeExecutablePath(path: String) {
        let configuration = HermesEngineConfiguration(executablePath: path, profilePath: "/tmp/profile")
        #expect(throws: HermesEngineConfiguration.ConfigurationError.executablePathMustBeAbsolute) {
            try configuration.resolveLaunchConfiguration(loginPATH: { "" })
        }
    }

    @Test func missingProfileFailsWithoutCreatingIt() {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = HermesEngineConfiguration(executablePath: "/bin/sh", profilePath: profile.path)
        #expect(throws: HermesEngineConfiguration.ConfigurationError.profileMissing) {
            try configuration.resolveLaunchConfiguration(loginPATH: { "" })
        }
        #expect(!FileManager.default.fileExists(atPath: profile.path))
    }

    @Test(arguments: ["export HERMES_HOME=/tmp/global-profile", "HERMES_HOME=\"$HOME/.hermes\" exec hermes acp", "true; HERMES_HOME=/tmp/global-profile"])
    func rejectsShellLaunchersThatOverrideIsolatedProfile(assignment: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let launcher = root.appendingPathComponent("hermes-wrapper")
        try Data("#!/bin/sh\n\(assignment)\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let configuration = HermesEngineConfiguration(executablePath: launcher.path, profilePath: root.path)
        #expect(throws: HermesEngineConfiguration.ConfigurationError.launcherOverridesProfile) {
            try configuration.resolveLaunchConfiguration(loginPATH: { "" })
        }
    }
}
