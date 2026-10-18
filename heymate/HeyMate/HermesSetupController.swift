import Foundation
import Combine

/// Setup talks only to the app-owned backend. Credentials never enter chat history,
/// preferences, diagnostics or model prompts; Hermes saves them in its isolated home.
@MainActor
final class HermesSetupController: ObservableObject {
    struct Provider: Identifiable, Equatable {
        let id: String
        let name: String
        let models: [String]
        let authenticated: Bool
        let authType: String
    }
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var providers: [Provider] = []
    @Published private(set) var currentModel = ""
    @Published private(set) var currentProvider = ""
    @Published private(set) var ready = false
    @Published private(set) var confirmationMessage: String?
    private var pendingModel: (HermesEngineConfiguration, String, String)?
    private let backend: HermesServeBackend
    private let openGateway: ((HermesEngineLaunchConfiguration) async throws -> HermesServeWebSocket)?
    private let writeModel: ((JSONValue) async throws -> JSONValue)?

    init(backend: HermesServeBackend = .shared,
         openGateway: ((HermesEngineLaunchConfiguration) async throws -> HermesServeWebSocket)? = nil,
         writeModel: ((JSONValue) async throws -> JSONValue)? = nil) {
        self.backend = backend
        self.openGateway = openGateway
        self.writeModel = writeModel
    }

    func check(_ configuration: HermesEngineConfiguration) async {
        await perform(configuration) { socket in
            let inventory = try await socket.request(method: "model.options", params: .object([
                "include_unconfigured": .bool(true)
            ]), timeout: .seconds(60))
            self.readInventory(inventory)
            try await self.readReadiness(socket)
        }
    }

