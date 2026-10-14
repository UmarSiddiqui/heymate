import Foundation

/// Process/thread-local overrides only. Never writes the user's Codex config.
nonisolated enum CodexPlanningIsolation {
    enum Failure: LocalizedError {
        case invalidConfiguration, unsafeConfiguration
        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "Codex did not return a supported planning configuration."
            case .unsafeConfiguration: return "Codex could not apply HeyMate's read-only planning settings."
            }
        }
    }

    static let disabledFeatures = ["apps", "hooks", "plugins", "multi_agent"]
    static var arguments: [String] {
        ["app-server", "--listen", "stdio://", "-c", "notify=[]", "-c", "model_provider=\"openai\""]
            + disabledFeatures.flatMap { ["-c", "features.\($0)=false"] }
    }

    private static func validatedServerNames(from response: JSONValue) throws -> [String] {
        guard case .object(let response) = response, case .object(let config) = response["config"],
              case .object(let features) = config["features"] else { throw Failure.invalidConfiguration }
        guard disabledFeatures.allSatisfy({ features[$0] == .bool(false) }),
              config["notify"] == .array([]), config["model_provider"] == .string("openai") else {
            throw Failure.unsafeConfiguration
        }
        if let servers = config["mcp_servers"] {
            guard case .object(let servers) = servers else { throw Failure.invalidConfiguration }
            return servers.keys.sorted()
        }
        return []
    }

    static func arguments(disablingServersFrom response: JSONValue) throws -> [String] {
        let names = try validatedServerNames(from: response)
        guard !names.isEmpty else { return arguments }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let entries = try names.map { name in
            let quoted = String(decoding: try encoder.encode(name), as: UTF8.self)
            return "\(quoted)={enabled=false}"
        }
        // CLI splits override *paths* on dots even inside quotes. Put server
        // names inside a TOML inline-table value, whose parser respects quoting.
        // This merges explicit enabled=false into each discovered server; an
        // empty mcp_servers={} does not clear inherited entries.
        return arguments + ["-c", "mcp_servers={\(entries.joined(separator: ","))}"]
    }

    static func validateFinalConfiguration(_ response: JSONValue) throws {
        _ = try validatedServerNames(from: response)
        guard case .object(let response) = response, case .object(let config) = response["config"] else {
            throw Failure.invalidConfiguration
        }
        if let servers = config["mcp_servers"] {
            guard case .object(let servers) = servers,
                  servers.values.allSatisfy({ value in
                      if case .object(let server) = value { return server["enabled"] == .bool(false) }
                      return false
                  }) else { throw Failure.unsafeConfiguration }
        }
    }
}
