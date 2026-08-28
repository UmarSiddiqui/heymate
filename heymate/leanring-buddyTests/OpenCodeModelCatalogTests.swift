//
//  OpenCodeModelCatalogTests.swift
//  leanring-buddyTests
//
//  The notch picker was clipping OpenCode's full catalog into a tiny list
//  that looked empty. Grouping and search have to keep every model.
//

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
