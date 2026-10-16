//
//  AgentCast.swift
//  HeyMate
//
//  Suggested agents for the rail. A suggestion disappears once an agent
//  already covers that kind of work. Nothing here calls a model.
//

import Foundation

struct AgentSuggestion: Equatable, Identifiable {
    var id: String { matchKey }
    let name: String
    let job: String
    let soul: String
    let faceAssetName: String
    /// A word already present in an agent's job hides this suggestion.
    let matchKey: String
}

enum AgentSuggestionCatalog {
    static let all: [AgentSuggestion] = [
        AgentSuggestion(
            name: "Inbox Scout",
            job: "Review the inbox with enabled mail tools, identify replies, and draft responses for approval. Report missing access; send only when explicitly authorized.",
            soul: "Brief and calm. One item at a time.",
            faceAssetName: MiloLook.defaultLook.assetName,
            matchKey: "inbox"
        ),
        AgentSuggestion(
            name: "Screen Guide",
            job: "Walk through the app on screen, one step at a time",
            soul: "Patient teacher. Wait after each step.",
            faceAssetName: MiloLook.defaultLook(for: .nova).assetName,
            matchKey: "screen"
        ),
        AgentSuggestion(
            name: "Desk Clerk",
            job: "Keep notes, files, and follow-ups in one place",
            soul: "Orderly. Write things down before moving on.",
            faceAssetName: "Milo-crop-copper-umber-amber-future",
            matchKey: "notes"
        ),
        AgentSuggestion(
            name: "Marketing Partner",
            job: "Plan marketing campaigns, research with enabled tools, and prepare evidence-backed copy and assets. Return drafts and blockers to HeyMate; publish only when explicitly authorized.",
            soul: "Clear and practical. State audience, goal, evidence, and next decision.",
            faceAssetName: "Milo-sweep-copper-caramel-amber-future",
            matchKey: "marketing"
        ),
        AgentSuggestion(
            name: "Developer",
            job: "Develop and review code using enabled repository and coding tools. Preserve task constraints, run relevant checks, and return changed files, test evidence, and remaining risks to HeyMate.",
            soul: "Precise and accountable. Verify behavior before claiming completion.",
            faceAssetName: "Milo-crop-tide-umber-sea-future",
            matchKey: "develop"
        ),
        AgentSuggestion(
            name: "LinkedIn Manager",
            job: "Research LinkedIn content, prepare posts and replies with enabled tools, and return drafts and evidence to HeyMate. Report missing access; publish or message only when explicitly authorized.",
            soul: "Professional and direct. Keep claims sourced and voice consistent.",
            faceAssetName: "Milo-sweep-lilac-sand-violet-future",
            matchKey: "linkedin"
        )
    ]

    static func offers(existingJobs: [String]) -> [AgentSuggestion] {
        all.filter { suggestion in
            !existingJobs.contains {
                $0.localizedCaseInsensitiveContains(suggestion.matchKey)
            }
        }
    }
}
