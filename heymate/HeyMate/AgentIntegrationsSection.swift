//
//  AgentIntegrationsSection.swift
//  HeyMate
//
//  Integrations live in each agent's settings, not on the chat bar.
//  HeyMate's own settings hold the defaults every agent starts with; another
//  agent inherits them and can switch any one on or off for itself.
//

import SwiftUI

/// Connected integrations as one list of switches, by the names people know.
enum ConnectedIntegrations {
    typealias Item = (id: String, name: String, logoSlug: String)

    @MainActor
    static func items(store: ConnectorStore, composio: ComposioConnectionsRuntime) -> [Item] {
        let catalogItems = store.activeConnectors
            .filter { $0.id != ComposioSessionStore.connectorID }
            .map {
                (
                    id: CompanionManager.chatConnectorSelectionID(forConnectorID: $0.id),
                    name: $0.displayName,
                    logoSlug: $0.id.lowercased()
                )
            }
        let composioItems = composio.connectedSlugs.filter { $0.lowercased() != ComposioSessionStore.connectorID }.map { slug in
            let name = readableName(composio.records[slug]?.displayName ?? slug, slug: slug)
            return (
                id: CompanionManager.chatConnectorSelectionID(forComposioSlug: slug),
                name: name,
                logoSlug: slug
            )
        }
        // Both routes stay separate switches; the label says which is which.
        return IntegrationOverlap.labeled(local: catalogItems, web: composioItems)
    }

    /// Some connections were saved with their slug as the name
    /// ("googlecalendar"). Show those the way people write them.
    static func readableName(_ name: String, slug: String) -> String {
        guard name.caseInsensitiveCompare(slug) == .orderedSame else { return name }
        let known: [String: String] = [
            "github": "GitHub", "gitlab": "GitLab", "gmail": "Gmail",
            "googlecalendar": "Google Calendar", "googledrive": "Google Drive",
            "googledocs": "Google Docs", "googlesheets": "Google Sheets",
            "youtube": "YouTube", "linkedin": "LinkedIn", "hubspot": "HubSpot",
            "clickup": "ClickUp", "whatsapp": "WhatsApp"
        ]
        if let readable = known[slug.lowercased()] { return readable }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Switches edit `draft`, the changes from HeyMate's current defaults,
/// and the settings sheet applies them on Save. For HeyMate itself the draft
/// changes the defaults; for any other agent it becomes that agent's own.
struct AgentIntegrationsSection: View {
    let isDefaults: Bool
    @Binding var draft: [String: Bool]
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var connectorStore: ConnectorStore
    @ObservedObject private var composioConnections: ComposioConnectionsRuntime
    var manage: () -> Void

    init(isDefaults: Bool, draft: Binding<[String: Bool]>, companionManager: CompanionManager, manage: @escaping () -> Void) {
        self.isDefaults = isDefaults
        self._draft = draft
        self.companionManager = companionManager
        self.connectorStore = companionManager.connectorStore
        self.composioConnections = companionManager.composioConnections
        self.manage = manage
    }

    private var items: [ConnectedIntegrations.Item] {
        ConnectedIntegrations.items(store: connectorStore, composio: composioConnections)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Integrations")
                    .font(DS.Fonts.sectionLabel)
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer(minLength: 8)
                if !isDefaults && !draft.isEmpty {
                    Button("Use HeyMate's") { draft = [:] }
                    .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                    .help("Drop this agent's changes and follow HeyMate's integrations")
                }
            }
            Text(summary)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(items, id: \.id) { item in
                        row(item)
                    }
                }
                .dsSurface(.card)
            }
            Button(action: manage) {
                Label(items.isEmpty ? "Connect integrations" : "Manage integrations", systemImage: "puzzlepiece.extension")
                    .font(DS.Fonts.control)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var summary: String {
        if items.isEmpty {
            return "Nothing connected yet. Connect Gmail, Slack, GitHub and more, and your agents can use them."
        }
        if isDefaults {
            return "Every agent starts with these. Any agent can change them in its own settings."
        }
        return draft.isEmpty
            ? "Same as HeyMate's. Flip one to change it for this agent only."
            : "Changes from HeyMate's are marked."
    }

    private func row(_ item: ConnectedIntegrations.Item) -> some View {
        let isCustom = !isDefaults && draft[item.id] != nil
        return Toggle(isOn: Binding(
            get: { isEnabled(item.id) },
            set: { setEnabled(item.id, $0) }
        )) {
            HStack(spacing: 10) {
                ComposioToolkitLogoView(
                    toolkit: .logoOnly(slug: item.logoSlug, name: item.name),
                    compactSize: 22
                )
                Text(item.name)
                    .font(DS.Fonts.bodyLarge)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                if isCustom {
                    Text("This agent only")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        // The logo view hides the name from VoiceOver, which left every
        // switch unlabeled.
        .accessibilityLabel(isCustom ? "\(item.name), this agent only" : item.name)
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func isEnabled(_ id: String) -> Bool {
        draft[id] ?? companionManager.isChatConnectorEnabled(id)
    }

    private func setEnabled(_ id: String, _ enabled: Bool) {
        // Matching the default again means following it again.
        draft[id] = enabled == companionManager.isChatConnectorEnabled(id) ? nil : enabled
    }
}
