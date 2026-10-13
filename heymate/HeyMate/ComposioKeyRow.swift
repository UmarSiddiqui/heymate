//
//  ComposioKeyRow.swift
//  HeyMate
//
//  The Composio key, entered and removed on the Integrations page itself.
//  Composio is the service that signs HeyMate in to web apps like Gmail
//  and Slack; the key never leaves this Mac.
//

import SwiftUI

struct ComposioKeyRow: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var composioConnections: ComposioConnectionsRuntime

    @State private var composioStatusMessage: String?
    @State private var composioStatusTone: SettingsStatusTone = .neutral
    @State private var isSavingComposioAPIKey = false

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.composioConnections = companionManager.composioConnections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSecretKeyRow(
                title: "Composio API key",
                subtitle: "Composio signs HeyMate in to apps like Gmail and Slack. Its free tier is enough to start. Stored in a private file only your Mac account can read.",
                item: nil,
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
                composioStatusMessage = "Ready. Web apps below can now connect."
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
