//
//  MateSettingsBrainPane.swift
//  HeyMate
//
//  Agent settings › Brain: which AI, model and effort this agent uses, and
//  the backup when that AI is at its usage limit. "Same as HeyMate" follows
//  the app's Brain. Saved on the Mate record (brainRawValue, modelID,
//  effortRawValue, backupBrainRawValue) and sent as the per-chat brain on
//  every turn, routine, check-in and continuation (resolvedSessionBrain).
//  Only providers that are signed in, and only their models, are offered.
//

import SwiftUI

struct MateSettingsBrainPane: View {
    let context: MateSettingsContext
    @ObservedObject private var companionManager: CompanionManager
    @ObservedObject private var setup = MateAgentSetupController.shared

    init(context: MateSettingsContext) {
        self.context = context
        self.companionManager = context.companionManager
    }

    private var mate: Mate { context.mate }
    private var appBrain: AgentBrain? { BrainProviderMapping.brain(forProvider: setup.currentProvider) }
    private var explicitBrain: AgentBrain? { mate.brainRawValue.flatMap(AgentBrain.init(rawValue:)) }
    private var effectiveBrain: AgentBrain? { explicitBrain ?? appBrain }
    private var effectiveProvider: MateAgentSetupController.Provider? {
        guard let id = effectiveBrain.flatMap(BrainProviderMapping.provider(for:)) else { return nil }
        return setup.providers.first { $0.id == id && $0.authenticated }
    }

    private var signedInBrains: [AgentBrain] {
        AgentBrain.allCases.filter { brain in
            guard let provider = BrainProviderMapping.provider(for: brain) else { return false }
            return setup.providers.contains { $0.id == provider && $0.authenticated }
        }
    }

    private var appSummary: String {
        let name = setup.currentProviderName.isEmpty ? (appBrain?.displayName ?? "HeyMate's Brain") : setup.currentProviderName
        let model = setup.currentModelName
        return model.isEmpty ? name : "\(name) · \(model)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
            SettingsSection("This agent's brain", footer: footer) {
                SettingsPickerRow(
                    "Brain",
                    subtitle: "Same as HeyMate: \(appSummary)",
                    selection: Binding(
                        get: { explicitBrain?.rawValue ?? "" },
                        set: { raw in companionManager.setMateBrainChoice(id: mate.id, brain: AgentBrain(rawValue: raw)) }
                    ),
                    options: brainOptions
                )
                .mateSettingsAnchor("brain.provider")
                SettingsDivider()
                SettingsPickerRow(
                    "Model",
                    subtitle: modelSubtitle,
                    selection: Binding(
                        get: { mate.modelID ?? "" },
                        set: { companionManager.setMateModel(id: mate.id, model: $0.isEmpty ? nil : $0) }
                    ),
                    options: modelOptions
                )
                .disabled(effectiveProvider == nil)
                .mateSettingsAnchor("brain.model")
                SettingsDivider()
                SettingsPickerRow(
                    "Effort",
                    subtitle: "Deeper thinking is slower and uses more of your plan.",
                    selection: Binding(
                        get: { mate.effortRawValue ?? "" },
                        set: { companionManager.setMateEffort(id: mate.id, effort: $0.isEmpty ? nil : $0) }
                    ),
                    options: effortOptions
                )
                .mateSettingsAnchor("brain.effort")
            }

            SettingsSection("When it hits a usage limit") {
                SettingsPickerRow(
                    "Backup brain",
                    subtitle: "Used while \(effectiveBrain?.displayName ?? "its brain") is at its limit, then it switches back.",
                    selection: Binding(
                        get: { mate.backupBrainRawValue ?? "" },
                        set: { companionManager.setMateBackupBrain(id: mate.id, brain: AgentBrain(rawValue: $0)) }
                    ),
                    options: backupOptions
                )
                .mateSettingsAnchor("brain.backup")
                if let effectiveBrain, let until = companionManager.brainLimitLedger.limitedUntil(effectiveBrain) {
                    SettingsInlineHelp(
                        "\(effectiveBrain.displayName) is at its limit until about \(until.formatted(date: .omitted, time: .shortened)).",
                        tone: .attention
                    )
                    .settingsRowContentInsets()
                }
            }
        }
    }

    private var footer: String {
        if setup.providers.isEmpty {
            return "Sign in under Settings › AI & Accounts to choose a different AI or model for this agent."
        }
        return "Applies to this agent's chats, routines, check-ins and long tasks. Other agents keep their own."
    }

    private var brainOptions: [DSMenuOption<String>] {
        [DSMenuOption(value: "", title: "Same as HeyMate")]
            + signedInBrains.enumerated().map { index, brain in
                DSMenuOption(value: brain.rawValue, title: brain.displayName, startsGroup: index == 0)
            }
            // A saved choice that is no longer signed in still shows as chosen.
            + (explicitBrain.map { brain in signedInBrains.contains(brain) ? [] : [
                DSMenuOption(value: brain.rawValue, title: "\(brain.displayName) (not signed in)", startsGroup: true)
            ] } ?? [])
    }

    private var modelSubtitle: String {
        guard effectiveProvider != nil else { return "Sign in to this agent's AI to pick a model." }
        if mate.modelID == nil { return "Uses the provider's model HeyMate would pick." }
        return "Only models your plan offers are listed."
    }

    private var modelOptions: [DSMenuOption<String>] {
        let provider = effectiveProvider
        var options = [DSMenuOption(value: "", title: "Same as HeyMate")]
        options += (provider?.models ?? []).enumerated().map { index, model in
            DSMenuOption(value: model, title: provider?.modelNames[model] ?? model, startsGroup: index == 0)
        }
        if let saved = mate.modelID, !(provider?.models.contains(saved) ?? false) {
            options.append(DSMenuOption(value: saved, title: "\(saved) (not offered)", startsGroup: true))
        }
        return options
    }

    private var effortOptions: [DSMenuOption<String>] {
        let model = mate.modelID ?? (effectiveProvider?.id == setup.currentProvider ? setup.currentModel : effectiveProvider?.models.first)
        let levels = model.flatMap { effectiveProvider?.efforts[$0] } ?? ["low", "medium", "high"]
        var options = [DSMenuOption(value: "", title: "Same as HeyMate (\(setup.currentEffort.capitalized))")]
        options += levels.filter { $0 != "off" }.enumerated().map { index, level in
            DSMenuOption(value: level, title: level == "xhigh" ? "Extra high" : level.capitalized, startsGroup: index == 0)
        }
        if let saved = mate.effortRawValue, !levels.contains(saved) {
            options.append(DSMenuOption(value: saved, title: "\(saved.capitalized) (not offered)", startsGroup: true))
        }
        return options
    }

    private var backupOptions: [DSMenuOption<String>] {
        let none: String = {
            if !mate.conductsOthers, let appBackup = companionManager.appBackupBrain {
                return "Same as HeyMate (\(appBackup.displayName))"
            }
            return "Nothing, wait for the limit to reset"
        }()
        return [DSMenuOption(value: "", title: none)]
            + signedInBrains.filter { $0 != effectiveBrain }.enumerated().map { index, brain in
                DSMenuOption(value: brain.rawValue, title: brain.displayName, startsGroup: index == 0)
            }
    }
}
