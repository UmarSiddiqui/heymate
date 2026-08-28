//
//  ComposioAuthBroker.swift
//  leanring-buddy
//
//  The sign-in service HeyMate never had.
//
//  Browser OAuth needs somebody to hold the refresh token, and HeyMate
//  deliberately runs no such backend. Composio is that somebody. It is not
//  a service card to connect to: it is the API behind the live toolkit
//  directory, making Gmail, Slack, Notion and the rest available without
//  HeyMate ever seeing a vendor token.
//
//  Three calls, in order, per connector:
//
//    1. auth config — the per-toolkit blueprint. Created once with Composio's
//       managed OAuth app so the user never registers a Google Cloud project,
//       then cached: creating a second one for the same toolkit would orphan
//       the accounts connected through the first.
//    2. connection link — `connected_accounts/link` returns the
//       `redirect_url` the user approves in their own browser. The older
//       `connected_accounts` endpoint refuses Composio-managed OAuth outright
//       ("no longer supported"), which is what it told us on the first live
//       call, so this is not a preference — it is the only route.
//    3. status poll — INITIATED until the user finishes, then ACTIVE.
//
//  There is deliberately no `callback_url`. A custom scheme is not a URL
//  Composio is guaranteed to accept as a redirect target, and polling a
//  status the user can see failing is more honest than a deep link that
//  silently never fires. The link response carries no status field either,
//  so the first real answer comes from the first poll.
//
//  Tools follow automatically: the Tool Router session in `ComposioSession`
//  is scoped to the same user id, so a toolkit connected here shows up in
//  that one MCP process without a second server per service.
//

import Foundation

// MARK: - Errors

enum ComposioAuthError: LocalizedError {
    case notConfigured
    case unsupportedToolkit(String)
    case rejected(status: Int, message: String)
    case malformedResponse(String)
    case transport(String)
    case connectionFailed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add your Composio API key in Settings → Composio first. The free tier is enough."
        case .unsupportedToolkit(let name):
            return "\(name) has no Composio toolkit mapped yet."
        case .rejected(let status, let message):
            return "Composio refused the request (\(status)): \(message)"
        case .malformedResponse(let detail):
            return "Composio returned an unexpected response: \(detail)"
        case .transport(let detail):
            return "Could not reach Composio: \(detail)"
        case .connectionFailed(let status):
            return "The sign-in did not complete (\(status)). Try connecting again."
        case .timedOut(let name):
            return "Still waiting for \(name) in your browser. Connect again once you have finished."
        }
    }
}

// MARK: - Wire results

struct ComposioConnectionRequest: Equatable, Sendable {
    let connectedAccountID: String
    /// Nil for auth schemes that need no browser step at all.
    let redirectURL: URL?
    let status: String
}

struct ComposioConnectedAccountSummary: Equatable, Sendable {
    let connectedAccountID: String
    let toolkitSlug: String
    let displayName: String
}

// MARK: - Broker

/// All Composio HTTP that is about *authorising an app*, as opposed to
/// running its tools. Kept separate from `ComposioProvisioner` because these
/// two talk to different halves of the API and fail for different reasons.
struct ComposioAuthBroker: Sendable {

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let apiBaseURL = URL(string: "https://backend.composio.dev/api/v3.1")!

    /// Terminal states. Anything else means the user is still in the browser.
    static let activeStatus = "ACTIVE"
    static let failureStatuses: Set<String> = ["FAILED", "EXPIRED", "DELETED"]

    let transport: Transport

