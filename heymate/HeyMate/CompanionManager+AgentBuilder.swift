//
//  CompanionManager+AgentBuilder.swift
//  HeyMate
//
//  Drafting, creating and editing an agent's character: who it is, the
//  habits it keeps, and what it must ask before doing. The habits live in
//  the agent's AGENTS.md, so Claude Code and Codex read the same thing Talk
//  does.
//

import Foundation

extension CompanionManager {
    /// Past this, the builder falls back to the local draft.
    nonisolated static let agentDraftTimeout: Duration = .seconds(25)

    /// Apps every agent can use right now, by the names people know.
    var connectedIntegrationNames: [String] {
        let native = connectorStore.activeConnectors
            .filter { $0.id != ComposioSessionStore.connectorID }
            .map(\.displayName)
        let web = composioConnections.connectedSlugs
            .filter { $0.lowercased() != ComposioSessionStore.connectorID }
            .map { slug in
                DesktopConnectorScopeMenu.readableName(
                    composioConnections.records[slug]?.displayName ?? slug, slug: slug
                )
            }
        return (native + web).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Drafts an agent from the person's description with the selected AI.
    /// `usedModel` is false when the local fallback had to stand in.
    func draftAgent(description: String) async -> (draft: AgentDraft, usedModel: Bool) {
        let names = mates.map(\.name)
        let fallback = AgentDrafter.localDraft(description: description, existingNames: names)
        guard let client = agentDraftingClient() else { return (fallback, false) }
        let userPrompt = AgentDrafter.userPrompt(
            description: description,
            connectedIntegrations: connectedIntegrationNames,
            existingNames: names
        )
        let reply: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in
                try? await client.analyzeImageStreaming(
                    images: [],
                    systemPrompt: AgentDrafter.systemPrompt,
                    conversationHistory: [],
                    userPrompt: userPrompt,
                    onTextChunk: { _ in }
                ).text
            }
            group.addTask {
                try? await Task.sleep(for: Self.agentDraftTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let reply, let draft = AgentDrafter.parse(reply, existingNames: names) else {
            return (fallback, false)
        }
        return (draft, true)
    }

    /// Creates the agent, writes its habits to AGENTS.md, and opens its chat
    /// with the first task offered (never sent).
    @discardableResult
    func createAgent(from draft: AgentDraft, faceAssetName: String?) -> Mate? {
        let draft = AgentDrafter.sanitized(draft, existingNames: mates.map(\.name))
        let task = draft.firstTask.trimmingCharacters(in: .whitespacesAndNewlines)
        let starter = task.isEmpty ? nil : MateStarterSuggestion(label: "Try the first task", prompt: task)
        guard let mate = createMate(
            name: draft.name,
            job: draft.role,
            soul: draft.personality,
            opensChat: true,
            faceAssetName: faceAssetName,
            starter: starter
        ) else { return nil }
        saveAgentHabits(id: mate.id, howItWorks: draft.howItWorks, asksFirst: draft.asksFirst)
        return mates.first { $0.id == mate.id } ?? mate
    }

    /// The habits as the edit sheet shows them.
    func agentHabits(for mate: Mate) -> (howItWorks: [String], asksFirst: [String]) {
        AgentDrafter.split(standing: MateWorkspaceMemory.standingLines(for: mate))
    }

    func saveAgentHabits(id: UUID, howItWorks: [String], asksFirst: [String]) {
        ensureMateFolder(id: id)
        guard let mate = mates.first(where: { $0.id == id }), let path = mate.folderPath else { return }
        let draft = AgentDraft(
            name: mate.name, role: mate.job, personality: mate.soul,
            howItWorks: howItWorks, asksFirst: asksFirst, firstTask: "", integrations: []
        )
        let cleaned = AgentDrafter.sanitized(draft, existingNames: [])
        MateWorkspaceMemory.replaceStanding(
            AgentDrafter.standingLines(for: cleaned),
            for: mate,
            in: URL(fileURLWithPath: path, isDirectory: true)
        )
    }
}
