//
//  MateSettingsAppsPane.swift
//  HeyMate
//
//  Agent settings › Apps & Skills: the integrations this agent may use (its
//  own switches over HeyMate's defaults; for HeyMate itself, the defaults)
//  and the skills door. Integration switches save as they flip.
//

import SwiftUI

struct MateSettingsAppsPane: View {
    let context: MateSettingsContext
    @ObservedObject private var companionManager: CompanionManager
    /// Changes from HeyMate's defaults, applied as soon as one flips.
    @State private var integrationDraft: [String: Bool]

    init(context: MateSettingsContext) {
        self.context = context
        self.companionManager = context.companionManager
        let mate = context.mate
        _integrationDraft = State(initialValue: mate.conductsOthers ? [:] : (mate.connectorOverrides ?? [:]))
    }

    private var mate: Mate { context.mate }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
            SettingsSection {
                AgentIntegrationsSection(
                    isDefaults: mate.conductsOthers,
                    draft: $integrationDraft,
                    companionManager: companionManager
                ) {
                    context.openDesktopSection(.connectors)
                }
                .settingsRowInsets()
            }
            .mateSettingsAnchor("apps.integrations")

            SettingsSection("Skills") {
                SettingsRow("Skills", subtitle: skillsSummary, systemImage: "wand.and.stars")
                SettingsDivider()
                MateSettingsLinkRow(title: "Manage skills", subtitle: "Turn skills on or off, or add new ones.",
                                    systemImage: "slider.horizontal.3") {
                    context.openDesktopSection(.skills)
                }
            }
            .mateSettingsAnchor("apps.skills")
        }
        .onChange(of: integrationDraft) { _, draft in apply(draft) }
    }

    private func apply(_ draft: [String: Bool]) {
        if mate.conductsOthers {
            for (selectionID, enabled) in draft {
                companionManager.setChatConnectorEnabled(enabled, selectionID: selectionID)
            }
        } else if draft != (mate.connectorOverrides ?? [:]) {
            companionManager.setMateConnectorOverrides(id: mate.id, overrides: draft)
        }
    }

    private var skillsSummary: String {
        if let names = mate.enabledSkillNames {
            return names.isEmpty ? "This agent uses no skills." : "This agent uses: \(names.joined(separator: ", "))."
        }
        let activeCount = companionManager.discoveredSkills.filter { companionManager.isSkillActive($0) }.count
        let countText = activeCount == 1 ? "1 skill is on" : "\(activeCount) skills are on"
        return "\(countText). Skills are short instructions every agent can use when they fit the request."
    }
}
