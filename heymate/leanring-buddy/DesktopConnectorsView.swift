//
//  DesktopConnectorsView.swift
//  leanring-buddy
//
//  The connector catalog: everything HeyMate can reach, what it would be
//  allowed to do, and one control to turn it on.
//
//  The design rule here is that a person should be able to answer "what
//  can this thing touch, and what can it do without asking me?" without
//  opening documentation. So every card states its transport, its highest
//  risk level, and its approval policy on the face of the card — not
//  behind a disclosure triangle.
//

import AppKit
import SwiftUI

struct DesktopConnectorsView: View {
    @ObservedObject var store: ConnectorStore
    @ObservedObject var runtime: ConnectorRuntime
    @ObservedObject var composioConnections: ComposioConnectionsRuntime
    @ObservedObject var composioToolkitDirectory: ComposioToolkitDirectory

    @State private var searchText = ""
    @State private var connectorAwaitingKeyEntry: Connector?
    @State private var connectorAwaitingCommandEntry: Connector?
    @State private var apiKeyDraft = ""
    @State private var launchCommandDraft = ""
    @State private var selectedComposioCategory = "All"
    @State private var areMCPPresetsExpanded = false
    @State private var isShowingAPIContractHelp = false
    @State private var disconnectPrompt: DisconnectPrompt?
    @State private var commandRemovalPrompt: Connector?

    var body: some View {
        DesktopPage(
            title: "Apps",
            subtitle: connectedSummary,
            accessory: AnyView(searchField)
        ) {
            if composioConnections.isConfigured {
                composioSection
                localSection
            } else {
                // Without a Composio key, lead with what works right now:
                // the Mac's own apps. The key is an optional extra.
                localSection
                composioSetupCard
            }
            customSection
        }
        .sheet(item: $connectorAwaitingKeyEntry) { connector in
            apiKeySheet(for: connector)
        }
        .sheet(item: $connectorAwaitingCommandEntry) { connector in
            launchCommandSheet(for: connector)
        }
        .sheet(isPresented: $isShowingAPIContractHelp) {
            apiContractHelpSheet
        }
        .confirmationDialog(
            disconnectPrompt.map { "Disconnect \($0.name)?" } ?? "Disconnect?",
            isPresented: Binding(
                get: { disconnectPrompt != nil },
                set: { isPresented in
                    if !isPresented { disconnectPrompt = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                let prompt = disconnectPrompt
                disconnectPrompt = nil
                switch prompt?.kind {
                case .connector(let connector):
                    Task { await runtime.disconnect(connector) }
                case .composio(let slug, _):
                    Task { await composioConnections.disconnect(slug) }
                case nil:
                    break
                }
            }
            Button("Cancel", role: .cancel) { disconnectPrompt = nil }
        } message: {
            Text("HeyMate will forget this connection on this Mac.")
        }
        .confirmationDialog(
            commandRemovalPrompt.map { "Remove the command for \($0.displayName)?" } ?? "Remove the command?",
            isPresented: Binding(
                get: { commandRemovalPrompt != nil },
                set: { isPresented in
                    if !isPresented { commandRemovalPrompt = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove command", role: .destructive) {
                let connector = commandRemovalPrompt
                commandRemovalPrompt = nil
                if let connector {
                    removeCustomMCPCommand(connector)
                }
            }
            Button("Cancel", role: .cancel) { commandRemovalPrompt = nil }
        } message: {
            Text("HeyMate will disconnect it and forget this command on this Mac.")
        }
        .task {
            await composioToolkitDirectory.loadDefaultPage(apiKey: composioConnections.apiKey)
            await composioConnections.revalidate()
        }
        .onChange(of: searchText) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedComposioCategory = "All"
            }
            composioToolkitDirectory.search(newValue, apiKey: composioConnections.apiKey)
        }
    }

    private var connectedSummary: String {
        let connectedCount = store.connectionStates.values.filter(\.isConnected).count
            + composioConnections.connectedSlugs.count
        if connectedCount == 0 {
            return "Turn on the apps HeyMate may use. Calendar, Reminders, Notes, and the other Mac apps need no setup."
        }
        return "\(connectedCount) connected. HeyMate can only reach what you turn on."
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
            TextField("Search apps and tools", text: $searchText)
                .textFieldStyle(.plain)
                .font(DS.Fonts.body)
                .frame(width: 180)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private var composioSetupCard: some View {
        DesktopCard(
            title: "More apps (optional)",
            footnote: "Mac apps like Calendar and Notes never need this. It is only for web apps."
        ) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 38, height: 38)
                    .background(DS.Colors.surface3, in: RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Want Gmail, Slack, Notion, and more?")
                        .font(DS.Fonts.headline)
                    Text("For now these need a free key from Composio, a service that handles signing in to web apps. Paste it once in Settings → Advanced. Your app logins stay with Composio, not HeyMate.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Set up in Advanced") {
                    DesktopSection.openSettings(tab: "advanced")
                }
                .buttonStyle(DSSecondaryButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var composioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Web apps", subtitle: "Popular first · powered by Composio")
            composioCategoryChips
        }
        if composioToolkitDirectory.isLoading && composioToolkitDirectory.toolkits.isEmpty {
            ProgressView("Loading apps…")
                .controlSize(.small)
        } else if let failure = composioToolkitDirectory.loadFailureMessage {
            DesktopEmptyState(symbolName: "exclamationmark.triangle", title: "Could not load apps", message: failure)
        } else if visibleComposioToolkits.isEmpty {
            DesktopEmptyState(
                symbolName: "magnifyingglass",
                title: "No matches",
                message: composioEmptyMessage
            )
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 10)],
                spacing: 10
            ) {
                ForEach(visibleComposioToolkits) { toolkit in
                    ComposioToolkitCard(
                        toolkit: toolkit,
                        state: composioConnections.state(for: toolkit.slug),
                        onConnect: { Task { await composioConnections.connect(toolkit) } },
                        onDisconnect: { requestComposioDisconnect(toolkit) }
                    )
                }
            }
        }
    }

