//
//  ComposioSessionTests.swift
//  leanring-buddyTests
//
//  The two things that rot silently: the shape of the request Composio
//  expects, and the shape of the command the session turns into. Neither
//  needs a live account to assert.
//

import Foundation
import Testing
@testable import HeyMate

struct ComposioProvisionerTests {

    private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    @Test func requestCarriesKeyInHeaderAndAsksForConnectionManagement() throws {
        let request = try ComposioProvisioner.makeRequest(apiKey: "comp_test_key", userID: "heymate-abc")

        #expect(request.httpMethod == "POST")
        #expect(request.url == ComposioProvisioner.sessionEndpoint)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "comp_test_key")

        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["user_id"] as? String == "heymate-abc")
        // Without this the user is never offered the browser link that
        // authorises a new app, which is the entire point of the connector.
        let manageConnections = try #require(decoded["manage_connections"] as? [String: Any])
        #expect(manageConnections["enable"] as? Bool == true)
    }

    @Test func sessionIsParsedFromTheToolRouterResponse() throws {
        let payload = """
        {
          "session_id": "trs_123",
          "mcp": { "type": "http", "url": "https://backend.composio.dev/mcp/trs_123" },
          "tool_router_tools": ["COMPOSIO_SEARCH_TOOLS", "COMPOSIO_MANAGE_CONNECTIONS"]
        }
        """.data(using: .utf8)!

        let session = try ComposioProvisioner.parseSession(from: payload)
        #expect(session.sessionID == "trs_123")
        #expect(session.mcpURL == "https://backend.composio.dev/mcp/trs_123")
        #expect(session.toolNames.count == 2)
        #expect(session.namespacedToolNames.first == "mcp__composio__COMPOSIO_SEARCH_TOOLS")
    }

    @Test func aResponseWithoutAnMCPURLIsRejected() {
        let payload = #"{"session_id":"trs_123"}"#.data(using: .utf8)!
        #expect(throws: ComposioProvisioningError.self) {
            _ = try ComposioProvisioner.parseSession(from: payload)
        }
    }

    @Test func launchCommandReferencesTheKeyRatherThanEmbeddingIt() {
        let session = ComposioSession(
            sessionID: "trs_123",
            mcpURL: "https://backend.composio.dev/mcp/trs_123",
            toolNames: [],
            createdAt: Date()
        )
        let command = session.launchCommand

        #expect(command.contains("mcp-remote"))
        #expect(command.contains("'https://backend.composio.dev/mcp/trs_123'"))
        // Single quotes so the login shell leaves the placeholder alone and
        // mcp-remote substitutes it — the key must never reach a command line.
        #expect(command.contains("--header 'x-api-key:${COMPOSIO_API_KEY}'"))
    }

    @Test func theKeychainEnvironmentNameMatchesWhatTheCommandExpects() {
        #expect(ConnectorRuntime.environmentVariableName(forConnectorID: ComposioSessionStore.connectorID) == "COMPOSIO_API_KEY")
    }

    @Test func aConfiguredUserIDWinsOverAMintedOne() {
        let defaults = makeDefaults()
        // Only assert the override when the environment actually carries one,
        // so the test is honest on a machine with no secrets file.
        guard let configured = HeyMateSecrets.lookup(ComposioSessionStore.userIDSecretsKey),
              !configured.isEmpty else { return }
        #expect(ComposioSessionStore.userID(userDefaults: defaults) == configured)
    }

    @Test func userIDIsMintedOnceAndReused() {
        let defaults = makeDefaults()
        let first = ComposioSessionStore.userID(userDefaults: defaults)
        let second = ComposioSessionStore.userID(userDefaults: defaults)
        #expect(first == second)
        #expect(first.hasPrefix("heymate-"))
        #expect(first.isEmpty == false)
    }

    @Test func sessionSurvivesARoundTripThroughStorage() {
        let defaults = makeDefaults()
        let session = ComposioSession(
            sessionID: "trs_abc",
            mcpURL: "https://example.invalid/mcp",
            toolNames: ["COMPOSIO_SEARCH_TOOLS"],
            createdAt: Date()
        )
        ComposioSessionStore.save(session, userDefaults: defaults)
        #expect(ComposioSessionStore.session(userDefaults: defaults) == session)

        ComposioSessionStore.clear(userDefaults: defaults)
        #expect(ComposioSessionStore.session(userDefaults: defaults) == nil)
    }

    @Test func anUnconnectedComposioContributesNothingToAnAgentLeg() {
        let defaults = makeDefaults()
        #expect(ComposioAgentAttachment.isAttachable(userDefaults: defaults) == false)
        #expect(ComposioAgentAttachment.mcpServerConfiguration(userDefaults: defaults) == nil)
        #expect(ComposioAgentAttachment.claudeCodeToolNames(userDefaults: defaults).isEmpty)
        #expect(ComposioAgentAttachment.childEnvironment(userDefaults: defaults).isEmpty)
    }

    @Test func aDisabledRecordKeepsComposioOffTheAgentLegEvenWithASession() {
        let defaults = makeDefaults()
        ComposioSessionStore.save(
            ComposioSession(sessionID: "trs_abc", mcpURL: "https://example.invalid/mcp", toolNames: [], createdAt: Date()),
            userDefaults: defaults
        )
        // No connector record at all is the same as disabled.
        #expect(ComposioAgentAttachment.isConnectorEnabled(userDefaults: defaults) == false)
        #expect(ComposioAgentAttachment.isAttachable(userDefaults: defaults) == false)
    }

    @Test func composioIsInTheCatalogAsAnMCPConnectorThatMintsItsOwnCommand() throws {
        let connector = try #require(ConnectorCatalog.connector(withID: ComposioSessionStore.connectorID))
        #expect(connector.transport == .mcp)
        // Nil on purpose: the URL does not exist until a session is created.
        #expect(connector.mcpLaunchCommand == nil)
        // It can send and delete in other people's accounts, so the card must
        // say so before the user connects, not after.
        #expect(connector.maximumRisk == .destructive)
    }
}

