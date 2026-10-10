//
//  SettingsConnectionsPane.swift
//  leanring-buddy
//
//  Settings › Connections: the apps HeyMate can reach, the Composio key that
//  signs it in to web apps, and the local Google tool. The Apps page sends
//  people here for the Composio key.
//

import SwiftUI

struct SettingsConnectionsPane: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject private var composioConnections: ComposioConnectionsRuntime

    @State private var composioStatusMessage: String?
    @State private var composioStatusTone: SettingsStatusTone = .neutral
    @State private var isSavingComposioAPIKey = false

    init(companionManager: CompanionManager, navigation: SettingsNavigationModel) {
        self.companionManager = companionManager
        self.navigation = navigation
        self.composioConnections = companionManager.composioConnections
    }

    var body: some View {
        SettingsPage(tab: .connections, navigation: navigation) {
            SettingsSection {
                SettingsRow(
                    SettingsItem.connectedApps.title,
                    subtitle: "Gmail, Slack, Calendar, and more. HeyMate can read and act in the apps you connect; anything it sends asks you first.",
                    systemImage: "app.connected.to.app.below.fill",
                    item: .connectedApps
                ) {
                    Button("Open Apps") {
                        companionManager.openDesktopWindow(section: .connectors)
                    }
                    .dsCapsuleButtonStyle(.secondary)
                }
            }

            composioSection

            SettingsSection(
                "Google",
                footer: "Agents reach Gmail, Calendar, and Drive through gogcli, a free tool you install on this Mac (brew install gogcli). HeyMate never handles your Google sign-in."
            ) {
                GoogleCLISettingsRow()
            }
        }
    }

    // MARK: Composio

    private var composioSection: some View {
        SettingsSection(
            "Web apps",
            footer: "Stored in a private file only your Mac account can read. HeyMate never receives the tokens for Gmail, Slack, or other connected apps."
        ) {
            SettingsSecretKeyRow(
                title: SettingsItem.composioKey.title,
                subtitle: "Optional. Composio is the service that signs HeyMate in to apps like Gmail and Slack. Its free tier is enough to start.",
                item: .composioKey,
                placeholder: "Composio API key",
                isStored: composioConnections.isConfigured,
                isBusy: isSavingComposioAPIKey,
                removalTitle: "Remove the Composio key?",
                removalMessage: "HeyMate deletes it from this Mac and signs out of Composio here. Apps connected through Composio stop working until you add a key again.",
                onSave: saveComposioAPIKey,
                onRemove: removeComposioAPIKey
            )

            if let composioStatusMessage, !isSavingComposioAPIKey {
                SettingsInlineHelp(composioStatusMessage, tone: composioStatusTone)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsRowContentInsets()
            }
        }
    }

    private func saveComposioAPIKey(_ key: String) {
        guard let composioConnector = ConnectorCatalog.connector(withID: ComposioSessionStore.connectorID) else { return }

        ConnectorSecretStore.setSecret(key, forConnectorID: ComposioSessionStore.connectorID)
        ComposioSessionStore.clear()
        companionManager.connectorStore.setCustomLaunchCommand(nil, for: ComposioSessionStore.connectorID)
        composioStatusMessage = nil
        isSavingComposioAPIKey = true

        Task {
            await companionManager.connectorRuntime.connect(composioConnector)
            let state = companionManager.connectorStore.connectionState(for: ComposioSessionStore.connectorID)
            switch state {
            case .connected:
                composioStatusMessage = "Ready. Supported apps can now connect from Apps."
                composioStatusTone = .positive
                await companionManager.composioToolkitDirectory.loadDefaultPage(
                    apiKey: companionManager.composioConnections.apiKey
                )
            case .needsAttention(let reason):
                composioStatusMessage = reason
                composioStatusTone = .attention
            default:
                composioStatusMessage = "Key saved."
                composioStatusTone = .neutral
            }
            isSavingComposioAPIKey = false
        }
    }

    /// Deletes the stored key and tears down the Tool Router session the
    /// same way disconnecting the Composio connector does. The key is never
    /// read back or logged.
    private func removeComposioAPIKey() {
        composioStatusMessage = nil
        guard let composioConnector = ConnectorCatalog.connector(withID: ComposioSessionStore.connectorID) else {
            ConnectorSecretStore.deleteSecret(forConnectorID: ComposioSessionStore.connectorID)
            ComposioSessionStore.clear()
            companionManager.connectorStore.setCustomLaunchCommand(nil, for: ComposioSessionStore.connectorID)
            composioStatusMessage = "Key removed."
            composioStatusTone = .neutral
            return
        }
        Task {
            await companionManager.connectorRuntime.disconnect(composioConnector)
            composioStatusMessage = "Key removed."
            composioStatusTone = .neutral
        }
    }
}
