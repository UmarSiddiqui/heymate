//
//  SkillRegistryTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct SkillRegistryTests {
    @Test func officialTreeParserKeepsOnlyDirectSkillFiles() throws {
        let data = Data(
            """
            {"truncated":false,"tree":[
              {"path":"skills/pdf/SKILL.md","type":"blob","sha":"pdf-sha"},
              {"path":"skills/pdf/references/forms.md","type":"blob","sha":"reference-sha"},
              {"path":"template/SKILL.md","type":"blob","sha":"template-sha"},
              {"path":"skills/xlsx","type":"tree","sha":"tree-sha"}
            ]}
            """.utf8
        )

        let entries = try AnthropicSkillRegistry.skillEntries(fromTreeData: data)
        #expect(entries == [
            .init(path: "skills/pdf/SKILL.md", type: "blob", sha: "pdf-sha")
        ])
    }

    @Test func injectedTransportLoadsOfficialMetadataAndInstructions() async {
        let treeURL = "https://api.github.com/repos/anthropics/skills/git/trees/main?recursive=1"
        let rawURL = "https://raw.githubusercontent.com/anthropics/skills/main/skills/pdf/SKILL.md"
        let transport = FixtureSkillRegistryTransport(fixtures: [
            treeURL: Data(
                """
                {"truncated":false,"tree":[
                  {"path":"skills/pdf/SKILL.md","type":"blob","sha":"1234567890abcdef"}
                ]}
                """.utf8
            ),
            rawURL: Data(
                """
                ---
                name: pdf
                description: Read and inspect PDF files
                allowed-tools: Read, Bash
                ---

                Inspect rendered pages before reporting.
                """.utf8
            )
        ])
        let registry = AnthropicSkillRegistry(transport: transport)

        await registry.refresh()

        #expect(registry.errorMessage == nil)
        #expect(registry.skills.count == 1)
        #expect(registry.skills.first?.name == "pdf")
        #expect(registry.skills.first?.tools == ["Read", "Bash"])
        #expect(registry.skills.first?.version == "1234567890abcdef")
        #expect(registry.skills.first?.author == "Anthropic")
    }

    @Test func installationStorePersistsUpdatesAndRemovesManagedCopy() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillRegistryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = SkillRegistryInstallationStore(rootDirectoryURL: rootURL)
        let initial = descriptor(version: "version-one", instructions: "First instructions")
        let updated = descriptor(version: "version-two", instructions: "Updated instructions")

        try store.install(initial)
        #expect(store.installedDescriptor(id: "pdf")?.version == "version-one")
        #expect(store.discoveredSkills().first?.skill.instructions == "First instructions")
        #expect(store.discoveredSkills().first?.trustTier == .remoteVerified)

        try store.install(updated)
        #expect(store.installedDescriptor(id: "pdf")?.version == "version-two")
        #expect(store.discoveredSkills().first?.skill.instructions == "Updated instructions")

        try store.remove(id: "pdf")
        #expect(store.installedDescriptors().isEmpty)
        #expect(store.discoveredSkills().isEmpty)
    }

    private func descriptor(version: String, instructions: String) -> RemoteSkillDescriptor {
        let markdown = """
        ---
        name: pdf
        description: Work with PDF files
        ---

        \(instructions)
        """
        return RemoteSkillDescriptor(
            id: "pdf",
            name: "pdf",
            description: "Work with PDF files",
            tools: [],
            instructions: instructions,
            markdown: markdown,
            author: "Anthropic",
            repositoryURL: URL(string: "https://github.com/anthropics/skills")!,
            sourceURL: URL(string: "https://github.com/anthropics/skills/blob/main/skills/pdf/SKILL.md")!,
            version: version,
            registryIdentifier: AnthropicSkillRegistry.registryIdentifier
        )
    }
}

private struct FixtureSkillRegistryTransport: SkillRegistryTransport {
    let fixtures: [String: Data]

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let data = fixtures[url.absoluteString] else {
            throw URLError(.resourceUnavailable)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}
