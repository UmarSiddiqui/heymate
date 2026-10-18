import Foundation

/// App-wide harness selection, independent of a mate's provider and model.
nonisolated enum MateEngine: String, CaseIterable, Identifiable {
    case native
    case hermes

    static let preferenceKey = "selectedMateEngine"
    var id: String { rawValue }
    var displayName: String { self == .native ? "Previous engine (legacy)" : "Hermes" }

    static func selected(defaults: UserDefaults = .standard) -> MateEngine {
        if let value = defaults.string(forKey: preferenceKey), let engine = MateEngine(rawValue: value) { return engine }
        return bundledRuntimeAvailable ? .hermes : .native
    }

    static var bundledRuntimeAvailable: Bool {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Hermes") else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
    }
}

nonisolated struct HermesEngineLaunchConfiguration: Equatable {
    let executableURL: URL
    let profileDirectoryURL: URL
    let environment: [String: String]
    var expectedCommit: String? = nil
}

nonisolated struct HermesEngineConfiguration {
    static let executablePathKey = "hermesExecutablePath"
    static let profilePathKey = "hermesProfilePath"
    static let runtimePathKey = "hermesRuntimePath"
    static var defaultProfilePath: String {
        HeyMateDataDirectory.url.appendingPathComponent("experimental-hermes", isDirectory: true).path
    }

    var executablePath: String
    var profilePath: String
    var runtimePath: String = ""

    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(executablePath: defaults.string(forKey: executablePathKey) ?? "",
             profilePath: defaults.string(forKey: profilePathKey) ?? defaultProfilePath,
             runtimePath: defaults.string(forKey: runtimePathKey) ?? "")
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
            case .runtimeMissing: return "Choose an existing absolute Hermes runtime tools folder."
            case .invalidBundledRuntime: return "The bundled Hermes runtime is incomplete or invalid. Reinstall HeyMate."
            case .executableMissing: return "Hermes was not found in your login-shell PATH. Set its full executable path."
            case .executablePathMustBeAbsolute: return "Use an absolute Hermes executable path."
            case .executableNotRunnable: return "The Hermes path is not an executable file."
            case .launcherOverridesProfile: return "This shell launcher assigns HERMES_HOME and overrides the isolated profile. Choose the direct official Hermes launcher instead."
            case .profilePathMustBeAbsolute: return "Use an absolute path for the isolated Hermes profile."
            case .profileMissing: return "The isolated Hermes profile folder does not exist. Prepare it locally before using Hermes."
            case .sharedGlobalProfile: return "Choose a separate Hermes profile, not your global ~/.hermes folder."
            }
        }
    }

    /// Reads setup only. Never installs Hermes, creates profiles, changes auth,
    /// or falls back to another engine when the selected engine is unavailable.
    func resolveLaunchConfiguration(
        resolving resolve: (String) -> URL? = { LoginShellExecutableResolver.resolveExecutable(named: $0) },
        loginPATH: () -> String = { LoginShellExecutableResolver.loginPATH() },
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundledRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent("Hermes", isDirectory: true)
    ) throws -> HermesEngineLaunchConfiguration {
        let executable = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let executableURL: URL
        var bundle: BundledRuntime?
        if executable.isEmpty, let bundledRoot, fileManager.fileExists(atPath: bundledRoot.path) {
            bundle = try Self.readBundledRuntime(at: bundledRoot)
        }
        if let bundle {
            executableURL = bundle.executable
        } else if executable.isEmpty {
            guard let resolved = resolve("hermes") else { throw ConfigurationError.executableMissing }
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
        let globalProfileURL = homeDirectoryURL.appendingPathComponent(".hermes", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard profileURL.resolvingSymlinksInPath() != globalProfileURL else { throw ConfigurationError.sharedGlobalProfile }
        var profileIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: profileURL.path, isDirectory: &profileIsDirectory),
              profileIsDirectory.boolValue else { throw ConfigurationError.profileMissing }
        var environment = ["HERMES_HOME": profileURL.path, "PATH": loginPATH()]
        let runtime = runtimePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !runtime.isEmpty {
            var isDirectory: ObjCBool = false
            guard runtime.hasPrefix("/"), fileManager.fileExists(atPath: runtime, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConfigurationError.runtimeMissing
            }
            environment["HERMES_RUNTIME_DIR"] = URL(fileURLWithPath: runtime).resolvingSymlinksInPath().path
        } else if let bundle { environment["HERMES_RUNTIME_DIR"] = bundle.runtime.path }
        return HermesEngineLaunchConfiguration(executableURL: executableURL, profileDirectoryURL: profileURL,
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
        guard let data = try? Data(contentsOf: manifest), data.count <= 262_144,
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
            guard let childData = try? Data(contentsOf: child.appendingPathComponent("manifest.json")), childData.count <= 262_144,
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
        return executableLines.range(of: #"(?:^|[\s;])(?:export\s+)?HERMES_HOME\s*="#,
                                     options: .regularExpression) != nil
    }
}