    private var visibleComposioToolkits: [ComposioToolkit] {
        guard selectedComposioCategory != "All" else {
            return composioToolkitDirectory.toolkits
        }
        return composioToolkitDirectory.toolkits.filter { toolkit in
            toolkit.categories.contains(selectedComposioCategory)
        }
    }

    private var composioCategoryNames: [String] {
        let counts = composioToolkitDirectory.toolkits
            .flatMap(\.categories)
            .reduce(into: [String: Int]()) { counts, category in
                counts[category, default: 0] += 1
            }
        let popularCategories = counts.keys.sorted { firstCategory, secondCategory in
            let firstCount = counts[firstCategory, default: 0]
            let secondCount = counts[secondCategory, default: 0]
            if firstCount != secondCount { return firstCount > secondCount }
            return firstCategory < secondCategory
        }
        return ["All"] + Array(popularCategories.prefix(6))
    }

    private var composioCategoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(composioCategoryNames, id: \.self) { category in
                    let isSelected = selectedComposioCategory == category
                    Button {
                        selectedComposioCategory = category
                    } label: {
                        Text(category)
                            .font(DS.Fonts.sectionLabel)
                            .foregroundColor(isSelected ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? DS.Colors.accent : DS.Colors.surface2)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var composioEmptyMessage: String {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearchText.isEmpty {
            return "No one-click integration matches “\(trimmedSearchText)”."
        }
        return "No one-click integration appears in \(selectedComposioCategory)."
    }

    @ViewBuilder
    private var localSection: some View {
        let nativeApps = filteredConnectors(ConnectorCatalog.appleNativeConnectors)
        let localTools = filteredConnectors(ConnectorCatalog.localCLIConnectors)

        if !nativeApps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(title: "Mac apps", subtitle: "Work right away. No account or key needed")

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(nativeApps) { connector in
                        NativeAppConnectionCard(
                            connector: connector,
                            state: store.connectionState(for: connector.id),
                            onConnect: { connect(connector) },
                            onDisconnect: { requestDisconnect(connector) }
                        )
                    }
                }
            }
        }

