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

    /// Builds an authorized request. Token comes from Info.plist key
    /// HeyMateClientToken (dev convenience); production builds should inject
    /// a per-user session token instead of shipping one.
    static func makeRequest(
        endpoint: BackendEndpoint,
        bundle: Bundle = .main,
        body: Data? = nil
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

        if let token = AppBundleConfiguration.stringValue(forKey: "HeyMateClientToken"), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
