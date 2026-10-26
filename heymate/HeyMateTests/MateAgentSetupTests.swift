import Foundation
import Testing
@testable import HeyMate

struct MateAgentSetupTests {
    @Test func newProfileIsPrivateAndDoesNotCopyCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MateAgentSetup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("private")
        try MateAgentSetupController.createProfile(at: profile, home: root)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: profile.path)) == ["settings.json"])
        let data = try Data(contentsOf: profile.appendingPathComponent("settings.json"))
        let config = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(config["approvals"] as? String == "manual")
        #expect(config["agent"] as? String == "heymate-pi")
        #expect(config["auth"] == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        let fileMode = try FileManager.default.attributesOfItem(atPath: profile.appendingPathComponent("settings.json").path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.intValue == 0o600)
    }

    @Test func existingProfileAndGlobalAliasesAreNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MateAgentSetup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent(".pi/agent")
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        let sentinel = global.appendingPathComponent(".env")
        try Data("preserve-local-credential".utf8).write(to: sentinel)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: global)
        for path in [global, alias, global.appendingPathComponent("nested"), root] {
            #expect(throws: MateAgentSetupController.SetupFailure.unsafeProfile) {
                try MateAgentSetupController.createProfile(at: path, home: root)
            }
        }
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        #expect(throws: MateAgentSetupController.SetupFailure.existingProfile) {
            try MateAgentSetupController.createProfile(at: existing, home: root)
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve-local-credential")
    }

    @Test func bundledManifestPinsRevisionAndRejectsEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MateAgentBundle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("HeyMate Agent")
        let profile = root.appendingPathComponent("profile")
        let tools = bundle.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let executable = bundle.appendingPathComponent("heymate-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let commit = String(repeating: "a", count: 40)
        func manifest(_ path: String) throws {
            try JSONSerialization.data(withJSONObject: ["executablePath": path, "runtimePath": "tools", "sourceCommit": commit, "files": String(repeating: "x", count: 300_000)])
                .write(to: bundle.appendingPathComponent("manifest.json"))
        }
        try manifest("heymate-agent")
        let launch = try MateAgentEngineConfiguration(executablePath: "", profilePath: profile.path)
            .resolveLaunchConfiguration(resolving: { _ in nil }, loginPATH: { "" }, homeDirectoryURL: root, bundledRoot: bundle)
        #expect(launch.expectedCommit == commit)
        #expect(launch.environment["HEYMATE_AGENT_RUNTIME_DIR"] == tools.resolvingSymlinksInPath().path)
        try manifest("../outside")
        #expect(throws: MateAgentEngineConfiguration.ConfigurationError.invalidBundledRuntime) {
            try MateAgentEngineConfiguration(executablePath: "", profilePath: profile.path)
                .resolveLaunchConfiguration(loginPATH: { "" }, homeDirectoryURL: root, bundledRoot: bundle)
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEYMATE_PI_TEST_BUNDLE"] != nil))
    func productionConfigurationResolvesRealPackagedManifest() throws {
        let payload = try #require(ProcessInfo.processInfo.environment["HEYMATE_PI_TEST_BUNDLE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrainBundle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = MateAgentEngineConfiguration(executablePath: "", profilePath: root.path)
        configuration.requiresBundledRuntime = true
        let launch = try configuration.resolveLaunchConfiguration(loginPATH: { "/usr/bin:/bin" }, bundledRoot: URL(fileURLWithPath: payload))
        #expect(launch.executableURL.lastPathComponent == "heymate-agent")
        #expect(launch.expectedCommit?.count == 40)
        #expect(launch.environment["HEYMATE_AGENT_RUNTIME_DIR"]?.hasSuffix("/bin") == true)
    }

    @MainActor
    @Test(arguments: ["openai-codex", "anthropic"])
    func selectsOnlySubscriptionWithoutWritingKeysOrModelChoice(provider: String) async throws {
        var methods: [JSONValue] = []
        var choice: JSONValue?
        var socket: MateAgentServeWebSocket!
        socket = MateAgentServeWebSocket { frame in
            guard case .object(let request) = frame else { return }
            methods.append(request["method"] ?? .null)
            socket.receive(.object(["jsonrpc": .string("2.0"), "id": request["id"]!, "result": .object([
                "ok": .bool(true), "provider": .string(provider), "model": .string("automatic-model")])]))
        }
        socket.connect()
        let setup = MateAgentSetupController(openGateway: { _ in socket }, writeModel: { value in
            choice = value; return .object(["ok": .bool(true)])
        })
        await setup.useSubscription(.init(executablePath: "/bin/sh", profilePath: "/tmp"), provider: provider)
        #expect(setup.ready)
        #expect(methods == [.string("setup.runtime_check")])
        #expect(choice == .object(["provider": .string(provider)]))
        #expect(setup.currentModel == "automatic-model")
    }

    @MainActor
    @Test func rejectsAPIKeysAndUnsupportedSubscriptionsBeforeStartingBackend() async {
        let setup = MateAgentSetupController(openGateway: { _ in
            Issue.record("Rejected access must not start backend")
            throw CancellationError()
        })
        let configuration = MateAgentEngineConfiguration(executablePath: "/bin/sh", profilePath: "/tmp")
        await setup.connect(configuration, provider: "anthropic", model: "ignored", key: "fixture-secret")
        #expect(!setup.ready)
        #expect(setup.status?.contains("fixture-secret") == false)
        await setup.useSubscription(configuration, provider: "openai")
        #expect(!setup.ready)
    }

    @MainActor
    @Test func customAPIKeyChosenModelAndEffortUseOwnedBackendOnly() async {
        var choice: JSONValue?
        var socket: MateAgentServeWebSocket!
        socket = MateAgentServeWebSocket { frame in
            guard case .object(let request) = frame else { return }
            socket.receive(.object(["jsonrpc": .string("2.0"), "id": request["id"]!, "result": .object([
                "ok": .bool(true), "provider": .string("heymate-custom"), "model": .string("fixture-model"), "effort": .string("high")])]))
        }
        socket.connect()
        let setup = MateAgentSetupController(openGateway: { _ in socket }, writeModel: { value in
            choice = value; return .object(["ok": .bool(true)])
        })
        await setup.connect(.init(executablePath: "/bin/sh", profilePath: "/tmp"),
                            provider: "heymate-custom", model: "fixture-model", key: "fixture-private-key", effort: "high",
                            baseURL: "https://api.example.com/v1")
        #expect(setup.ready)
        #expect(setup.currentEffort == "high")
        #expect(choice == .object(["provider": .string("heymate-custom"), "model": .string("fixture-model"),
                                   "api_key": .string("fixture-private-key"), "effort": .string("high"),
                                   "base_url": .string("https://api.example.com/v1"),
                                   "api_format": .string("openai-completions")]))
        #expect(setup.status?.contains("fixture-private-key") == false)
    }

    @MainActor
    @Test func readinessCannotMasqueradeAsChosenSubscription() async {
        var socket: MateAgentServeWebSocket!
        socket = MateAgentServeWebSocket { frame in
            guard case .object(let request) = frame else { return }
            socket.receive(.object(["jsonrpc": .string("2.0"), "id": request["id"]!, "result": .object([
                "ok": .bool(true), "provider": .string("another-provider"), "model": .string("fixture")])]))
        }
        socket.connect()
        let setup = MateAgentSetupController(openGateway: { _ in socket }, writeModel: { _ in .object(["ok": .bool(true)]) })
        await setup.useSubscription(.init(executablePath: "/bin/sh", profilePath: "/tmp"), provider: "anthropic")
        #expect(!setup.ready)
    }
}
