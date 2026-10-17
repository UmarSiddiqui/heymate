import Foundation
import Testing
@testable import HeyMate

struct HermesSetupTests {
    @Test func newProfileIsPrivateAndDoesNotCopyCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HermesSetup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("private")
        try HermesSetupController.createProfile(at: profile, home: root)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: profile.path)) == ["config.yaml"])
        let data = try Data(contentsOf: profile.appendingPathComponent("config.yaml"))
        let config = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((config["skills"] as? [String: Bool])?["write_approval"] == true)
        #expect((config["approvals"] as? [String: String])?["mode"] == "manual")
        #expect((config["model"] as? [String: String])?["openai_runtime"] == "auto")
        #expect((config["auth"] as? [String: Bool])?["adopt_external_logins"] == false)
        let mode = try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        let fileMode = try FileManager.default.attributesOfItem(atPath: profile.appendingPathComponent("config.yaml").path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.intValue == 0o600)
    }

    @Test func existingProfileAndGlobalAliasesAreNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HermesSetup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        let sentinel = global.appendingPathComponent(".env")
        try Data("preserve-local-credential".utf8).write(to: sentinel)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: global)
        for path in [global, alias, global.appendingPathComponent("nested"), root] {
            #expect(throws: HermesSetupController.SetupFailure.unsafeProfile) {
                try HermesSetupController.createProfile(at: path, home: root)
            }
        }
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        #expect(throws: HermesSetupController.SetupFailure.existingProfile) {
            try HermesSetupController.createProfile(at: existing, home: root)
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve-local-credential")
    }

    @Test func bundledManifestPinsRevisionAndRejectsEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HermesBundle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Hermes")
        let profile = root.appendingPathComponent("profile")
        let tools = bundle.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let executable = bundle.appendingPathComponent("hermes")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let commit = String(repeating: "a", count: 40)
        func manifest(_ path: String) throws {
            try JSONSerialization.data(withJSONObject: ["executablePath": path, "runtimePath": "tools", "sourceCommit": commit])
                .write(to: bundle.appendingPathComponent("manifest.json"))
        }
        try manifest("hermes")
        let launch = try HermesEngineConfiguration(executablePath: "", profilePath: profile.path)
            .resolveLaunchConfiguration(resolving: { _ in nil }, loginPATH: { "" }, homeDirectoryURL: root, bundledRoot: bundle)
        #expect(launch.expectedCommit == commit)
        #expect(launch.environment["HERMES_RUNTIME_DIR"] == tools.resolvingSymlinksInPath().path)
        try manifest("../outside")
        #expect(throws: HermesEngineConfiguration.ConfigurationError.invalidBundledRuntime) {
            try HermesEngineConfiguration(executablePath: "", profilePath: profile.path)
                .resolveLaunchConfiguration(loginPATH: { "" }, homeDirectoryURL: root, bundledRoot: bundle)
        }
    }
    @MainActor
    @Test(arguments: ["openai", "anthropic"])
    func modelSetupKeepsCredentialOutOfModelConfigAndChecksReadiness(provider: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HermesSetup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var requests: [[String: JSONValue]] = []
        var savedChoice: JSONValue?
        var socket: HermesServeWebSocket!
        socket = HermesServeWebSocket { value in
            guard case .object(let fields) = value else { return }
            requests.append(fields)
            let result: JSONValue
            if fields["method"] == .string("setup.runtime_check") {
                result = .object(["ok": .bool(true), "provider": .string(provider), "model": .string("fixture-model")])
            } else { result = .object(["provider": .object(["slug": .string(provider)])]) }
            socket.receive(.object(["jsonrpc": .string("2.0"), "id": fields["id"]!, "result": result]))
        }
        socket.connect()
        let setup = HermesSetupController(openGateway: { _ in socket }, writeModel: { choice in
            savedChoice = choice
            return .object(["ok": .bool(true)])
        })
        await setup.connect(.init(executablePath: "/bin/sh", profilePath: root.path),
                            provider: provider, model: "fixture-model", key: "non-live-fixture-key")
        #expect(setup.ready)
        #expect(requests.map { $0["method"] } == [.string("model.save_key"), .string("setup.runtime_check")])
        #expect(requests[0]["params"] == .object(["slug": .string(provider), "api_key": .string("non-live-fixture-key")]))
        #expect(savedChoice == .object([
            "scope": .string("main"), "provider": .string(provider), "model": .string("fixture-model"),
            "base_url": .string(""), "api_key": .string(""), "confirm_expensive_model": .bool(false)
        ]))
        #expect(requests[1]["params"] == .object(["provider": .string(provider)]))
        #expect(setup.status?.contains("non-live-fixture-key") == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @MainActor
    @Test func providerErrorCannotEchoCredentialIntoSetupStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HermesSetup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var socket: HermesServeWebSocket!
        socket = HermesServeWebSocket { value in
            guard case .object(let fields) = value else { return }
            socket.receive(.object(["jsonrpc": .string("2.0"), "id": fields["id"]!, "error": .object([
                "code": .number(5001), "message": .string("rejected private-fixture-key")
            ])]))
        }
        socket.connect()
        let setup = HermesSetupController(openGateway: { _ in socket }, writeModel: { _ in
            Issue.record("Config write reached after credential rejection")
            return .null
        })
        await setup.connect(.init(executablePath: "/bin/sh", profilePath: root.path),
                            provider: "openai", model: "fixture-model", key: "private-fixture-key")
        #expect(!setup.ready)
        #expect(setup.status?.contains("private-fixture-key") == false)
    }

    @MainActor
    @Test func expensiveModelNeedsExplicitConfirmationBeforeReadiness() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HermesSetup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var assignments: [JSONValue] = []
        var probes = 0
        let setup = HermesSetupController(openGateway: { _ in
            var socket: HermesServeWebSocket!
            socket = HermesServeWebSocket { value in
                guard case .object(let fields) = value else { return }
                probes += 1
                socket.receive(.object(["jsonrpc": .string("2.0"), "id": fields["id"]!, "result": .object([
                    "ok": .bool(true), "provider": .string("openai"), "model": .string("fixture-model")
                ])]))
            }
            socket.connect()
            return socket
        }, writeModel: { choice in
            assignments.append(choice)
            return assignments.count == 1
                ? .object(["ok": .bool(false), "confirm_required": .bool(true), "confirm_message": .string("Review higher model cost.")])
                : .object(["ok": .bool(true)])
        })
        await setup.connect(.init(executablePath: "/bin/sh", profilePath: root.path), provider: "openai", model: "fixture-model", key: "")
        #expect(!setup.ready)
        #expect(setup.confirmationMessage != nil)
        #expect(probes == 0)
        #expect(assignments.count == 1)
        await setup.confirmModel()
        #expect(setup.ready)
        #expect(setup.confirmationMessage == nil)
        #expect(probes == 1)
        if case .object(let first) = assignments[0], case .object(let confirmed) = assignments[1] {
            #expect(first["confirm_expensive_model"] == .bool(false))
            #expect(confirmed["confirm_expensive_model"] == .bool(true))
        } else { Issue.record("Invalid assignment payload") }
    }

    @MainActor
    @Test func readyFallbackCannotMasqueradeAsChosenProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HermesSetup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var socket: HermesServeWebSocket!
        socket = HermesServeWebSocket { value in
            guard case .object(let fields) = value else { return }
            socket.receive(.object(["jsonrpc": .string("2.0"), "id": fields["id"]!, "result": .object([
                "ok": .bool(true), "provider": .string("another-provider"), "model": .string("fixture-model")
            ])]))
        }
        socket.connect()
        let setup = HermesSetupController(openGateway: { _ in socket }, writeModel: { _ in .object(["ok": .bool(true)]) })
        await setup.connect(.init(executablePath: "/bin/sh", profilePath: root.path), provider: "openai", model: "fixture-model", key: "")
        #expect(!setup.ready)
    }

    @MainActor
    @Test func checkingSubscriptionProfilePreservesItsCurrentRouteWithoutWriting() async throws {
        var methods: [JSONValue] = []
        var socket: HermesServeWebSocket!
        socket = HermesServeWebSocket { frame in
            guard case .object(let request) = frame else { return }
            methods.append(request["method"] ?? .null)
            let response: JSONValue = request["method"] == .string("model.options")
                ? .object(["provider": .string("openai-codex"), "model": .string("existing-model"), "providers": .array([
                    .object(["slug": .string("openai-codex"), "name": .string("ChatGPT"), "authenticated": .bool(true),
                             "auth_type": .string("oauth"), "models": .array([.string("existing-model")])])])])
                : .object(["ok": .bool(true), "provider": .string("openai-codex"), "model": .string("existing-model")])
            socket.receive(.object(["jsonrpc": .string("2.0"), "id": request["id"]!, "result": response]))
        }
        socket.connect()
        let setup = HermesSetupController(openGateway: { _ in socket }, writeModel: { _ in
            Issue.record("Check must not change profile model"); return .null
        })
        await setup.check(.init(executablePath: "/bin/sh", profilePath: "/tmp"))
        #expect(setup.ready)
        #expect(setup.currentProvider == "openai-codex")
        #expect(setup.currentModel == "existing-model")
        #expect(methods == [.string("model.options"), .string("setup.runtime_check")])
        #expect(setup.providers.first?.authenticated == true)
    }

    @MainActor
    @Test func subscriptionModelUsesCanonicalAssignmentAndNeverSavesAnAPIKey() async throws {
        var methods: [JSONValue] = []
        var choice: JSONValue?
        var socket: HermesServeWebSocket!
        socket = HermesServeWebSocket { frame in
            guard case .object(let request) = frame else { return }
            methods.append(request["method"] ?? .null)
            #expect(request["params"] == .object(["provider": .string("openai-codex")]))
            socket.receive(.object(["jsonrpc": .string("2.0"), "id": request["id"]!, "result": .object([
                "ok": .bool(true), "provider": .string("openai-codex"), "model": .string("selected-model")])]))
        }
        socket.connect()
        let setup = HermesSetupController(openGateway: { _ in socket }, writeModel: { value in
            choice = value; return .object(["ok": .bool(true)])
        })
        await setup.connect(.init(executablePath: "/bin/sh", profilePath: "/tmp"),
            provider: "openai-codex", model: "selected-model", key: "must-not-be-saved")
        #expect(setup.ready)
        #expect(methods == [.string("setup.runtime_check")])
        #expect(choice == .object(["scope": .string("main"), "provider": .string("openai-codex"),
            "model": .string("selected-model"), "base_url": .string(""), "api_key": .string(""), "confirm_expensive_model": .bool(false)]))
    }

}
