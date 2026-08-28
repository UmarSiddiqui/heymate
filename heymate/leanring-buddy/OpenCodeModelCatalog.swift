//
//  OpenCodeModelCatalog.swift
//  leanring-buddy
//
//  The model list an `opencode serve` server exposes, and the grouping the
//  pickers render. Split out of the old AIEngine.swift when the engine choice
//  became AgentBrain.
//

import Foundation

/// One selectable model exposed by an opencode server (from GET /config/providers).
/// A full identity is provider + model because opencode can expose models from
/// multiple providers at once (e.g. anthropic/claude-sonnet-4-6 AND openai/gpt-5.2).
struct OpenCodeModelOption: Identifiable, Hashable {
    let providerID: String
    /// Display name for the provider (`Local`, `Moonshot AI`), not the id.
    let providerName: String
    let modelID: String
    /// Human-readable model name as reported by the server; falls back to modelID.
    let modelName: String

    var id: String { "\(providerID)/\(modelID)" }

    /// Compact label for pickers — model name only, since the surrounding UI
    /// already groups or labels by provider.
    var shortLabel: String { modelName.isEmpty ? modelID : modelName }

    func matches(search needle: String) -> Bool {
        [providerID, providerName, modelID, modelName, shortLabel].contains {
            $0.localizedCaseInsensitiveContains(needle)
        }
    }
}

/// Groups and filters the OpenCode catalog for the notch picker.
enum OpenCodeModelCatalog {
    struct ProviderGroup: Equatable {
        let providerID: String
        let providerName: String
        let models: [OpenCodeModelOption]
    }

    static func grouped(_ models: [OpenCodeModelOption]) -> [ProviderGroup] {
        Dictionary(grouping: models, by: \.providerID)
            .map { providerID, modelsInProvider in
                ProviderGroup(
                    providerID: providerID,
                    providerName: modelsInProvider.first?.providerName ?? providerID,
                    models: modelsInProvider
                )
            }
            .sorted { $0.providerID.localizedStandardCompare($1.providerID) == .orderedAscending }
    }

    static func grouped(
        _ models: [OpenCodeModelOption],
        matching query: String
    ) -> [ProviderGroup] {
        grouped(filtered(models, matching: query))
    }

    static func filtered(
        _ models: [OpenCodeModelOption],
        matching query: String
    ) -> [OpenCodeModelOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return models }
        return models.filter { $0.matches(search: needle) }
    }
}
