//
//  BackendClient.swift
//  leanring-buddy
//
//  Client surface for the HeyMate Worker's /v1/* endpoints (see
//  worker/src/index.ts). Deliberately NOT wired into the live Talk pipeline
//  yet: the app keeps working against the legacy proxy routes until an
//  actual deployment exists. Cut over by pointing WorkerBaseURL routes here
//  once HEYMATE_CLIENT_TOKEN auth is live.
//

import Foundation

enum BackendEndpoint {
    case chatStream
    case ttsStream
    case sttSessionToken
    case me
    case usage

    var path: String {
        switch self {
        case .chatStream: return "/v1/chat/stream"
        case .ttsStream: return "/v1/tts/stream"
        case .sttSessionToken: return "/v1/stt/session-token"
        case .me: return "/v1/me"
        case .usage: return "/v1/usage"
        }
    }

    var method: String {
        switch self {
        case .me, .usage: return "GET"
        default: return "POST"
        }
    }
}

nonisolated enum BackendClient {

    /// Base URL from the bundle's Info.plist (key: HeyMateBackendURL).
    /// Falls back to the same placeholder as WorkerBaseURL so nothing
    /// silently points at a real host before configuration.
    static func baseURL(bundle: Bundle = .main) -> URL? {
        let raw = AppBundleConfiguration.stringValue(forKey: "HeyMateBackendURL")
            ?? "https://your-worker-name.your-subdomain.workers.dev"
        return URL(string: raw)
    }

    static let clientTokenSecretsKey = "HEYMATE_CLIENT_TOKEN"

    /// Adds the Worker client token without putting it in the app bundle or
    /// process arguments. An absent token deliberately leaves the header off;
    /// a securely configured Worker then rejects the request.
    static func applyAuthorization(
        to request: inout URLRequest,
        clientToken: String? = HeyMateSecrets.lookup(clientTokenSecretsKey)
    ) {
        guard let clientToken = clientToken?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !clientToken.isEmpty else { return }
        request.setValue("Bearer \(clientToken)", forHTTPHeaderField: "Authorization")
    }

    /// Builds an authorized request. The token resolves from the process
    /// environment or the local HeyMate secrets file, never Info.plist.
    static func makeRequest(
        endpoint: BackendEndpoint,
        bundle: Bundle = .main,
        body: Data? = nil,
        clientToken: String? = HeyMateSecrets.lookup(clientTokenSecretsKey)
    ) -> URLRequest? {
        guard let base = baseURL(bundle: bundle),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = endpoint.path
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.httpBody = body

        applyAuthorization(to: &request, clientToken: clientToken)
        return request
    }
}
