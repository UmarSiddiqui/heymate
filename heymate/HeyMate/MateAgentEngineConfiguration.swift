import Foundation

/// Fixed HeyMate runtime identity. Retired preferences cannot select another engine.
nonisolated enum MateEngine: String {
    case pi

    static let preferenceKey = "selectedMateEngine"
    // Retired preference key remains only for migration.
    // Runtime selection is fixed; a saved legacy preference cannot enable it.
    static func migrateRetiredSelection(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: preferenceKey)
    }
    var displayName: String { "HeyMate" }
    static func selected(defaults: UserDefaults = .standard) -> MateEngine { .pi }

    static var bundledRuntimeAvailable: Bool {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("MateAgent") else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
    }
}

nonisolated struct MateAgentEngineLaunchConfiguration: Equatable {
    let executableURL: URL
    let profileDirectoryURL: URL
    let environment: [String: String]
    var expectedCommit: String? = nil
}

nonisolated struct MateAgentEngineConfiguration {
    static let executablePathKey = "piAgentExecutablePath"
    static let profilePathKey = "piAgentProfilePath"
    static let runtimePathKey = "piAgentRuntimePath"
    static var defaultProfilePath: String {
        HeyMateDataDirectory.url.appendingPathComponent("pi-agent", isDirectory: true).path
    }

    var executablePath: String
    var profilePath: String
    var runtimePath: String = ""
    var requiresBundledRuntime = false

    static func load(defaults: UserDefaults = .standard) -> Self {
        var configuration = Self(executablePath: "", profilePath: defaultProfilePath, runtimePath: "")
        configuration.requiresBundledRuntime = true
        return configuration
    }

    enum ConfigurationError: LocalizedError, Equatable {
        case executableMissing
        case executablePathMustBeAbsolute
        case executableNotRunnable
        case launcherOverridesProfile
        case profilePathMustBeAbsolute
        case profileMissing
        case sharedGlobalProfile
        case runtimeMissing
        case invalidBundledRuntime

        var errorDescription: String? {
            switch self {
            case .runtimeMissing: return "Choose an existing absolute HeyMate Agent runtime tools folder."
            case .invalidBundledRuntime: return "The bundled HeyMate agent runtime is incomplete or invalid. Reinstall HeyMate."
            case .executableMissing: return "HeyMate Agent was not found in your login-shell PATH. Set its full executable path."
            case .executablePathMustBeAbsolute: return "Use an absolute HeyMate Agent executable path."
            case .executableNotRunnable: return "The HeyMate Agent path is not an executable file."
            case .launcherOverridesProfile: return "This shell launcher assigns HEYMATE_AGENT_HOME and overrides the isolated profile. Choose the HeyMate harness launcher instead."
            case .profilePathMustBeAbsolute: return "Use an absolute path for the isolated HeyMate agent profile."
            case .profileMissing: return "The isolated HeyMate agent profile folder does not exist. Prepare it locally before using HeyMate Agent."
            case .sharedGlobalProfile: return "Choose a separate HeyMate agent profile, not your global ~/.pi/agent folder."
            }
        }
    }

    /// Reads setup only. Never installs MateAgent, creates profiles, changes auth,
    /// or falls back to another engine when the selected engine is unavailable.
    func resolveLaunchConfiguration(
        resolving resolve: (String) -> URL? = { LoginShellExecutableResolver.resolveExecutable(named: $0) },
        loginPATH: () -> String = { LoginShellExecutableResolver.loginPATH() },
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundledRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent("MateAgent", isDirectory: true)
    ) throws -> MateAgentEngineLaunchConfiguration {
        let executable = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let executableURL: URL
        var bundle: BundledRuntime?
        if executable.isEmpty, let bundledRoot, fileManager.fileExists(atPath: bundledRoot.path) {
            bundle = try Self.readBundledRuntime(at: bundledRoot)
        }
        if requiresBundledRuntime, bundle == nil { throw ConfigurationError.invalidBundledRuntime }
        if let bundle {
            executableURL = bundle.executable
        } else if executable.isEmpty {
            guard let resolved = resolve("heymate-agent") else { throw ConfigurationError.executableMissing }
            executableURL = resolved
        } else {
            guard executable.hasPrefix("/") else { throw ConfigurationError.executablePathMustBeAbsolute }
            executableURL = URL(fileURLWithPath: executable)
        }
        var executableIsDirectory: ObjCBool = false
        guard executableURL.path.hasPrefix("/"),
              fileManager.fileExists(atPath: executableURL.path, isDirectory: &executableIsDirectory),
              !executableIsDirectory.boolValue,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw ConfigurationError.executableNotRunnable
        }
        if try shellLauncherOverridesProfile(at: executableURL) {
            throw ConfigurationError.launcherOverridesProfile
        }
        let profile = profilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.hasPrefix("/") else { throw ConfigurationError.profilePathMustBeAbsolute }
        let profileURL = URL(fileURLWithPath: profile, isDirectory: true).standardizedFileURL
        let globalProfileURL = homeDirectoryURL.appendingPathComponent(".pi/agent", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard profileURL.resolvingSymlinksInPath() != globalProfileURL, !profileURL.resolvingSymlinksInPath().path.hasPrefix(globalProfileURL.path + "/") else { throw ConfigurationError.sharedGlobalProfile }
        var profileIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: profileURL.path, isDirectory: &profileIsDirectory),
              profileIsDirectory.boolValue else { throw ConfigurationError.profileMissing }
        var environment = ["HEYMATE_AGENT_HOME": profileURL.path, "PATH": loginPATH()]
        let runtime = runtimePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !runtime.isEmpty {
            var isDirectory: ObjCBool = false
            guard runtime.hasPrefix("/"), fileManager.fileExists(atPath: runtime, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConfigurationError.runtimeMissing
            }
            environment["HEYMATE_AGENT_RUNTIME_DIR"] = URL(fileURLWithPath: runtime).resolvingSymlinksInPath().path
        } else if let bundle { environment["HEYMATE_AGENT_RUNTIME_DIR"] = bundle.runtime.path }
        return MateAgentEngineLaunchConfiguration(executableURL: executableURL, profileDirectoryURL: profileURL,
            environment: environment, expectedCommit: bundle?.commit)
    }

    private struct BundledRuntime {
        let executable: URL
        let runtime: URL
        let commit: String
    }

    private static func readBundledRuntime(at root: URL) throws -> BundledRuntime {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let manifest = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest), data.count <= 8 * 1_024 * 1_024,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationError.invalidBundledRuntime
        }
        if let payloads = fields["payloads"] as? [String: String] {
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            guard let relative = payloads[architecture], !relative.isEmpty, !relative.hasPrefix("/"),
                  !relative.split(separator: "/").contains("..") else { throw ConfigurationError.invalidBundledRuntime }
            let child = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
            guard child.path.hasPrefix(canonical.path + "/"), child.path != canonical.path else { throw ConfigurationError.invalidBundledRuntime }
            guard let childData = try? Data(contentsOf: child.appendingPathComponent("manifest.json")), childData.count <= 8 * 1_024 * 1_024,
                  let childFields = try? JSONSerialization.jsonObject(with: childData) as? [String: Any], childFields["payloads"] == nil else {
                throw ConfigurationError.invalidBundledRuntime
            }
            let runtime = try readBundledRuntime(at: child)
            guard fields["sourceCommit"] as? String == runtime.commit else { throw ConfigurationError.invalidBundledRuntime }
            return runtime
        }
        guard let executable = fields["executablePath"] as? String,
              let runtime = fields["runtimePath"] as? String,
              let commit = fields["sourceCommit"] as? String,
              commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw ConfigurationError.invalidBundledRuntime
        }
        func child(_ relative: String) throws -> URL {
            guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                throw ConfigurationError.invalidBundledRuntime
            }
            let url = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(canonical.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
                throw ConfigurationError.invalidBundledRuntime
            }
            return url
        }
        return try BundledRuntime(executable: child(executable), runtime: child(runtime), commit: commit)
    }

    private func shellLauncherOverridesProfile(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 1_024 * 1_024),
              let source = String(data: data, encoding: .utf8), source.hasPrefix("#!") else { return false }
        let firstLine = source.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let words = firstLine.dropFirst(2).split(whereSeparator: \.isWhitespace)
        let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
        guard words.contains(where: { shellNames.contains(URL(fileURLWithPath: String($0)).lastPathComponent) }) else { return false }
        let executableLines = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        return executableLines.range(of: #"(?:^|[\s;])(?:export\s+)?HEYMATE_AGENT_HOME\s*="#,
                                     options: .regularExpression) != nil
    }
}