// MARK: - Brokered sign-in

struct ComposioAuthBrokerTests {

    @Test func authConfigRequestAsksForComposioManagedAuth() throws {
        let request = try ComposioAuthBroker.makeAuthConfigRequest(apiKey: "k", toolkitSlug: "gmail")

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path.hasSuffix("/auth_configs") == true)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")

        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((decoded["toolkit"] as? [String: Any])?["slug"] as? String == "gmail")
        // Managed auth is what spares the user from registering an OAuth app
        // per service, which is the whole reason this path exists.
        #expect((decoded["auth_config"] as? [String: Any])?["type"] as? String == "use_composio_managed_auth")
    }

    @Test func connectionRequestBindsTheAccountToThisInstall() throws {
        let request = try ComposioAuthBroker.makeConnectionRequest(
            apiKey: "k",
            authConfigID: "ac_1",
            userID: "heymate-abc"
        )
        // The `connected_accounts` create endpoint refuses Composio-managed
        // OAuth outright; `/link` is the only route that works. Verified live.
        #expect(request.url?.path.hasSuffix("/connected_accounts/link") == true)

        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["auth_config_id"] as? String == "ac_1")
        #expect(decoded["user_id"] as? String == "heymate-abc")
        // No callback_url on purpose: a custom scheme is not a redirect target
        // Composio is guaranteed to accept, so the status is polled instead.
        #expect(decoded["callback_url"] == nil)
    }

    @Test func authConfigIDIsReadFromEitherResponseShape() throws {
        #expect(try ComposioAuthBroker.parseAuthConfigID(from: #"{"auth_config":{"id":"ac_1"}}"#.data(using: .utf8)!) == "ac_1")
        #expect(try ComposioAuthBroker.parseAuthConfigID(from: #"{"id":"ac_2"}"#.data(using: .utf8)!) == "ac_2")
    }

    @Test func connectionResponseYieldsTheBrowserURLToOpen() throws {
        // Shape taken from a live `/link` response: an id and a consent URL,
        // and no status field at all.
        let payload = """
        {"id":"ca_Evsaw43sAyCt","redirect_url":"https://connect.composio.dev/link/lk_abc"}
        """.data(using: .utf8)!
        let request = try ComposioAuthBroker.parseConnectionRequest(from: payload)
        #expect(request.connectedAccountID == "ca_Evsaw43sAyCt")
        #expect(request.redirectURL?.host == "connect.composio.dev")
        // Missing status must not read as failure — the first poll answers.
        #expect(request.status == "INITIATED")
    }

    @Test func disconnectDeletesTheConnectedAccount() {
        let request = ComposioAuthBroker.makeDisconnectRequest(apiKey: "k", connectedAccountID: "ca_123")
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path.hasSuffix("/connected_accounts/ca_123") == true)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
    }

    @Test func activeAccountListIsScopedToTheStableUserAndParsedByToolkit() throws {
        let request = ComposioAuthBroker.makeActiveConnectionsRequest(apiKey: "k", userID: "heymate-abc")
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        #expect(components?.queryItems?.contains(URLQueryItem(name: "user_ids", value: "heymate-abc")) == true)
        #expect(components?.queryItems?.contains(URLQueryItem(name: "statuses", value: "ACTIVE")) == true)

        let payload = """
        {
          "items": [
            {"id":"ca_1","status":"ACTIVE","toolkit":{"slug":"gmail","name":"Gmail"}},
            {"id":"ca_2","status":"FAILED","toolkit":{"slug":"slack","name":"Slack"}}
          ]
        }
        """.data(using: .utf8)!
        let activeConnections = try ComposioAuthBroker.parseActiveConnections(from: payload)
        #expect(activeConnections == [
            ComposioConnectedAccountSummary(
                connectedAccountID: "ca_1",
                toolkitSlug: "gmail",
                displayName: "Gmail"
            )
        ])
    }

    @Test func vendorAppsAreFetchedInsteadOfDuplicatedInTheLocalCatalog() {
        let obsoleteIdentifiers = ["gmail", "mcp-slack", "mcp-notion", "mcp-github"]
        for identifier in obsoleteIdentifiers {
            #expect(ConnectorCatalog.connector(withID: identifier) == nil)
        }
        #expect(ConnectorCatalog.connector(withID: ComposioSessionStore.connectorID) != nil)
    }

    @Test func authConfigsAreCachedPerToolkit() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        #expect(ComposioAuthConfigCache.identifier(forToolkit: "gmail", userDefaults: defaults) == nil)

        ComposioAuthConfigCache.store("ac_1", forToolkit: "gmail", userDefaults: defaults)
        ComposioAuthConfigCache.store("ac_2", forToolkit: "slack", userDefaults: defaults)
        #expect(ComposioAuthConfigCache.identifier(forToolkit: "gmail", userDefaults: defaults) == "ac_1")
        #expect(ComposioAuthConfigCache.identifier(forToolkit: "slack", userDefaults: defaults) == "ac_2")

        ComposioAuthConfigCache.clear(userDefaults: defaults)
        #expect(ComposioAuthConfigCache.identifier(forToolkit: "gmail", userDefaults: defaults) == nil)
    }

    @Test func activeIsTheOnlyStatusThatCounts() {
        #expect(ComposioAuthBroker.activeStatus == "ACTIVE")
        #expect(ComposioAuthBroker.failureStatuses.contains("FAILED"))
        #expect(ComposioAuthBroker.failureStatuses.contains("EXPIRED"))
        #expect(ComposioAuthBroker.failureStatuses.contains("ACTIVE") == false)
    }
}

