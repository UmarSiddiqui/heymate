//
//  SkillRegistry.swift
//  leanring-buddy
//
//  Read-only browser for Anthropic's public Agent Skills repository plus a
//  small, app-managed installation store. Remote instructions never become
//  active until the user reviews, installs, then explicitly activates them.
//

import Combine
import Foundation

nonisolated struct RemoteSkillDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let tools: [String]
    let instructions: String
    let markdown: String
    let author: String
    let repositoryURL: URL
    let sourceURL: URL
    let version: String
    let registryIdentifier: String

    var shortVersion: String { String(version.prefix(8)) }
}

nonisolated protocol SkillRegistryTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

nonisolated struct URLSessionSkillRegistryTransport: SkillRegistryTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

nonisolated enum AnthropicSkillRegistryError: LocalizedError {
    case invalidResponse
    case requestFailed(Int)
    case truncatedTree

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Anthropic registry returned an unreadable response."
        case .requestFailed(let status): return "Anthropic registry request failed (HTTP \(status))."
        case .truncatedTree: return "Anthropic registry listing was incomplete. Try again later."
        }
    }
}

@MainActor
final class AnthropicSkillRegistry: ObservableObject {
    static let registryIdentifier = "anthropics/skills"
    static let repositoryURL = URL(string: "https://github.com/anthropics/skills")!
    private static let treeURL = URL(
        string: "https://api.github.com/repos/anthropics/skills/git/trees/main?recursive=1"
    )!

    @Published private(set) var skills: [RemoteSkillDescriptor] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let transport: any SkillRegistryTransport

    init(transport: any SkillRegistryTransport = URLSessionSkillRegistryTransport()) {
        self.transport = transport
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let treeData = try await fetch(Self.treeURL)
            let entries = try Self.skillEntries(fromTreeData: treeData)
            var loadedSkills: [RemoteSkillDescriptor] = []

            for entry in entries {
                guard let rawURL = URL(
                    string: "https://raw.githubusercontent.com/anthropics/skills/main/\(entry.path)"
                ) else { continue }
                guard let markdownData = try? await fetch(rawURL),
                      let markdown = String(data: markdownData, encoding: .utf8),
                      let skill = SkillMarkdownParser.parse(markdown)
                else { continue }

                let folderName = entry.path.split(separator: "/").dropLast().last.map(String.init)
                    ?? skill.name
                loadedSkills.append(RemoteSkillDescriptor(
                    id: folderName,
                    name: skill.name,
                    description: skill.trigger,
                    tools: skill.tools,
                    instructions: skill.instructions,
                    markdown: markdown,
                    author: "Anthropic",
                    repositoryURL: Self.repositoryURL,
                    sourceURL: URL(
                        string: "https://github.com/anthropics/skills/blob/main/\(entry.path)"
                    )!,
                    version: entry.sha,
                    registryIdentifier: Self.registryIdentifier
                ))
            }

            skills = loadedSkills.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HeyMate-Skills/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicSkillRegistryError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AnthropicSkillRegistryError.requestFailed(httpResponse.statusCode)
        }
        return data
    }

    nonisolated static func skillEntries(fromTreeData data: Data) throws -> [GitTreeEntry] {
        let response = try JSONDecoder().decode(GitTreeResponse.self, from: data)
        guard !response.truncated else { throw AnthropicSkillRegistryError.truncatedTree }
        return response.tree.filter { entry in
            let components = entry.path.split(separator: "/")
            return entry.type == "blob"
                && components.count == 3
                && components.first == "skills"
                && components.last == "SKILL.md"
        }
    }

    nonisolated struct GitTreeEntry: Codable, Equatable, Sendable {
        let path: String
        let type: String
        let sha: String
    }

    private nonisolated struct GitTreeResponse: Decodable {
        let tree: [GitTreeEntry]
        let truncated: Bool
    }
}

@MainActor
final class SkillRegistryInstallationStore {
    private struct Manifest: Codable { var skills: [RemoteSkillDescriptor] }

    private let rootDirectoryURL: URL
    private let fileManager: FileManager

    init(
        rootDirectoryURL: URL = SkillRegistryInstallationStore.defaultDirectory(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.fileManager = fileManager
    }

    func installedDescriptors() -> [RemoteSkillDescriptor] {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return [] }
        return manifest.skills
    }

    func installedDescriptor(id: String) -> RemoteSkillDescriptor? {
        installedDescriptors().first { $0.id == id }
    }

    func install(_ descriptor: RemoteSkillDescriptor) throws {
        guard isSafePathComponent(descriptor.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let directoryURL = skillDirectoryURL(for: descriptor)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try descriptor.markdown.write(
            to: directoryURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        var installed = installedDescriptors().filter { $0.id != descriptor.id }
        installed.append(descriptor)
        try persist(installed)
    }

    func remove(id: String) throws {
        guard isSafePathComponent(id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let directoryURL = rootDirectoryURL.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        try persist(installedDescriptors().filter { $0.id != id })
    }

    func discoveredSkills() -> [DiscoveredSkill] {
        installedDescriptors().compactMap { descriptor in
            let fileURL = skillDirectoryURL(for: descriptor).appendingPathComponent("SKILL.md")
            guard fileManager.fileExists(atPath: fileURL.path),
                  let markdown = try? String(contentsOf: fileURL, encoding: .utf8),
                  let skill = SkillMarkdownParser.parse(markdown)
            else { return nil }
            return DiscoveredSkill(
                skill: skill,
                origin: .remoteRegistry(registryIdentifier: descriptor.registryIdentifier),
                fileURL: fileURL,
                remoteMetadata: descriptor
            )
        }
    }

    private var manifestURL: URL { rootDirectoryURL.appendingPathComponent("manifest.json") }

    private func skillDirectoryURL(for descriptor: RemoteSkillDescriptor) -> URL {
        rootDirectoryURL.appendingPathComponent(descriptor.id, isDirectory: true)
    }

    private func persist(_ skills: [RemoteSkillDescriptor]) throws {
        try fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Manifest(skills: skills.sorted { $0.id < $1.id }))
        try data.write(to: manifestURL, options: .atomic)
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }

    nonisolated static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupportURL
            .appendingPathComponent("heymate", isDirectory: true)
            .appendingPathComponent("installed-skills", isDirectory: true)
            .appendingPathComponent("anthropic", isDirectory: true)
    }
}