    func connect(_ configuration: HermesEngineConfiguration, provider: String, model: String, key: String, confirmed: Bool = false) async {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["openai-codex", "openai", "anthropic"].contains(provider), !cleanModel.isEmpty,
              cleanModel.utf8.count <= 256, !cleanModel.contains(where: \.isNewline), cleanKey.utf8.count <= 16_384 else {
            status = "Choose a provider and enter a model name."; return
        }
        await perform(configuration) { socket in
            if provider != "openai-codex", !cleanKey.isEmpty {
                _ = try await socket.request(method: "model.save_key", params: .object([
                    "slug": .string(provider), "api_key": .string(cleanKey)
                ]), timeout: .seconds(60))
            }
            // Use Hermes' validated assignment path; generic config merges can
            // retain stale transport or credential fields from another provider.
            let choice = JSONValue.object([
                "scope": .string("main"), "provider": .string(provider), "model": .string(cleanModel),
                "base_url": .string(""), "api_key": .string(""), "confirm_expensive_model": .bool(confirmed)
            ])
            let saved: JSONValue
            if let writeModel = self.writeModel { saved = try await writeModel(choice) }
            else { saved = try await self.backend.requestHTTP(path: "/api/model/set", method: "POST", body: choice) }
            guard case .object(let fields) = saved else { throw SetupFailure.invalidResponse }
            if fields["confirm_required"] == .bool(true) {
                self.pendingModel = (configuration, provider, cleanModel)
                if case .string(let message) = fields["confirm_message"] { self.confirmationMessage = String(message.prefix(2_000)) }
                else { self.confirmationMessage = "Hermes requires confirmation before selecting this model." }
                self.status = "Model change awaits your confirmation."
                return
            }
            guard fields["ok"] == .bool(true) else { throw SetupFailure.invalidResponse }
            self.pendingModel = nil
            self.confirmationMessage = nil
            self.currentModel = cleanModel
            self.currentProvider = provider
            try await self.readReadiness(socket, expectedProvider: provider, expectedModel: cleanModel)
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

    private func perform(_ configuration: HermesEngineConfiguration,
                         action: (HermesServeWebSocket) async throws -> Void) async {
        guard !busy else { return }
        busy = true; ready = false; status = "Checking Hermes…"
        defer { busy = false }
        do {
            let launch = try configuration.resolveLaunchConfiguration()
            let socket: HermesServeWebSocket
            if let openGateway { socket = try await openGateway(launch) }
            else {
                if let identity = backend.identity,
                   identity.home.resolvingSymlinksInPath().path != launch.profileDirectoryURL.resolvingSymlinksInPath().path {
                    guard await backend.shutdown() else { throw HermesServeBackend.Failure.notRunning }
                }
                do { _ = try await backend.start(configuration: launch) }
                catch HermesServeBackend.Failure.alreadyRunningDifferentProfile {
                    guard await backend.shutdown() else { throw HermesServeBackend.Failure.notRunning }
                    _ = try await backend.start(configuration: launch)
                }
                socket = try backend.openWebSocket()
            }
            defer { socket.close() }
            try await action(socket)
        } catch is CancellationError {
            status = "Setup cancelled."
        } catch let error as HermesEngineConfiguration.ConfigurationError {
            status = error.localizedDescription
        } catch let error as HermesServeBackend.Failure {
            status = error.localizedDescription
        } catch {
            // Backend/provider errors may include request values. Show a bounded
            // fixed message rather than echoing a credential-bearing remote error.
            status = "Hermes setup could not finish. Check the runtime and profile, then try again. No alternate engine was started."
        }
    }

    private func readReadiness(_ socket: HermesServeWebSocket, expectedProvider: String? = nil,
                               expectedModel: String? = nil) async throws {
        let params: JSONValue = expectedProvider.map { .object(["provider": .string($0)]) } ?? .emptyObject
        let response = try await socket.request(method: "setup.runtime_check", params: params, timeout: .seconds(60))
        guard case .object(let fields) = response else { throw SetupFailure.invalidResponse }
        ready = fields["ok"] == .bool(true)
        if case .string(let provider) = fields["provider"] { currentProvider = provider }
        if case .string(let model) = fields["model"] { currentModel = model }
        if let expectedProvider { ready = ready && currentProvider == expectedProvider }
        if let expectedModel { ready = ready && currentModel == expectedModel }
        status = ready ? "Hermes is ready. New conversations use the selected provider and model."
            : "Hermes started, but the selected provider is not ready. Add an API key and choose a model."
    }

    private func readInventory(_ value: JSONValue) {
        guard case .object(let fields) = value else { return }
        if case .string(let model) = fields["model"] { currentModel = model }
        if case .string(let provider) = fields["provider"] { currentProvider = provider }
        guard case .array(let rows) = fields["providers"] else { return }
        providers = rows.compactMap { value in
            guard case .object(let row) = value, case .string(let slug) = row["slug"],
                  case .string(let name) = row["name"] else { return nil }
            let models: [String]
            if case .array(let entries) = row["models"] {
                models = entries.compactMap { if case .string(let model) = $0 { return model }; return nil }
            } else { models = [] }
            let authType: String
            if case .string(let value) = row["auth_type"] { authType = value } else { authType = "" }
            return Provider(id: slug, name: name, models: models, authenticated: row["authenticated"] == .bool(true), authType: authType)
        }
    }

    nonisolated enum SetupFailure: Error { case invalidResponse, unsafeProfile, existingProfile }

    /// Explicit button action only. Never clones a user profile or its credentials.
    nonisolated static func createProfile(at url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let global = home.appendingPathComponent(".hermes").resolvingSymlinksInPath().standardizedFileURL
        guard url.isFileURL, url.path.hasPrefix("/"), canonical.path != global.path,
              !canonical.path.hasPrefix(global.path + "/"), canonical.path != home.path, canonical.path != "/" else {
            throw SetupFailure.unsafeProfile
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw SetupFailure.existingProfile }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = url.appendingPathComponent("config.yaml")
        do {
            // JSON is YAML-compatible. Only a newly created empty home is written.
            let data = try JSONSerialization.data(withJSONObject: [
                "approvals": ["mode": "manual"], "skills": ["write_approval": true],
                "model": ["openai_runtime": "auto"], "auth": ["adopt_external_logins": false]
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