// MARK: - Toolkit directory and per-app state

@MainActor
struct ComposioToolkitDirectoryTests {

    @Test func listRequestUsesServerSideSearchAndKeepsTheKeyInAHeader() {
        let request = ComposioToolkitDirectory.makeListRequest(apiKey: "secret", search: "google calendar", limit: 30)
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)

        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(components?.queryItems?.contains(URLQueryItem(name: "search", value: "google calendar")) == true)
        #expect(components?.queryItems?.contains(URLQueryItem(name: "limit", value: "30")) == true)
    }

    @Test func parserKeepsOnlyAppsThatCanConnectWithoutDeveloperCredentials() throws {
        let payload = """
        {
          "items": [
            {
              "slug": "gmail",
              "name": "Gmail",
              "composio_managed_auth_schemes": ["OAUTH2"],
              "no_auth": false,
              "meta": {
                "description": "Read and send mail",
                "logo": "https://example.invalid/gmail.png",
                "tools_count": 24,
                "categories": [{"name": "Communication"}]
              }
            },
            {
              "slug": "hackernews",
              "name": "Hacker News",
              "composio_managed_auth_schemes": [],
              "no_auth": true,
              "meta": {}
            },
            {
              "slug": "bring-your-own-oauth",
              "name": "Developer credentials required",
              "composio_managed_auth_schemes": [],
              "no_auth": false,
              "meta": {}
            }
          ]
        }
        """.data(using: .utf8)!

        let toolkits = ComposioToolkitDirectory.parseToolkits(from: payload)
        #expect(toolkits.map(\.slug) == ["gmail", "hackernews"])
        #expect(toolkits.first?.toolCount == 24)
        #expect(toolkits.first?.categories == ["Communication"])
    }

    @Test func persistedConnectionsRestoreAsKnownConnectedApps() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let record = ComposioConnectionRecord(
            toolkitSlug: "gmail",
            connectedAccountID: "ca_123",
            displayName: "Gmail"
        )
        defaults.set(try JSONEncoder().encode(["gmail": record]), forKey: "composioConnections")

        let runtime = ComposioConnectionsRuntime(userDefaults: defaults)
        #expect(runtime.records["gmail"] == record)
        #expect(runtime.state(for: "gmail") == .connected)

        // Empty account ids represent no-auth toolkits, so disconnecting is
        // local and does not need a Keychain fixture or network transport.
        let noAuthRecord = ComposioConnectionRecord(
            toolkitSlug: "hackernews",
            connectedAccountID: "",
            displayName: "Hacker News"
        )
        defaults.set(try JSONEncoder().encode(["hackernews": noAuthRecord]), forKey: "composioConnections")
        let noAuthRuntime = ComposioConnectionsRuntime(userDefaults: defaults)
        await noAuthRuntime.disconnect("hackernews")
        #expect(noAuthRuntime.records["hackernews"] == nil)
        #expect(noAuthRuntime.state(for: "hackernews") == .notConnected)
    }
}
