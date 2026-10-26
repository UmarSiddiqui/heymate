import Foundation
import Combine

/// Setup talks only to the app-owned backend. Credentials never enter chat history,
/// preferences, diagnostics or model prompts; MateAgent saves them in its isolated home.
@MainActor
final class MateAgentSetupController: ObservableObject {
    struct Provider: Identifiable, Equatable {
        let id: String
        let name: String
        let models: [String]
        /// Effort levels each model supports, in Pi's order (off … max).
        let efforts: [String: [String]]
        /// Display names ("Claude Sonnet 5.5") keyed by model ID.
        let modelNames: [String: String]
        let authenticated: Bool
        let authType: String
    }
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var providers: [Provider] = []
    @Published private(set) var currentModel = ""
    @Published private(set) var currentEffort = "medium"
    @Published private(set) var currentProvider = ""
    @Published private(set) var currentBaseURL = ""
    @Published private(set) var currentAPIFormat = "openai-completions"
    @Published private(set) var ready = false
    @Published private(set) var confirmationMessage: String?
    private var pendingModel: (MateAgentEngineConfiguration, String, String)?
    private let backend: MateAgentServeBackend
    private let openGateway: ((MateAgentEngineLaunchConfiguration) async throws -> MateAgentServeWebSocket)?
    private let writeModel: ((JSONValue) async throws -> JSONValue)?

    init(backend: MateAgentServeBackend = .shared,
         openGateway: ((MateAgentEngineLaunchConfiguration) async throws -> MateAgentServeWebSocket)? = nil,
         writeModel: ((JSONValue) async throws -> JSONValue)? = nil) {
        self.backend = backend
        self.openGateway = openGateway
        self.writeModel = writeModel
    }

    func check(_ configuration: MateAgentEngineConfiguration) async {
        await perform(configuration) { socket in
            let inventory = try await socket.request(method: "model.options", params: .object([
                "include_unconfigured": .bool(true)
            ]), timeout: .seconds(60))
            self.readInventory(inventory)
            try await self.readReadiness(socket)
        }
    }

    func useSubscription(_ configuration: MateAgentEngineConfiguration, provider: String) async {
        await connect(configuration, provider: provider, model: "", key: "")
    }

    func connect(_ configuration: MateAgentEngineConfiguration, provider: String, model: String, key: String,
                 effort: String = "", confirmed: Bool = false, baseURL: String = "",
                 apiFormat: String = "openai-completions") async {
        let supported = ["openai-codex", "anthropic", "heymate-custom"]
        guard supported.contains(provider), model.utf8.count <= 256, key.utf8.count <= 16384,
              !model.contains(where: \.isNewline), !key.contains(where: \.isNewline),
              !(["openai-codex", "anthropic"].contains(provider) && !key.isEmpty) else {
            status = "Choose a supported plan or API provider."; return
        }
        await perform(configuration) { socket in
            var fields: [String: JSONValue] = ["provider": .string(provider)]
            if !model.isEmpty { fields["model"] = .string(model) }
            if !key.isEmpty { fields["api_key"] = .string(key) }
            if !effort.isEmpty { fields["effort"] = .string(effort) }
            if provider == "heymate-custom" {
                fields["base_url"] = .string(baseURL)
                fields["api_format"] = .string(apiFormat)
            }
            let result: JSONValue
            if let writeModel = self.writeModel { result = try await writeModel(.object(fields)) }
            else { result = try await self.backend.requestHTTP(path: "/api/model/set", method: "POST", body: .object(fields)) }
            guard case .object(let saved) = result, saved["ok"] == .bool(true) else { throw SetupFailure.invalidResponse }
            try await self.readReadiness(socket, expectedProvider: provider, expectedModel: model.isEmpty ? nil : model)
        }
    }

    func confirmModel() async {
        guard let (configuration, provider, model) = pendingModel else { return }
        await connect(configuration, provider: provider, model: model, key: "", confirmed: true)
    }
    func cancelConfirmation() { pendingModel = nil; confirmationMessage = nil }
    func resetStatus() {
        status = nil; ready = false; providers = []; currentModel = ""; currentProvider = ""
        cancelConfirmation()
    }

