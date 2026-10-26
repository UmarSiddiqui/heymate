import Foundation

/// Only providers backed by a real reader are registered here. A provider's
/// presence here does not enable it, sign in, start a runtime or install hooks.
nonisolated struct NotchProviderCapability: Identifiable {
    let id: String
    let name: String
    let glyph: String
    let detail: String
    let activity: Bool

    nonisolated static let additional: [Self] = [
        .init(id: "antigravity", name: "Antigravity", glyph: "antigravity", detail: "Quota from running Antigravity IDE/CLI; otherwise local request counts. Recent transcript activity.", activity: true),
        .init(id: "gemini", name: "Gemini", glyph: "gemini", detail: "Local Gemini CLI, OpenCode and Hermes token counts. Derived totals; no quota percentage. Recent Gemini CLI activity.", activity: true),
        .init(id: "opencode", name: "OpenCode Go", glyph: "opencode", detail: "Go plan quota from OpenCode's local API key or OAuth sign-in. Other OpenCode providers keep their own meters.", activity: false),
        .init(id: "copilot", name: "GitHub Copilot", glyph: "copilot", detail: "Metered quotas using GH_TOKEN/GITHUB_TOKEN or GitHub CLI hosts.yml. No interactive credential commands.", activity: false),
        .init(id: "kimi", name: "Kimi Code", glyph: "kimi", detail: "Kimi CLI sign-in, rolling/weekly quotas and live wire states, including approval waits.", activity: true),
        .init(id: "grok", name: "Grok", glyph: "grok", detail: "Grok CLI's xAI-issued session and weekly billing quota. Expired sessions renew in Grok.", activity: false),
        .init(id: "glm", name: "GLM", glyph: "glm", detail: "Z.ai/BigModel Coding Plan quota using the matching key from Claude Code, ZCode or OpenCode.", activity: false),
        .init(id: "ollama", name: "Ollama", glyph: "ollama", detail: "Loaded models, memory and context limits from localhost:11434. No inferred token quota or activity.", activity: false),
        .init(id: "lmstudio", name: "LM Studio", glyph: "generic", detail: "Loaded model instances and model/context sizes from localhost:1234. No inferred token quota or activity.", activity: false)
    ]
    static func find(_ id: String) -> Self? { additional.first { $0.id == id } }
}

extension NotchUsageProvider {
    nonisolated static let antigravity = Self(rawValue: "antigravity")
    nonisolated static let gemini = Self(rawValue: "gemini")
    nonisolated static let opencode = Self(rawValue: "opencode")
    nonisolated static let copilot = Self(rawValue: "copilot")
    nonisolated static let kimi = Self(rawValue: "kimi")
    nonisolated static let grok = Self(rawValue: "grok")
    nonisolated static let glm = Self(rawValue: "glm")
    nonisolated static let ollama = Self(rawValue: "ollama")
    nonisolated static let lmstudio = Self(rawValue: "lmstudio")
    nonisolated var capability: NotchProviderCapability? { NotchProviderCapability.find(rawValue) }
    nonisolated var connectionDetail: String { capability?.detail ?? (isBuiltIn ? "Usage ring and reset times" : spec?.url ?? "Custom JSON source") }
}

nonisolated enum NotchRingOrder: String, CaseIterable {
    case manual, remaining
    var title: String { self == .manual ? "My order" : "Most remaining first" }
}
