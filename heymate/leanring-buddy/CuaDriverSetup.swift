//
//  CuaDriverSetup.swift
//  leanring-buddy
//
//  Finds, installs, and upgrades Cua's background computer-use driver, and
//  hands it to approved agent jobs.
//
//  The decisions — which release, which tools, how a child is configured —
//  live in the HeyMateComputerUse package. This file is the part that needs
//  a running Mac: launching processes, the network, and the UI's view of it.
//
//  Nothing here downloads on its own. The installer is fetched only when the
//  user presses Install or Update in Settings → Computer control, and it is
//  run only if its bytes match the hash pinned in `CuaDriverRelease`.
//

import Combine
import CryptoKit
import Foundation
import HeyMateComputerUse

@MainActor
final class CuaDriverSetup: ObservableObject {

    static let shared = CuaDriverSetup()

    enum Phase: Equatable {
        case idle
        case installing
        case failed(String)
    }

    @Published private(set) var installation: CuaDriverInstallation = .missing
    @Published private(set) var phase: Phase = .idle

    private let release = CuaDriverRelease.pinned

    private init() {}

    // MARK: - Status

    /// Re-reads what is installed. Cheap: one `--version` call.
    func refresh() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let found = await Task.detached(priority: .utility) {
            Self.locate(homeDirectory: home)
        }.value
        installation = found
    }

    nonisolated private static func locate(homeDirectory: URL) -> CuaDriverInstallation {
        let executable = CuaDriverInstallation.candidateExecutables(homeDirectory: homeDirectory)
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let executable else { return .missing }
        let output = try? runToCompletion(executable: executable, arguments: ["--version"], timeout: 10)
        return CuaDriverInstallation.classify(executable: executable, versionOutput: output?.standardOutput)
    }

    // MARK: - Install

    /// Downloads the pinned installer, verifies it, runs it, then opens the
    /// driver's own permission flow so the grants attach to CuaDriver.app.
    func install() async {
        guard phase != .installing else { return }
        phase = .installing
        do {
            let release = self.release
            try await Task.detached(priority: .userInitiated) {
                try await Self.runPinnedInstaller(release)
            }.value
            await refresh()
            guard let executable = installation.readyExecutable else {
                throw SetupError("The installer finished but no current driver was found.")
            }
            // LaunchServices opens CuaDriver.app so the macOS prompts name
            // it, not HeyMate. Returns once the prompts are up.
            _ = try? await Task.detached {
                try Self.runToCompletion(executable: executable, arguments: ["permissions", "grant"], timeout: 180)
            }.value
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
            await refresh()
        }
    }

    nonisolated private static func runPinnedInstaller(_ release: CuaDriverRelease) async throws {
        let (data, response) = try await URLSession.shared.data(from: release.installerURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SetupError("Could not download the Cua installer.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard release.isTrustedInstaller(sha256HexDigest: digest) else {
            throw SetupError("The downloaded Cua installer did not match the reviewed version, so it was not run.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-cua-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("install-cua-driver.sh")
        try data.write(to: scriptURL)

        let result = try runToCompletion(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path, "--no-modify-path"],
            environmentOverrides: release.installerEnvironment,
            timeout: 15 * 60
        )
        guard result.status == 0 else {
            let detail = result.standardError
                .split(separator: "\n")
                .last(where: { $0.contains("error") }) ?? "exit \(result.status)"
            throw SetupError("Cua's installer failed: \(detail)")
        }
    }

    // MARK: - Agent wiring

    /// The Cua server for an approved Claude leg, when computer control is on
    /// and a current driver is installed.
    func claudeServers(computerControlEnabled: Bool) -> [String: Any] {
        guard computerControlEnabled, let executable = installation.readyExecutable else { return [:] }
        return [CuaDriverMCPConfiguration.serverName: CuaDriverMCPConfiguration.claudeServerEntry(executable: executable)]
    }

    func claudeAllowedToolNames(computerControlEnabled: Bool) -> [String] {
        guard computerControlEnabled, installation.readyExecutable != nil else { return [] }
        return CuaDriverMCPConfiguration.claudeAllowedToolNames()
    }

    func codexArguments(computerControlEnabled: Bool) -> [String] {
        guard computerControlEnabled, let executable = installation.readyExecutable else { return [] }
        return CuaDriverMCPConfiguration.codexArguments(executable: executable)
    }

    // MARK: - Process

    struct ProcessResult {
        var status: Int32
        var standardOutput: String
        var standardError: String
    }

    struct SetupError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    nonisolated private static func runToCompletion(
        executable: URL,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Never hand a metered key to someone else's installer.
        for key in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"] { environment.removeValue(forKey: key) }
        environment.merge(environmentOverrides) { _, new in new }
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting so a chatty child cannot fill the pipe and stall.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