        if !localTools.isEmpty {
            connectorSection(
                title: "Local tools",
                subtitle: "Command-line tools already signed in locally",
                connectors: localTools
            )
        }
    }

    @ViewBuilder
    private var customSection: some View {
        let customMCPConnector = ConnectorCatalog.connector(withID: "mcp-custom")
        let presetConnectors = filteredConnectors(
            ConnectorCatalog.mcpConnectors.filter {
                $0.id != ComposioSessionStore.connectorID && $0.id != "mcp-custom"
            }
        )

        let primaryNeedsCommand = customMCPConnector.map { !shouldListCustomMCP(id: $0.id) } ?? true
        let savedCustomServers = listedCustomMCPConnectors

        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Custom", subtitle: "Bring tools HeyMate can inspect before use")

            HStack(alignment: .top, spacing: 10) {
                if customMCPConnector != nil {
                    CustomIntegrationChoiceCard(
                        symbolName: "cable.connector",
                        title: "MCP server",
                        detail: "Add a local command or remote MCP URL. HeyMate discovers its tools before connecting.",
                        actionTitle: primaryNeedsCommand ? "Add MCP" : "Add another MCP server",
                        isEnabled: true,
                        action: { addCustomMCPServer() }
                    )
                }

                CustomIntegrationChoiceCard(
                    symbolName: "curlybraces.square",
                    title: "HTTP API",
                    detail: "An API needs an OpenAPI schema and explicit authentication mapping before it can become safe agent tools.",
                    actionTitle: "Requirements",
                    isEnabled: false,
                    action: { isShowingAPIContractHelp = true }
                )
            }

            if !savedCustomServers.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 340, maximum: 420), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(savedCustomServers) { connector in
                        ConnectorCard(
                            connector: connector,
                            state: store.connectionState(for: connector.id),
                            record: store.record(for: connector.id),
                            onConnect: { connect(connector) },
                            onDisconnect: { requestDisconnect(connector) },
                            onChangePolicy: { store.setApprovalPolicy($0, for: connector.id) },
                            onAddKey: { beginKeyEntry(for: connector) },
                            onEditCommand: { beginLaunchCommandEntry(for: connector) },
                            onRemoveCommand: { commandRemovalPrompt = connector },
                            showsReplaceKey: showsReplaceKey(for: connector)
                        )
                    }
                }
            }

            if !presetConnectors.isEmpty {
                DisclosureGroup(isExpanded: $areMCPPresetsExpanded) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 340, maximum: 420), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(presetConnectors) { connector in
                            ConnectorCard(
                                connector: connector,
                                state: store.connectionState(for: connector.id),
                                record: store.record(for: connector.id),
                                onConnect: { connect(connector) },
                                onDisconnect: { requestDisconnect(connector) },
                                onChangePolicy: { store.setApprovalPolicy($0, for: connector.id) },
                                onAddKey: { beginKeyEntry(for: connector) },
                                showsReplaceKey: showsReplaceKey(for: connector)
                            )
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Text("MCP presets")
                        .font(DS.Fonts.sectionLabel)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
        }
    }

    private var apiContractHelpSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("HTTP APIs need a contract", systemImage: "curlybraces.square")
                .font(DS.Fonts.title)

            Text("A base URL and API key do not describe available operations, parameters, or risk. HeyMate will not guess those details.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                requirementRow("OpenAPI 3 schema", detail: "Defines operations and parameters.")
                requirementRow("Authentication header", detail: "Stored in macOS Keychain.")
                requirementRow("Risk review", detail: "Writes, sends, and deletes stay approval-gated.")
            }

            Text("Available now: connect an MCP server that wraps your API. Native OpenAPI import remains disabled until schema validation and risk mapping ship.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.warningText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { isShowingAPIContractHelp = false }
                    .buttonStyle(DSPrimaryButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 470)
    }

    private func requirementRow(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundColor(DS.Colors.info)
            Text(title)
                .font(DS.Fonts.headline)
            Text(detail)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private func filteredConnectors(_ connectors: [Connector]) -> [Connector] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return connectors }
        let matchingIDs = Set(ConnectorCatalog.search(trimmed).map(\.id))
        return connectors.filter { matchingIDs.contains($0.id) }
    }

    @ViewBuilder
    private func connectorSection(title: String, subtitle: String, connectors: [Connector]) -> some View {
        if !connectors.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(title: title, subtitle: subtitle)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 340, maximum: 420), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(connectors) { connector in
                        ConnectorCard(
                            connector: connector,
                            state: store.connectionState(for: connector.id),
                            record: store.record(for: connector.id),
                            onConnect: { connect(connector) },
                            onDisconnect: { requestDisconnect(connector) },
                            onChangePolicy: { policy in
                                store.setApprovalPolicy(policy, for: connector.id)
                            },
                            onAddKey: { beginKeyEntry(for: connector) },
                            showsReplaceKey: showsReplaceKey(for: connector)
                        )
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)
            Text(subtitle)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
            Spacer(minLength: 0)
        }
    }

    private func connect(_ connector: Connector) {
        if ConnectorCatalog.isUserSuppliedMCPID(connector.id),
           store.record(for: connector.id).customLaunchCommand?.isEmpty != false {
            beginLaunchCommandEntry(for: connector)
            return
        }
        // MCP servers commonly need a key before they will even start, so
        // ask for it up front rather than letting the handshake fail.
        let needsKeyFirst = connector.transport == .apiKey
            || (connector.transport == .mcp && Self.mcpConnectorsRequiringKey.contains(connector.id))
        if needsKeyFirst, !ConnectorSecretStore.hasSecret(forConnectorID: connector.id) {
            beginKeyEntry(for: connector)
            return
        }
        Task { await runtime.connect(connector) }
    }

    private func showsReplaceKey(for connector: Connector) -> Bool {
        connector.transport == .apiKey || Self.mcpConnectorsRequiringKey.contains(connector.id)
    }

    private func beginKeyEntry(for connector: Connector) {
        apiKeyDraft = ""
        connectorAwaitingKeyEntry = connector
    }

    private func requestDisconnect(_ connector: Connector) {
        disconnectPrompt = DisconnectPrompt(kind: .connector(connector))
    }

    private func requestComposioDisconnect(_ toolkit: ComposioToolkit) {
        disconnectPrompt = DisconnectPrompt(kind: .composio(slug: toolkit.slug, name: toolkit.name))
    }

    private func beginLaunchCommandEntry(for connector: Connector) {
        launchCommandDraft = store.record(for: connector.id).customLaunchCommand ?? ""
        connectorAwaitingCommandEntry = connector
    }

    /// The first server occupies `mcp-custom`. Once that command is saved,
    /// another tap mints `mcp-custom-` plus a UUID and opens the same sheet.
    private func addCustomMCPServer() {
        if let primary = ConnectorCatalog.connector(withID: ConnectorCatalog.customMCPConnectorID),
           !shouldListCustomMCP(id: primary.id) {
            beginLaunchCommandEntry(for: primary)
            return
        }
        let identifier = ConnectorCatalog.additionalCustomMCPIDPrefix + UUID().uuidString
        let connector = ConnectorCatalog.userSuppliedMCPConnector(
            id: identifier,
            displayName: "Custom MCP server"
        )
        beginLaunchCommandEntry(for: connector)
    }

    private func removeCustomMCPCommand(_ connector: Connector) {
        Task {
            await runtime.disconnect(connector)
            store.setCustomLaunchCommand(nil, for: connector.id)
            if ConnectorCatalog.isAdditionalCustomMCPID(connector.id) {
                store.removeAdditionalCustomMCP(connectorID: connector.id)
            }
        }
    }

    private var listedCustomMCPConnectors: [Connector] {
        var listed: [Connector] = []
        if shouldListCustomMCP(id: ConnectorCatalog.customMCPConnectorID) {
            let primary = presentedCustomMCP(id: ConnectorCatalog.customMCPConnectorID)
            if matchesCustomMCPSearch(primary) {
                listed.append(primary)
            }
        }
        let additional = store.additionalCustomMCPConnectors()
            .filter { shouldListCustomMCP(id: $0.id) && matchesCustomMCPSearch($0) }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        return listed + additional
    }

    private func presentedCustomMCP(id: String) -> Connector {
        let command = store.record(for: id).customLaunchCommand
        return ConnectorCatalog.userSuppliedMCPConnector(
            id: id,
            displayName: ConnectorCatalog.displayName(forCustomLaunchCommand: command),
            summary: command
        )
    }

    private func shouldListCustomMCP(id: String) -> Bool {
        let record = store.record(for: id)
        if record.customLaunchCommand?.isEmpty == false { return true }
        if record.isEnabled { return true }
        if record.lastErrorMessage?.isEmpty == false { return true }
        return store.connectionState(for: id) != .notConnected
    }

    private func matchesCustomMCPSearch(_ connector: Connector) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let command = store.record(for: connector.id).customLaunchCommand ?? ""
        let haystack = [connector.displayName, connector.summary, command].joined(separator: " ")
        return haystack.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Servers whose published packages exit immediately without a key.
    static let mcpConnectorsRequiringKey: Set<String> = [
        "mcp-brave-search"
    ]

    // MARK: API key sheet

    private func apiKeySheet(for connector: Connector) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect \(connector.displayName)")
                .font(DS.Fonts.title)

            Text("HeyMate stores this in your macOS Keychain and passes it to the server as `\(ConnectorRuntime.environmentVariableName(forConnectorID: connector.id))`. It is never written to a file and never sent anywhere else.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("API key", text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { connectorAwaitingKeyEntry = nil }
                    .buttonStyle(DSSecondaryButtonStyle())
                Button("Save and connect") {
                    let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedKey.isEmpty else { return }
                    ConnectorSecretStore.setSecret(trimmedKey, forConnectorID: connector.id)
                    apiKeyDraft = ""
                    connectorAwaitingKeyEntry = nil
                    Task { await runtime.connect(connector) }
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func launchCommandSheet(for connector: Connector) -> some View {
        let savedCommand = store.record(for: connector.id).customLaunchCommand ?? ""
        let isEditing = !savedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit MCP server" : "Add custom MCP server")
                .font(DS.Fonts.title)
            Text("Paste a local launch command or remote MCP URL. HeyMate discovers its tools before marking it connected.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("npx -y package-name or https://…", text: $launchCommandDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    launchCommandDraft = ""
                    connectorAwaitingCommandEntry = nil
                }
                .buttonStyle(DSSecondaryButtonStyle())
                Button("Save and connect") {
                    let command = launchCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !command.isEmpty else { return }
                    store.setCustomLaunchCommand(command, for: connector.id)
                    launchCommandDraft = ""
                    connectorAwaitingCommandEntry = nil
                    Task { await runtime.connect(connector) }
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(launchCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear {
            if launchCommandDraft.isEmpty, !savedCommand.isEmpty {
                launchCommandDraft = savedCommand
            }
        }
    }
}

private struct DisconnectPrompt: Identifiable {
    enum Kind {
        case connector(Connector)
        case composio(slug: String, name: String)
    }

    let id = UUID()
    let kind: Kind

    var name: String {
        switch kind {
        case .connector(let connector):
            return connector.displayName
        case .composio(_, let name):
            return name
        }
    }
}

// MARK: - Native app connection card

/// Native apps use the same short connection treatment as hosted apps. Their
/// per-action permission rules remain enforced by the tool runtime; showing
/// the full MCP/CLI policy surface here made this simple opt-in needlessly tall.
private struct NativeAppConnectionCard: View {
    let connector: Connector
    let state: ConnectorConnectionState
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: connector.symbolName)
                .font(DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.surface3)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(connector.displayName)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(nativeAppStatus)
                    .font(DS.Fonts.caption)
                    .foregroundColor(state.tintColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            if state.isConnected {
                Button("Disconnect", action: onDisconnect)
                    .buttonStyle(ToolkitCardButtonStyle(prominence: .secondary))
            } else if state == .connecting {
                ProgressView().controlSize(.small)
            } else {
                Button(state == .notConnected ? "Connect" : "Retry", action: onConnect)
                    .buttonStyle(ToolkitCardButtonStyle(prominence: .primary))
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(isHovered ? DS.Colors.surface2 : DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(
                    state.isConnected ? DS.Colors.success.opacity(0.48) : DS.Colors.borderSubtle,
                    lineWidth: 1
                )
        )
        .offset(y: isHovered && !accessibilityReduceMotion ? -1 : 0)
        .animation(accessibilityReduceMotion ? nil : DS.Animation.controlSpring, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var nativeAppStatus: String {
        switch state {
        case .notConnected:
            return "Not connected"
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Connected"
        case .needsAttention(let reason):
            return reason
        }
    }
}

// MARK: - Card

private struct ConnectorCard: View {
    let connector: Connector
    let state: ConnectorConnectionState
    let record: ConnectorRecord
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onChangePolicy: (ConnectorApprovalPolicy) -> Void
    let onAddKey: () -> Void
    var onEditCommand: (() -> Void)? = nil
    var onRemoveCommand: (() -> Void)? = nil
    var showsReplaceKey: Bool = false

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(connector.summary)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            capabilityChips

            if let errorMessage = record.lastErrorMessage, record.isEnabled {
                Text(errorMessage)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.3)
            footer
            if onEditCommand != nil || onRemoveCommand != nil {
                commandActions
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(isHovered ? DS.Colors.surface2 : DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(state.isConnected ? DS.Colors.success.opacity(0.4) : DS.Colors.borderSubtle, lineWidth: 1)
        )
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: connector.symbolName)
                .font(DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface3)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(connector.displayName)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                HStack(spacing: 5) {
                    Circle().fill(state.tintColor).frame(width: 5, height: 5)
                    Text(state.displayName)
                        .font(DS.Fonts.statusWord)
                        .foregroundColor(state.tintColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            riskBadge
        }
    }

    private var riskBadge: some View {
        Text(connector.maximumRisk.displayName)
            .font(DS.Fonts.micro)
            .tracking(0.3)
            .foregroundColor(connector.maximumRisk.tintColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(connector.maximumRisk.tintColor.opacity(0.13))
            )
            .help("The most sensitive thing this connector's tools can do.")
    }

    private var capabilityChips: some View {
        HStack(spacing: 5) {
            ForEach(connector.capabilities.prefix(3), id: \.self) { capability in
                Text(capability)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous).fill(DS.Colors.surface3)
                    )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label(connector.transport.displayName, systemImage: transportSymbolName)
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textTertiary)
                .labelStyle(.titleAndIcon)

            Spacer(minLength: 0)

            if state.isConnected {
                Menu {
                    ForEach(ConnectorApprovalPolicy.allCases, id: \.self) { policy in
                        Button {
                            onChangePolicy(policy)
                        } label: {
                            if policy == record.approvalPolicy {
                                Label(policy.displayName, systemImage: "checkmark")
                            } else {
                                Text(policy.displayName)
                            }
                        }
                    }
                } label: {
                    Text(record.approvalPolicy.displayName)
                        .font(DS.Fonts.micro)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()
                .help("When this connector needs your approval. Sends and deletions always ask, whatever you pick.")

                if showsReplaceKey {
                    Button("Replace key", action: onAddKey)
                        .buttonStyle(DSTertiaryButtonStyle())
                }

                Button("Disconnect", action: onDisconnect)
                    .buttonStyle(DSTertiaryButtonStyle())
            } else if case .connecting = state {
                ProgressView().controlSize(.small)
            } else {
                // Key-only connectors get an explicit entry point. MCP
                // servers that need a key are handled by the parent's
                // connect path, which opens the same sheet on demand.
                if connector.transport == .apiKey {
                    Button(
                        ConnectorSecretStore.hasSecret(forConnectorID: connector.id) ? "Change key" : "Add key",
                        action: onAddKey
                    )
                    .buttonStyle(DSSecondaryButtonStyle())
                }
                Button(state == .notConnected ? "Connect" : "Retry", action: onConnect)
                    .buttonStyle(DSPrimaryButtonStyle())
            }
        }
    }

    private var commandActions: some View {
        HStack(spacing: 8) {
            if let onEditCommand {
                Button("Edit command", action: onEditCommand)
                    .buttonStyle(DSTertiaryButtonStyle())
            }
            if let onRemoveCommand {
                Button("Remove command", action: onRemoveCommand)
                    .buttonStyle(DSTertiaryButtonStyle())
            }
            Spacer(minLength: 0)
        }
    }

    private var transportSymbolName: String {
        switch connector.transport {
        case .appleNative: return "lock.shield"
        case .localCLI: return "terminal"
        case .mcp: return "cable.connector"
        case .apiKey: return "key"
        }
    }
}

// MARK: - Composio app card

private struct ComposioToolkitCard: View {
    let toolkit: ComposioToolkit
    let state: ComposioConnectionState
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        HStack(spacing: 13) {
            ComposioToolkitLogoView(toolkit: toolkit, isConnected: state.isConnected)

            VStack(alignment: .leading, spacing: 3) {
                Text(toolkit.name)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(toolkit.description.isEmpty ? "Connect through Composio" : toolkit.description)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                if case .needsAttention(let reason) = state {
                    Text(reason)
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.warningText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 6)

            if state.isConnected {
                Button("Disconnect", action: onDisconnect)
                    .buttonStyle(ToolkitCardButtonStyle(prominence: .secondary))
            } else if state == .connecting {
                ProgressView().controlSize(.small)
            } else {
                Button(state.needsAttention ? "Retry" : "Connect", action: onConnect)
                    .buttonStyle(ToolkitCardButtonStyle(prominence: .primary))
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            toolkit.visualAccent.opacity(isHovered ? 0.11 : 0.055),
                            isHovered ? DS.Colors.surface2 : DS.Colors.surface1
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(
                    state.isConnected
                        ? DS.Colors.success.opacity(0.48)
                        : isHovered
                            ? toolkit.visualAccent.opacity(0.38)
                            : DS.Colors.borderSubtle,
                    lineWidth: 1
                )
        )
        .shadow(color: toolkit.visualAccent.opacity(isHovered ? 0.14 : 0), radius: 14, y: 6)
        .offset(y: isHovered && !accessibilityReduceMotion ? -1 : 0)
        .animation(accessibilityReduceMotion ? nil : DS.Animation.controlSpring, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct ToolkitCardButtonStyle: ButtonStyle {
    enum Prominence {
        case primary
        case secondary
    }

    let prominence: Prominence
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.sectionLabel)
            .foregroundStyle(foregroundColor)
            .frame(minWidth: 72)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(backgroundColor(isPressed: configuration.isPressed)))
            .overlay(Capsule().stroke(borderColor, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private var foregroundColor: Color {
        prominence == .primary ? DS.Colors.textOnAccent : DS.Colors.textSecondary
    }

    private var borderColor: Color {
        prominence == .primary ? Color.clear : DS.Colors.borderStrong
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch prominence {
        case .primary:
            if isPressed { return DS.Colors.accentHover }
            return isHovered ? DS.Colors.accentHover : DS.Colors.accent
        case .secondary:
            if isPressed { return DS.Colors.surface4 }
            return isHovered ? DS.Colors.surface3 : DS.Colors.surface2
        }
    }
}

private extension ComposioConnectionState {
    var needsAttention: Bool {
        if case .needsAttention = self { return true }
        return false
    }
}

private struct CustomIntegrationChoiceCard: View {
    let symbolName: String
    let title: String
    let detail: String
    let actionTitle: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(DS.Fonts.title)
                    .foregroundColor(isEnabled ? DS.Colors.accentText : DS.Colors.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(isEnabled ? DS.Colors.accentSubtle : DS.Colors.surface3)
                    )

                Text(title)
                    .font(DS.Fonts.titleCompact)
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer(minLength: 6)

                if !isEnabled {
                    Text("Schema required")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.warningText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(DS.Colors.warning.opacity(0.10), in: Capsule())
                }
            }

            Text(detail)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if isEnabled {
                Button(actionTitle, action: action)
                    .buttonStyle(DSPrimaryButtonStyle())
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(DSSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(isHovered ? DS.Colors.surface2 : DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }
}
