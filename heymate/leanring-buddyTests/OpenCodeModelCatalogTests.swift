//
//  OpenCodeModelCatalogTests.swift
//  leanring-buddyTests
//
//  The notch picker was clipping OpenCode's full catalog into a tiny list
//  that looked empty. Grouping and search have to keep every model.
//

import Foundation
import Testing
@testable import HeyMate

struct OpenCodeModelCatalogTests {

    private let catalog: [OpenCodeModelOption] = [
        .init(providerID: "glm", providerName: "Local", modelID: "zai-org/glm-4.7-flash", modelName: "zai-org/glm-4.7-flash"),
        .init(providerID: "kimi-for-coding", providerName: "Kimi For Coding", modelID: "k3", modelName: "Kimi K3"),
        .init(providerID: "kimi-for-coding", providerName: "Kimi For Coding", modelID: "kimi-for-coding", modelName: "Kimi K2.7 Code"),
        .init(providerID: "moonshotai", providerName: "Moonshot AI", modelID: "kimi-k3", modelName: "Kimi K3"),
        .init(providerID: "moonshotai", providerName: "Moonshot AI", modelID: "kimi-k2.5", modelName: "Kimi K2.5"),
        .init(providerID: "opencode", providerName: "OpenCode Zen", modelID: "big-pickle", modelName: "Big Pickle"),
        .init(providerID: "opencode", providerName: "OpenCode Zen", modelID: "mimo-v2.5-free", modelName: "MiMo V2.5 Free")
    ]

    @Test func groupsEveryModelByProviderNameNotJustTheFirstFew() {
        let groups = OpenCodeModelCatalog.grouped(catalog)
        #expect(groups.map(\.providerID) == ["glm", "kimi-for-coding", "moonshotai", "opencode"])
        #expect(groups.map(\.providerName) == ["Local", "Kimi For Coding", "Moonshot AI", "OpenCode Zen"])
        #expect(groups.map(\.models.count) == [1, 2, 2, 2])
        #expect(groups.flatMap(\.models).count == catalog.count)
    }

    @Test func searchFindsModelsAcrossProviders() {
        let groups = OpenCodeModelCatalog.grouped(catalog, matching: "kimi")
        #expect(groups.map(\.providerID) == ["kimi-for-coding", "moonshotai"])
        #expect(groups.flatMap(\.models).map(\.modelID).sorted() == [
            "k3",
            "kimi-for-coding",
            "kimi-k2.5",
            "kimi-k3"
        ])
    }

    @Test func blankSearchKeepsTheFullCatalog() {
        let groups = OpenCodeModelCatalog.grouped(catalog, matching: "  ")
        #expect(groups.flatMap(\.models).count == catalog.count)
    }

    @Test func searchCanMatchAProviderDisplayName() {
        let groups = OpenCodeModelCatalog.grouped(catalog, matching: "zen")
        #expect(groups.map(\.providerID) == ["opencode"])
        #expect(groups.flatMap(\.models).map(\.modelID) == ["big-pickle", "mimo-v2.5-free"])
    }
}

struct OpenCodeTransportSecurityTests {

    @Test func loopbackHTTPAndRemoteHTTPSAreAllowed() {
        #expect(OpenCodeClient.isAllowedServerURL(URL(string: "http://127.0.0.1:4096")!))
        #expect(OpenCodeClient.isAllowedServerURL(URL(string: "http://localhost:4096")!))
        #expect(OpenCodeClient.isAllowedServerURL(URL(string: "http://[::1]:4096")!))
        #expect(OpenCodeClient.isAllowedServerURL(URL(string: "https://opencode.example.com")!))
    }

    @Test func remotePlainHTTPAndUnknownSchemesAreRejected() {
        #expect(OpenCodeClient.isAllowedServerURL(URL(string: "http://192.168.1.12:4096")!) == false)
        #expect(OpenCodeClient.isAllowedServerURL(URL(string: "http://127.example.com:4096")!) == false)
        #expect(OpenCodeClient.isAllowedServerURL(URL(string: "ftp://opencode.example.com")!) == false)
    }

    @Test func basicAuthHeaderIsNeverAddedToRemotePlainHTTP() {
        var request = URLRequest(url: URL(string: "http://192.168.1.12:4096/global/health")!)
        OpenCodeClient.applyBasicAuth(to: &request, username: "user", password: "secret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func redirectsCannotDowngradeOrLeaveTheApprovedOrigin() {
        #expect(OpenCodeRedirectPolicy.isAllowedRedirect(
            from: URL(string: "https://opencode.example.com/session")!,
            to: URL(string: "http://opencode.example.com/session")!
        ) == false)
        #expect(OpenCodeRedirectPolicy.isAllowedRedirect(
            from: URL(string: "http://127.0.0.1:4096/session")!,
            to: URL(string: "http://192.168.1.12:4096/session")!
        ) == false)
        #expect(OpenCodeRedirectPolicy.isAllowedRedirect(
            from: URL(string: "https://opencode.example.com/session")!,
            to: URL(string: "https://collector.example.net/session")!
        ) == false)
        #expect(OpenCodeRedirectPolicy.isAllowedRedirect(
            from: URL(string: "https://opencode.example.com/session")!,
            to: URL(string: "https://opencode.example.com/next")!
        ))
    }
}
