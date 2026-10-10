//
//  ConnectorSecretStoreTests.swift
//  HeyMateTests
//
//  Connector keys live in a private file, not the Keychain, so self-signed
//  updates stop asking for the login password.
//

import Foundation
import Testing
@testable import HeyMate

@Suite(.serialized)
struct ConnectorSecretStoreTests {

    /// Points the store at a fresh folder and keeps it off the real Keychain.
    private func useScratchFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-secrets-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("secrets", isDirectory: true)
        ConnectorSecretStore.fileURL = directory.appendingPathComponent("connector-secrets.json")
        ConnectorSecretStore.migratesFromKeychain = false
        ConnectorSecretStore.resetCacheForTesting()
        return ConnectorSecretStore.fileURL
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func savedKeyIsReadBackAndOwnerOnly() throws {
        let url = try useScratchFile()
        #expect(ConnectorSecretStore.setSecret("sk-test-123", forConnectorID: "composio"))
        ConnectorSecretStore.resetCacheForTesting()
        #expect(ConnectorSecretStore.secret(forConnectorID: "composio") == "sk-test-123")
        #expect(ConnectorSecretStore.hasSecret(forConnectorID: "composio"))
        #expect(try permissions(url) == 0o600)
        #expect(try permissions(url.deletingLastPathComponent()) == 0o700)
    }

    @Test func keysAreKeptApartAndDeletedOneByOne() throws {
        _ = try useScratchFile()
        ConnectorSecretStore.setSecret("a", forConnectorID: "one")
        ConnectorSecretStore.setSecret("b", forConnectorID: "two")
        #expect(ConnectorSecretStore.deleteSecret(forConnectorID: "one"))
        ConnectorSecretStore.resetCacheForTesting()
        #expect(ConnectorSecretStore.secret(forConnectorID: "one") == nil)
        #expect(!ConnectorSecretStore.hasSecret(forConnectorID: "one"))
        #expect(ConnectorSecretStore.secret(forConnectorID: "two") == "b")
    }

    @Test func replacingAKeyOverwritesIt() throws {
        let url = try useScratchFile()
        ConnectorSecretStore.setSecret("old", forConnectorID: "custom")
        ConnectorSecretStore.setSecret("new", forConnectorID: "custom")
        ConnectorSecretStore.resetCacheForTesting()
        #expect(ConnectorSecretStore.secret(forConnectorID: "custom") == "new")
        #expect(try permissions(url) == 0o600)
    }

    @Test func missingFileMeansNoKeys() throws {
        _ = try useScratchFile()
        #expect(ConnectorSecretStore.secret(forConnectorID: "nothing") == nil)
        #expect(!ConnectorSecretStore.hasSecret(forConnectorID: "nothing"))
    }

    @Test func aLooseDirectoryIsTightened() throws {
        let url = try useScratchFile()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        ConnectorSecretStore.setSecret("x", forConnectorID: "k")
        #expect(try permissions(directory) == 0o700)
    }
}
