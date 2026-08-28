//
//  AgentFilament.swift
//  leanring-buddy
//

import Foundation

/// Tiny ambient identity for one live agent. Folder slug chooses hue with a
/// stable hash, so a workspace keeps its color across launches.
nonisolated struct AgentFilament: Identifiable, Equatable {
    let id: UUID
    let hue: Double

    static func live(from runs: [AgentRun]) -> [AgentFilament] {
        runs
            .filter { !$0.status.isTerminal }
            .sorted { $0.createdAt < $1.createdAt }
            .map { run in
                AgentFilament(
                    id: run.id,
                    hue: stableHue(forFolderSlug: run.workspaceURL.lastPathComponent)
                )
            }
    }

    static func stableHue(forFolderSlug slug: String) -> Double {
        // FNV-1a is deterministic. Swift Hasher deliberately is not.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in slug.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Double(hash % 360) / 360.0
    }
}
