import AppKit
import Foundation

/// Owns only the loopback server started by HeyMate. Existing servers remain user-owned.
final class OpenCodeLocalServer {
    private var process: Process?
    private var configurationHome: URL?
    private var terminationObserver: NSObjectProtocol?

    var isRunning: Bool { process?.isRunning == true }

    static func supports(_ url: URL) -> Bool {
        url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? "")
            && (url.port ?? 80) == 4096 && ["", "/"].contains(url.path)
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    func start(executable: URL, username: String, password: String) throws {
        guard !isRunning else { return }
        stop()
        let home = OpenCodeRuntimeIsolation.makeConfigurationHome()
        configurationHome = home
        let child = Process()
        child.executableURL = executable
        child.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "4096"]
        child.currentDirectoryURL = home
        var overrides = OpenCodeRuntimeIsolation.persistentRuntimeEnvironment()
        overrides.merge([
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.path,
            "OPENCODE_TEST_HOME": home.path,
            "OPENCODE_TEST_MANAGED_CONFIG_DIR": home.appendingPathComponent("managed").path,
            "OPENCODE_DISABLE_PROJECT_CONFIG": "true",
            "OPENCODE_DISABLE_CLAUDE_CODE": "true",
            "OPENCODE_DISABLE_EXTERNAL_SKILLS": "true",
            "OPENCODE_DISABLE_DEFAULT_PLUGINS": "true",
            "OPENCODE_CONFIG_CONTENT": #"{"mcp":{},"plugin":[],"permission":"deny"}"#,
            "OPENCODE_SERVER_USERNAME": username,
            "OPENCODE_SERVER_PASSWORD": password
        ]) { _, value in value }
        child.environment = HeadlessChildEnvironment.build(
            stripping: HeadlessExecutor.openCode.environmentKeysToRemove, overrides: overrides
        )
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
    }

    func stop() {
        if let process, process.isRunning {
            // Cleanup only after the child exits; never remove its live working directory.
            let home = configurationHome
            process.terminationHandler = { _ in
                if let home { OpenCodeTemporaryDirectoryCleaner.remove([home]) }
            }
            process.terminate()
        } else if let configurationHome {
            OpenCodeTemporaryDirectoryCleaner.remove([configurationHome])
        }
        process = nil
        configurationHome = nil
    }
}
