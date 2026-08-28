//
//  HeyMateSecretsTests.swift
//  leanring-buddyTests
//
//  Parser and overlay tests for the local secrets file. Fixtures are injected
//  via `lookup(_:fileContents:processEnvironment:)` and temp-dir `fileURLs`
//  so these never read the user's real `~/.config/heymate/secrets.env`.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct HeyMateSecretsTests {

    private static let sampleFileContents = """
    # comment that must be ignored
    ANTHROPIC_API_KEY=from-file

    export OPENAI_API_KEY=exported-key
    ASSEMBLYAI_API_KEY="double-quoted"
    ELEVENLABS_API_KEY='single-quoted'
    ELEVENLABS_VOICE_ID=$(PLACEHOLDER)
    GOG_KEYRING_PASSWORD=
    """

    @Test func commentsAreSkipped() {
        let value = HeyMateSecrets.lookup(
            "ANTHROPIC_API_KEY",
            fileContents: Self.sampleFileContents,
            processEnvironment: [:]
        )
        #expect(value == "from-file")
    }

    @Test func exportPrefixIsAllowed() {
        let value = HeyMateSecrets.lookup(
            "OPENAI_API_KEY",
            fileContents: Self.sampleFileContents,
            processEnvironment: [:]
        )
        #expect(value == "exported-key")
    }

    @Test func matchingQuotesAreStripped() {
        let doubleQuoted = HeyMateSecrets.lookup(
            "ASSEMBLYAI_API_KEY",
            fileContents: Self.sampleFileContents,
            processEnvironment: [:]
        )
        #expect(doubleQuoted == "double-quoted")

        let singleQuoted = HeyMateSecrets.lookup(
            "ELEVENLABS_API_KEY",
            fileContents: Self.sampleFileContents,
            processEnvironment: [:]
        )
        #expect(singleQuoted == "single-quoted")
    }

    @Test func processEnvironmentBeatsFile() {
        let value = HeyMateSecrets.lookup(
            "ANTHROPIC_API_KEY",
            fileContents: Self.sampleFileContents,
            processEnvironment: ["ANTHROPIC_API_KEY": "from-env"]
        )
        #expect(value == "from-env")
    }

    @Test func missingFileReturnsNil() {
        let missingFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-secrets-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("secrets.env", isDirectory: false)

        let value = HeyMateSecrets.lookup(
            "ANTHROPIC_API_KEY",
            fileURLs: [missingFileURL],
            processEnvironment: [:]
        )
        #expect(value == nil)
    }

    @Test func placeholderValuesAreIgnored() {
        let value = HeyMateSecrets.lookup(
            "ELEVENLABS_VOICE_ID",
            fileContents: Self.sampleFileContents,
            processEnvironment: [:]
        )
        #expect(value == nil)
    }

    @Test func overlayDoesNotOverwriteExistingProcessEnvironmentKey() {
        let merged = HeyMateSecrets.mergedProcessEnvironment(
            processEnvironment: [
                "ANTHROPIC_API_KEY": "keep-me",
                "PATH": "/usr/bin"
            ],
            fileContents: Self.sampleFileContents
        )
        #expect(merged["ANTHROPIC_API_KEY"] == "keep-me")
        #expect(merged["OPENAI_API_KEY"] == "exported-key")
        #expect(merged["PATH"] == "/usr/bin")
        #expect(merged["ELEVENLABS_VOICE_ID"] == nil)
    }

    @Test func secretsFileEnvironmentOverrideIsFirstURL() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-secrets-home-\(UUID().uuidString)", isDirectory: true)
        let overridePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-secrets-override-\(UUID().uuidString).env")
            .path

        let urls = HeyMateSecrets.secretsFileURLs(
            processEnvironment: [HeyMateSecrets.secretsFileEnvironmentKey: overridePath],
            homeDirectoryURL: home
        )

        #expect(urls.count == 2)
        #expect(urls[0].path == overridePath)
        #expect(urls[1].path.hasSuffix("/.config/heymate/secrets.env"))
    }

    @Test func lookupReadsInjectedTempFileAndSkipsRealConfig() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-secrets-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("secrets.env")
        try "HEYMATE_BRIDGE_TOKEN=temp-token\n".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let value = HeyMateSecrets.lookup(
            "HEYMATE_BRIDGE_TOKEN",
            fileURLs: [fileURL],
            processEnvironment: [:]
        )
        #expect(value == "temp-token")
    }
}