    init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.transport = transport
    }

    // MARK: Request building

    /// Built separately from being sent so the shape — the part that rots
    /// silently when an API moves — can be asserted without an account.
    static func makeAuthConfigRequest(apiKey: String, toolkitSlug: String) throws -> URLRequest {
        var request = signedRequest(path: "auth_configs", apiKey: apiKey)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "toolkit": ["slug": toolkitSlug],
            // Composio's own OAuth app. The alternative is asking the user to
            // register a Google Cloud project per service, which is the exact
            // friction this connector exists to remove.
            "auth_config": ["type": "use_composio_managed_auth"]
        ])
        return request
    }

    static func makeConnectionRequest(
        apiKey: String,
        authConfigID: String,
        userID: String
    ) throws -> URLRequest {
        // Flat keys, not the nested `auth_config` / `connection` objects the
        // create endpoint takes. Verified against the live API.
        var request = signedRequest(path: "connected_accounts/link", apiKey: apiKey)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "auth_config_id": authConfigID,
            "user_id": userID
        ])
        return request
    }

    static func makeStatusRequest(apiKey: String, connectedAccountID: String) -> URLRequest {
        var request = signedRequest(path: "connected_accounts/\(connectedAccountID)", apiKey: apiKey)
        request.httpMethod = "GET"
        return request
    }

    static func makeDisconnectRequest(apiKey: String, connectedAccountID: String) -> URLRequest {
        var request = signedRequest(path: "connected_accounts/\(connectedAccountID)", apiKey: apiKey)
        request.httpMethod = "DELETE"
        return request
    }

    static func makeActiveConnectionsRequest(apiKey: String, userID: String) -> URLRequest {
        var components = URLComponents(
            url: apiBaseURL.appendingPathComponent("connected_accounts"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "user_ids", value: userID),
            URLQueryItem(name: "statuses", value: activeStatus),
            URLQueryItem(name: "limit", value: "100")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    private static func signedRequest(path: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent(path))
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    // MARK: Response parsing

    /// The id lives under `auth_config` on create and at the root on list, so
    /// both shapes are accepted rather than guessing which version answered.
    static func parseAuthConfigID(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ComposioAuthError.malformedResponse("not an object")
        }
        if let nested = root["auth_config"] as? [String: Any], let id = nested["id"] as? String {
            return id
        }
        if let id = root["id"] as? String { return id }
        throw ComposioAuthError.malformedResponse("no auth config id")
    }

    static func parseConnectionRequest(from data: Data) throws -> ComposioConnectionRequest {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ComposioAuthError.malformedResponse("not an object")
        }
        guard let identifier = (root["id"] as? String) ?? (root["connected_account_id"] as? String) else {
            throw ComposioAuthError.malformedResponse("no connected account id")
        }
        let redirect = (root["redirect_url"] as? String) ?? (root["redirectUrl"] as? String)
        return ComposioConnectionRequest(
            connectedAccountID: identifier,
            redirectURL: redirect.flatMap(URL.init(string:)),
            status: (root["status"] as? String) ?? "INITIATED"
        )
    }

    static func parseStatus(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["status"] as? String else {
            throw ComposioAuthError.malformedResponse("no status")
        }
        return status
    }

    static func parseActiveConnections(from data: Data) throws -> [ComposioConnectedAccountSummary] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            throw ComposioAuthError.malformedResponse("no connected-account list")
        }
        return items.compactMap { item in
            guard item["status"] as? String == activeStatus,
                  let identifier = item["id"] as? String,
                  let toolkit = item["toolkit"] as? [String: Any],
                  let slug = toolkit["slug"] as? String else { return nil }
            let name = (toolkit["name"] as? String) ?? slug
            return ComposioConnectedAccountSummary(
                connectedAccountID: identifier,
                toolkitSlug: slug,
                displayName: name
            )
        }
    }

    // MARK: Calls

    func createAuthConfig(apiKey: String, toolkitSlug: String) async throws -> String {
        let data = try await send(try Self.makeAuthConfigRequest(apiKey: apiKey, toolkitSlug: toolkitSlug))
        return try Self.parseAuthConfigID(from: data)
    }

    func initiateConnection(
        apiKey: String,
        authConfigID: String,
        userID: String
    ) async throws -> ComposioConnectionRequest {
        let data = try await send(
            try Self.makeConnectionRequest(apiKey: apiKey, authConfigID: authConfigID, userID: userID)
        )
        return try Self.parseConnectionRequest(from: data)
    }

    func connectionStatus(apiKey: String, connectedAccountID: String) async throws -> String {
        let data = try await send(Self.makeStatusRequest(apiKey: apiKey, connectedAccountID: connectedAccountID))
        return try Self.parseStatus(from: data)
    }

    func disconnect(apiKey: String, connectedAccountID: String) async throws {
        _ = try await send(Self.makeDisconnectRequest(apiKey: apiKey, connectedAccountID: connectedAccountID))
    }

    func activeConnections(apiKey: String, userID: String) async throws -> [ComposioConnectedAccountSummary] {
        let data = try await send(Self.makeActiveConnectionsRequest(apiKey: apiKey, userID: userID))
        return try Self.parseActiveConnections(from: data)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw ComposioAuthError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ComposioAuthError.rejected(
                status: http.statusCode,
                message: ComposioProvisioner.errorMessage(from: data)
            )
        }
        return data
    }
}

// MARK: - Auth config cache

/// One auth config per toolkit, remembered forever. Re-creating one would
/// leave every account already connected through the old config unreachable,
/// which looks exactly like "the connector randomly signed itself out".
enum ComposioAuthConfigCache {

    private static let storageKey = "composioAuthConfigIDsByToolkit"

    static func identifier(forToolkit slug: String, userDefaults: UserDefaults = .standard) -> String? {
        stored(userDefaults: userDefaults)[slug]
    }

    static func store(_ identifier: String, forToolkit slug: String, userDefaults: UserDefaults = .standard) {
        var table = stored(userDefaults: userDefaults)
        table[slug] = identifier
        userDefaults.set(table, forKey: storageKey)
    }

    static func clear(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: storageKey)
    }

    private static func stored(userDefaults: UserDefaults) -> [String: String] {
        userDefaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
}
