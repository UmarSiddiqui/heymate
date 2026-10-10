//
//  GoogleWorkspaceCLIStatus.swift
//  HeyMate
//
//  Whether `gog` (gogcli, the Google Workspace command-line tool agents use)
//  is installed and signed in, for the Google row in Settings. It only
//  looks at files: running `gog` from a GUI app can block on its file-
//  keyring passphrase prompt.
//

import Foundation

nonisolated struct GoogleWorkspaceCLIStatus: Equatable, Sendable {
    var executablePath: String?
    var credentialsExist = false
    /// "default" when the default OAuth client is present.
    var client: String?
    var accountEmail: String?
    var keyringBackend: String?

    static let unknown = GoogleWorkspaceCLIStatus()

    var isInstalled: Bool { executablePath != nil }

    private var hasAccount: Bool { accountEmail?.isEmpty == false }

    /// The file keyring asks for its passphrase whenever an agent uses it.
    var needsKeyringPassphrase: Bool { keyringBackend == "file" && hasAccount }

    var isReadyForUserAccount: Bool { isInstalled && credentialsExist && hasAccount }

    var readinessTitle: String {
        if !isInstalled { return "gogcli not found by HeyMate" }
        if !credentialsExist { return "OAuth client needed" }
        return hasAccount ? "Connected locally" : "Authorize an account"
    }

    var readinessDetail: String {
        if !isInstalled {
            return "HeyMate could not see gog at /opt/homebrew/bin/gog, /usr/local/bin/gog, or HEYMATE_GOG_PATH."
        }
        if !credentialsExist {
            return "Add a Google Cloud Desktop OAuth client JSON with gog auth credentials."
        }
        guard let accountEmail, hasAccount else {
            return "Credentials are present; run gog auth add for the Google account you want HeyMate agents to use."
        }
        if needsKeyringPassphrase {
            return "Using \(accountEmail). gogcli may ask for its local file-keyring passphrase when an agent runs Google commands."
        }
        return "Using \(accountEmail) via \(keyringBackend ?? "local keyring")."
    }
}

nonisolated enum GoogleWorkspaceCLIInspector {
    static let pathOverrideVariable = "HEYMATE_GOG_PATH"
    static let standardExecutablePaths = ["/opt/homebrew/bin/gog", "/usr/local/bin/gog", "/usr/bin/gog"]

    /// Inspects in the background so Settings never waits on the disk.
    static func refresh() async -> GoogleWorkspaceCLIStatus {
        await Task.detached(priority: .utility) { inspect() }.value
    }

    /// Everything is injectable so tests use a temporary home and never see
    /// a real gogcli install.
    static func inspect(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePaths: [String] = standardExecutablePaths
    ) -> GoogleWorkspaceCLIStatus {
        let support = homeDirectory.appendingPathComponent("Library/Application Support/gogcli", isDirectory: true)
        var status = GoogleWorkspaceCLIStatus()

        let override = environment[pathOverrideVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [override].compactMap { $0 }.filter { !$0.isEmpty } + executablePaths
        status.executablePath = candidates.first { fileManager.fileExists(atPath: $0) }

        status.credentialsExist = fileManager.fileExists(atPath: support.appendingPathComponent("credentials.json").path)
        status.client = status.credentialsExist ? "default" : nil
        status.keyringBackend = keyringBackend(inConfigAt: support.appendingPathComponent("config.json"))

        // Signed-in accounts are keyring entries named "token:…:<email>";
        // the alphabetically first one is reported.
        let keyring = support.appendingPathComponent("keyring", isDirectory: true)
        let entries = (try? fileManager.contentsOfDirectory(atPath: keyring.path)) ?? []
        status.accountEmail = entries
            .filter { $0.hasPrefix("token:") }
            .compactMap { $0.split(separator: ":").last.map(String.init) }
            .filter { $0.contains("@") }
            .min()
        return status
    }

    /// The `keyring_backend` setting, read leniently (comments and trailing
    /// commas allowed).
    private static func keyringBackend(inConfigAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
        else { return nil }
        return config["keyring_backend"] as? String
    }
}