    private func perform(_ configuration: MateAgentEngineConfiguration,
                         action: (MateAgentServeWebSocket) async throws -> Void) async {
        guard !busy else { return }
        busy = true; ready = false; status = "Checking HeyMate Agent…"
        defer { busy = false }
        do {
            let launch = try configuration.resolveLaunchConfiguration()
            let socket: MateAgentServeWebSocket
            if let openGateway { socket = try await openGateway(launch) }
            else {
                if let identity = backend.identity,
                   identity.home.resolvingSymlinksInPath().path != launch.profileDirectoryURL.resolvingSymlinksInPath().path {
                    guard await backend.shutdown() else { throw MateAgentServeBackend.Failure.notRunning }
                }
                do { _ = try await backend.start(configuration: launch) }
                catch MateAgentServeBackend.Failure.alreadyRunningDifferentProfile {
                    guard await backend.shutdown() else { throw MateAgentServeBackend.Failure.notRunning }
                    _ = try await backend.start(configuration: launch)
                }
                socket = try backend.openWebSocket()
            }
            defer { socket.close() }
            try await action(socket)
        } catch is CancellationError {
            status = "Setup cancelled."
        } catch let error as MateAgentEngineConfiguration.ConfigurationError {
            status = error.localizedDescription
        } catch let error as MateAgentServeBackend.Failure {
            status = error.localizedDescription
        } catch {
            // Backend/provider errors may include request values. Show a bounded
            // fixed message rather than echoing a credential-bearing remote error.
            status = "HeyMate Agent setup could not finish. Check the runtime and profile, then try again. No alternate engine was started."
        }
    }

    private func readReadiness(_ socket: MateAgentServeWebSocket, expectedProvider: String? = nil,
                               expectedModel: String? = nil) async throws {
        let params: JSONValue = expectedProvider.map { .object(["provider": .string($0)]) } ?? .emptyObject
        let response = try await socket.request(method: "setup.runtime_check", params: params, timeout: .seconds(60))
        guard case .object(let fields) = response else { throw SetupFailure.invalidResponse }
        ready = fields["ok"] == .bool(true)
        if case .string(let provider) = fields["provider"] { currentProvider = provider }
        if case .string(let model) = fields["model"] { currentModel = model }
        if case .string(let effort) = fields["effort"] { currentEffort = effort }
        if let expectedProvider { ready = ready && currentProvider == expectedProvider }
        if let expectedModel { ready = ready && currentModel == expectedModel }
        status = ready ? "HeyMate is ready. Your selected provider and model will answer the next turn."
            : "Connect your plan or API provider in Brain to continue."
    }

    private func readInventory(_ value: JSONValue) {
        guard case .object(let fields) = value else { return }
        if case .string(let model) = fields["model"] { currentModel = model }
        if case .string(let provider) = fields["provider"] { currentProvider = provider }
        if case .string(let effort) = fields["effort"] { currentEffort = effort }
        currentBaseURL = fields["base_url"].flatMap { if case .string(let value) = $0 { return value }; return nil } ?? ""
        currentAPIFormat = fields["api_format"].flatMap { if case .string(let value) = $0 { return value }; return nil } ?? "openai-completions"
        guard case .array(let rows) = fields["providers"] else { return }
        providers = rows.compactMap { value in
            guard case .object(let row) = value, case .string(let slug) = row["slug"],
                  case .string(let name) = row["name"] else { return nil }
            let models: [String]
            if case .array(let entries) = row["models"] {
                models = entries.compactMap { if case .string(let model) = $0 { return model }; return nil }
            } else { models = [] }
            var efforts: [String: [String]] = [:]
            if case .object(let map) = row["efforts"] {
                for (id, value) in map {
                    guard case .array(let levels) = value else { continue }
                    efforts[id] = levels.compactMap { if case .string(let level) = $0 { return level }; return nil }
                }
            }
            var modelNames: [String: String] = [:]
            if case .object(let map) = row["model_names"] {
                for (id, value) in map { if case .string(let name) = value { modelNames[id] = name } }
            }
            let authType: String
            if case .string(let value) = row["auth_type"] { authType = value } else { authType = "" }
            return Provider(id: slug, name: name, models: models, efforts: efforts, modelNames: modelNames, authenticated: row["authenticated"] == .bool(true), authType: authType)
        }
    }

    nonisolated enum SetupFailure: Error { case invalidResponse, unsafeProfile, existingProfile }

    /// Explicit button action only. Never clones a user profile or its credentials.
    nonisolated static func createProfile(at url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let global = home.appendingPathComponent(".pi/agent").resolvingSymlinksInPath().standardizedFileURL
        guard url.isFileURL, url.path.hasPrefix("/"), canonical.path != global.path,
              !canonical.path.hasPrefix(global.path + "/"), canonical.path != home.path, canonical.path != "/" else {
            throw SetupFailure.unsafeProfile
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw SetupFailure.existingProfile }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = url.appendingPathComponent("settings.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "approvals": "manual", "enabledSkills": [], "agent": "heymate-pi"
            ], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: config, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        } catch {
            // Preserve any partially created directory for inspection; never remove
            // a path that another process might have begun using.
            throw error
        }
    }
}
