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
            job: "Watch the inbox and point out what needs a reply",
            soul: "Brief and calm. One item at a time.",
            faceAssetName: "MateFaceSignalPointer",
            matchKey: "inbox"
        ),
        AgentSuggestion(
            name: "Screen Guide",
            job: "Walk through the app on screen, one step at a time",
            soul: "Patient teacher. Wait after each step.",
            faceAssetName: "MateFaceInstrumentLens",
            matchKey: "screen"
        ),
        AgentSuggestion(
            name: "Desk Clerk",
            job: "Keep notes, files, and follow-ups in one place",
            soul: "Orderly. Write things down before moving on.",
            faceAssetName: "MateFaceMarginQuill",
            matchKey: "notes"
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
