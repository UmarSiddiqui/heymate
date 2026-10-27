import Foundation
import Testing
@testable import HeyMate

struct MateAgentEngineConfigurationTests {
    @Test func productionConfigurationIgnoresRetiredRuntimePathsAndRequiresBundle() throws {
        let name = "FixedHarness-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/bin/sh", forKey: MateAgentEngineConfiguration.executablePathKey)
        defaults.set("/tmp/retired", forKey: MateAgentEngineConfiguration.profilePathKey)
        let configuration = MateAgentEngineConfiguration.load(defaults: defaults)
        #expect(configuration.executablePath.isEmpty)
        #expect(configuration.profilePath == MateAgentEngineConfiguration.defaultProfilePath)
        #expect(configuration.requiresBundledRuntime)
        #expect(throws: MateAgentEngineConfiguration.ConfigurationError.invalidBundledRuntime) {
            try configuration.resolveLaunchConfiguration(resolving: { _ in URL(fileURLWithPath: "/bin/sh") }, bundledRoot: nil)
        }
    }

    @Test func engineDefaultsToPiWithoutChangingProviderPreferences() throws {
        let name = "MateAgentEngineConfigurationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("codex", forKey: "selectedAgentBrain")
        #expect(MateEngine.selected(defaults: defaults) == .pi)
        defaults.set("pi", forKey: MateEngine.preferenceKey)
        #expect(MateEngine.selected(defaults: defaults) == .pi)
        #expect(defaults.string(forKey: "selectedAgentBrain") == "codex")
        defaults.set("unknown", forKey: MateEngine.preferenceKey)
        #expect(MateEngine.selected(defaults: defaults) == .pi)
    }

    @Test func resolvesLoginShellExecutableAndIsolatedProfileWithoutWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("heymate-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var requestedName: String?
        let configuration = MateAgentEngineConfiguration(executablePath: "", profilePath: profile.path)
        let launch = try configuration.resolveLaunchConfiguration(resolving: { requestedName = $0; return executable }, loginPATH: { "/custom/bin" }, bundledRoot: nil)
        #expect(requestedName == "heymate-agent")
        #expect(launch.executableURL == executable)
        #expect(launch.profileDirectoryURL == profile)
        #expect(launch.environment == ["HEYMATE_AGENT_HOME": profile.path, "PATH": "/custom/bin"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: profile.path).isEmpty)
    }

    @Test func missingExecutableFailsWithoutFallbackOrProfileCreation() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = MateAgentEngineConfiguration(executablePath: "", profilePath: missing.path)
        #expect(throws: MateAgentEngineConfiguration.ConfigurationError.executableMissing) {
            try configuration.resolveLaunchConfiguration(resolving: { _ in nil }, loginPATH: { "" }, bundledRoot: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func rejectsSharedGlobalProfileIncludingSymlinkAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent(".pi/agent", isDirectory: true)
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: global)
        for profile in [global, alias] {
            let configuration = MateAgentEngineConfiguration(executablePath: "/bin/sh", profilePath: profile.path)
            #expect(throws: MateAgentEngineConfiguration.ConfigurationError.sharedGlobalProfile) {
                try configuration.resolveLaunchConfiguration(loginPATH: { "" }, homeDirectoryURL: root)
            }
        }
    }

    @Test(arguments: ["heymate-agent", "~/bin/mateAgent"])
    func rejectsRelativeExecutablePath(path: String) {
        let configuration = MateAgentEngineConfiguration(executablePath: path, profilePath: "/tmp/profile")
        #expect(throws: MateAgentEngineConfiguration.ConfigurationError.executablePathMustBeAbsolute) {
            try configuration.resolveLaunchConfiguration(loginPATH: { "" })
        }
    }

    @Test func missingProfileFailsWithoutCreatingIt() {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = MateAgentEngineConfiguration(executablePath: "/bin/sh", profilePath: profile.path)
        #expect(throws: MateAgentEngineConfiguration.ConfigurationError.profileMissing) {
            try configuration.resolveLaunchConfiguration(loginPATH: { "" })
        }
        #expect(!FileManager.default.fileExists(atPath: profile.path))
    }

    @Test(arguments: ["export HEYMATE_AGENT_HOME=/tmp/global-profile", "HEYMATE_AGENT_HOME=\"$HOME/.pi\" exec mateAgent acp", "true; HEYMATE_AGENT_HOME=/tmp/global-profile"])
    func rejectsShellLaunchersThatOverrideIsolatedProfile(assignment: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let launcher = root.appendingPathComponent("pi-sessions")
        try Data("#!/bin/sh\n\(assignment)\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let configuration = MateAgentEngineConfiguration(executablePath: launcher.path, profilePath: root.path)
        #expect(throws: MateAgentEngineConfiguration.ConfigurationError.launcherOverridesProfile) {
            try configuration.resolveLaunchConfiguration(loginPATH: { "" })
        }
    }
}
