import Foundation

nonisolated enum CodexExecutionIsolation {
    /// Only app-supplied MCP overrides may be added to the isolated process.
    /// The config probe resolves inherited names before any thread is resumed.
    static func serverNames(_ arguments: [String]) throws -> Set<String> {
        guard arguments.count.isMultiple(of: 2) else { throw CodexPlanningIsolation.Failure.unsafeConfiguration }
        var names = Set<String>()
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard arguments[index] == "-c" else { throw CodexPlanningIsolation.Failure.unsafeConfiguration }
            let path = arguments[index + 1].split(separator: "=", maxSplits: 1).first?.split(separator: ".") ?? []
            guard path.count == 3, path[0] == "mcp_servers", !path[1].isEmpty,
                  path[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
                  ["command", "args", "env_vars", "enabled_tools", "default_tools_approval_mode"].contains(String(path[2])) else {
                throw CodexPlanningIsolation.Failure.unsafeConfiguration
            }
            names.insert(String(path[1]))
        }
        return names
    }

    static func arguments(probe: JSONValue, mcpArguments: [String]) throws -> [String] {
        let names = try serverNames(mcpArguments)
        return try CodexPlanningIsolation.arguments(disablingServersFrom: probe) + mcpArguments
            + names.sorted().flatMap { ["-c", "mcp_servers.\($0).enabled=true"] }
    }

    static func validate(_ response: JSONValue, mcpArguments: [String]) throws {
        let names = try serverNames(mcpArguments)
        guard case .object(let root) = response, case .object(let config) = root["config"],
              config["notify"] == .array([]), config["model_provider"] == .string("openai"),
              case .object(let features) = config["features"],
              CodexPlanningIsolation.disabledFeatures.allSatisfy({ features[$0] == .bool(false) }) else {
            throw CodexPlanningIsolation.Failure.unsafeConfiguration
        }
        if let value = config["mcp_servers"] {
            guard case .object(let servers) = value else { throw CodexPlanningIsolation.Failure.unsafeConfiguration }
            for (name, value) in servers {
                guard case .object(let server) = value,
                      names.contains(name) ? server["enabled"] == .bool(true) : server["enabled"] == .bool(false) else {
                    throw CodexPlanningIsolation.Failure.unsafeConfiguration
                }
            }
            guard names.isSubset(of: Set(servers.keys)) else { throw CodexPlanningIsolation.Failure.unsafeConfiguration }
        } else if !names.isEmpty { throw CodexPlanningIsolation.Failure.unsafeConfiguration }
    }
}
