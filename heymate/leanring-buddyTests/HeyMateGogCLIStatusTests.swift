//
//  HeyMateGogCLIStatusTests.swift
//  leanring-buddyTests
//
//  Settings gogcli readiness is file inspection only. Fixtures live in a
//  temp home so tests never touch the user's real gogcli install or spawn
//  `gog`.
//

import Foundation
import Testing
@testable import HeyMate

struct HeyMateGogCLIStatusTests {

    @Test func reportsNotInstalledWhenExecutableAndSupportFilesAreMissing() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let status = inspect(home: home)

        #expect(status.isInstalled == false)
        #expect(status.executablePath == nil)
        #expect(status.credentialsExist == false)
        #expect(status.accountEmail == nil)
        #expect(status.readinessTitle == "gogcli not found by HeyMate")
    }

    @Test func reportsCredentialsWhenDefaultClientJSONExists() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let gog = home.appendingPathComponent("bin/gog")
        try FileManager.default.createDirectory(
            at: gog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: gog.path, contents: Data())

        let support = gogcliSupportDirectory(under: home)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try "{}\n".write(
            to: support.appendingPathComponent("credentials.json"),
            atomically: true,
            encoding: .utf8
        )

        let status = inspect(home: home, knownExecutablePaths: [gog.path])

        #expect(status.isInstalled == true)
        #expect(status.executablePath == gog.path)
        #expect(status.credentialsExist == true)
        #expect(status.client == "default")
        #expect(status.accountEmail == nil)
        #expect(status.readinessTitle == "Authorize an account")
    }

    @Test func parsesAccountEmailFromTokenFilename() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let gog = home.appendingPathComponent("bin/gog")
        try FileManager.default.createDirectory(
            at: gog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: gog.path, contents: Data())

        let support = gogcliSupportDirectory(under: home)
        let keyring = support.appendingPathComponent("keyring", isDirectory: true)
        try FileManager.default.createDirectory(at: keyring, withIntermediateDirectories: true)
        try "{}\n".write(
            to: support.appendingPathComponent("credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        FileManager.default.createFile(
            atPath: keyring.appendingPathComponent("token:user@gmail.com").path,
            contents: Data()
        )

        let status = inspect(home: home, knownExecutablePaths: [gog.path])

        #expect(status.accountEmail == "user@gmail.com")
        #expect(status.isReadyForUserAccount == true)
        #expect(status.readinessTitle == "Connected locally")
        #expect(status.readinessDetail == "Using user@gmail.com via local keyring.")
    }

    // MARK: - Fixtures

    /// Empty known paths so a real `/opt/homebrew/bin/gog` cannot leak in.
    private func inspect(
        home: URL,
        knownExecutablePaths: [String] = [],
        environment: [String: String] = [:]
    ) -> HeyMateGogCLIStatus {
        HeyMateGogCLIStatusResolver.refreshSynchronously(
            fileManager: .default,
            homeDirectory: home,
            environment: environment,
            knownExecutablePaths: knownExecutablePaths
        )
    }

    private func makeTemporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeyMateGogCLIStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func gogcliSupportDirectory(under home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support/gogcli", isDirectory: true)
    }
}
