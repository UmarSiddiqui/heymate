import Foundation
import Security

/// Provider I/O boundary. Invoked in a detached, cancellation-linked task;
/// no keychain prompts, subprocess sign-ins, token renewal or helper servers.
nonisolated enum NotchCodenotchReader {
    static func fetch(_ provider: NotchUsageProvider, client: URLSession) async throws -> NotchUsageReading {
        if provider == .gemini {
            return try CNReadBudget.scan {
                let sources: [(String, CNGeminiTokenUsage?)] = [
                    ("Gemini CLI", CNGeminiCLIUsage.read()),
                    ("OpenCode", CNOpenCodeGeminiUsage.read(database: CNOpenCodeCredentials.databaseURL)),
                    ("Hermes", CNHermesGeminiUsage.read())
                ]
                let found = sources.compactMap { name, usage -> NotchUsageWindow? in
                    guard let usage else { return nil }
                    return .init(id: name, title: "\(name) · month", usedPercent: nil, resetsAt: nil,
                                 valueText: "\(usage.tokensThisMonth.formatted()) tokens", fidelity: .derived)
                }
                guard !found.isEmpty else { throw NotchUsageFailure.guidance("No Gemini usage logs found") }
                let total = sources.compactMap(\.1).reduce(CNGeminiTokenUsage.zero) { $0.adding($1) }
                return .init(windows: [
                    .init(id: "today", title: "Today · local logs", usedPercent: nil, resetsAt: nil,
                          valueText: "\(total.tokensToday.formatted()) tokens", fidelity: .derived)
                ] + found, fetchedAt: Date())
            }
        }
        if provider == .antigravity {
            // Scope both discovery and self-signed TLS exception to this fetch.
            // Never call upstream Owned.endpointOrStart or renew credentials.
            let endpoint = CNAntigravityBridge.discover()
            if let endpoint {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.urlCache = nil
                configuration.connectionProxyDictionary = [:]
                let local = URLSession(configuration: configuration,
                    delegate: NotchAntigravityTransport(ports: Set(endpoint.ports)), delegateQueue: nil)
                defer { local.invalidateAndCancel() }
                do {
                    let windows = try await CNAntigravityBridge.quota(from: endpoint, session: local)
                    try Task.checkCancellation()
                    if !windows.isEmpty { return try reading(windows) }
                } catch {
                    try Task.checkCancellation()
                    if case CNUsageProviderError.rateLimited = error { throw error }
                    // Local counts remain useful when the running server cannot
                    // supply quota. Their labels explicitly carry no denominator.
                }
            }
            return try CNReadBudget.scan {
                let roots = CNAntigravityActivity.transcriptRoots
                guard !roots.isEmpty else {
                    throw NotchUsageFailure.guidance("Open Antigravity to read quota or local activity")
                }
                let activity = CNAntigravityActivity.read(roots: roots)
                return .init(windows: [.init(id: "requests", title: "Today · quota unavailable", usedPercent: nil,
                    resetsAt: nil, valueText: "\(activity.requestsToday) requests", fidelity: .derived)], fetchedAt: Date())
            }
        }
        if provider == .ollama || provider == .lmstudio {
            let url = URL(string: provider == .ollama ? "http://127.0.0.1:11434/api/ps" : "http://127.0.0.1:1234/api/v1/models")!
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.connectionProxyDictionary = [:]
            let local = URLSession(configuration: configuration, delegate: NotchUsageRedirectGuard(), delegateQueue: nil)
            defer { local.invalidateAndCancel() }
            let data = try await response(URLRequest(url: url), client: local)
            let runtime = try provider == .ollama ? CNOllamaLocalUsage.parse(data) : CNLMStudioUsage.parse(data)
            // Model names/details remain in memory. Persisted cache contains only
            // count metrics and quota windows, never projects or session contents.
            return .init(windows: [.init(id: "loaded", title: "Local runtime", usedPercent: nil, resetsAt: nil,
                valueText: "\(runtime.models.count) models loaded")], fetchedAt: Date(),
                runtimeDetails: runtime.models.prefix(12).map { "\($0.name) · \($0.detail)" })
        }
        let urlRequest: URLRequest = try CNReadBudget.scan { try request(provider) }
        let data = try await response(urlRequest, client: client)
        let text = String(decoding: data, as: UTF8.self)
        let windows: [CNLimitWindow]
        switch provider {
        case .opencode: windows = try CNOpenCodeUsage.windows(fromJSON: text)
        case .copilot: windows = try CNGitHubCopilotUsage.windows(from: data)
        case .kimi: windows = try CNKimiUsage.read(fromJSON: text).windows
        case .grok: windows = try CNGrokUsage.windows(creditsJSON: text)
        case .glm: windows = try CNGLMUsage.parse(data).windows
        default: throw NotchUsageFailure.unavailable
        }
        return try reading(windows)
    }

    static func reading(_ windows: [CNLimitWindow], now: Date = Date()) throws -> NotchUsageReading {
        let mapped = windows.compactMap { window -> NotchUsageWindow? in
            if let fraction = window.usedFraction {
                guard fraction.isFinite, (0...1000).contains(fraction) else { return nil }
            } else if window.used == nil && window.remaining == nil && window.usedText == nil { return nil }
            return .init(id: window.group.map { "\($0)::\(window.id)" } ?? window.id, title: [window.group, window.label].compactMap { $0 }.joined(separator: " · "),
                usedPercent: window.usedFraction.map { $0 * 100 }, resetsAt: window.resetsAt,
                valueText: window.usedFraction == nil ? window.summary : nil, group: window.group, duration: window.duration)
        }
        guard !mapped.isEmpty else { throw NotchUsageFailure.unavailable }
        return .init(windows: mapped, fetchedAt: now)
    }

    // From OpenCodeProvider.endpoint(for:): credentials determine the route.
    static func openCodeEndpoint(_ credential: CNOpenCodeCredentials.Credential) -> URL {
        credential.oauth ? CNOpenCodeUsage.oauthEndpoint : CNOpenCodeUsage.endpoint
    }

    static func request(_ provider: NotchUsageProvider) throws -> URLRequest {
        var result: URLRequest
        var token: String
        switch provider {
        case .opencode:
            guard let credential = CNOpenCodeCredentials.load() else { throw NotchUsageFailure.signIn }
            guard credential.expires.map({ $0 > Date() }) ?? true else { throw NotchUsageFailure.expired }
            // Metadata.server never controls where a borrowed token is sent.
            guard credential.console.map({ $0.scheme == "https" && $0.host == "opencode.ai" && $0.user == nil && $0.password == nil }) ?? true else {
                throw NotchUsageFailure.guidance("Custom OpenCode consoles require a custom source")
            }
            result = URLRequest(url: openCodeEndpoint(credential))
            token = credential.token
            if credential.oauth, let org = credential.org { result.setValue(org, forHTTPHeaderField: "x-opencode-org-id") }
        case .copilot:
            token = try CNGitHubCopilotCredentials.load().token
            result = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
            result.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            result.setValue("HeyMate", forHTTPHeaderField: "User-Agent")
        case .kimi:
            let credential = try CNKimiCredentials.load()
            guard !credential.isExpired else { throw NotchUsageFailure.expired }
            token = credential.accessToken
            result = URLRequest(url: CNKimiUsage.endpoint)
        case .grok:
            let credential = try CNGrokCredentials.load()
            guard !credential.isExpired else { throw NotchUsageFailure.expired }
            token = credential.accessToken
            result = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        case .glm:
            guard let credential = CNGLMCredentials.load() else { throw NotchUsageFailure.signIn }
            guard ["api.z.ai", "open.bigmodel.cn"].contains(credential.baseURL.host ?? "") else { throw NotchUsageFailure.unavailable }
            token = credential.token
            result = URLRequest(url: credential.baseURL.appendingPathComponent("api/monitor/usage/quota/limit"))
        default: throw NotchUsageFailure.unavailable
        }
        result.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        return result
    }

    static func response(_ original: URLRequest, client: URLSession) async throws -> Data {
        var request = original
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await client.data(for: request)
        try Task.checkCancellation()
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 401, 403: throw NotchUsageFailure.signIn
        case 429: throw NotchUsageFailure.rateLimited(retryAfter(http))
        case 200..<300: break
        default: throw NotchUsageFailure.unavailable
        }
        guard data.count <= 4 * 1024 * 1024 else { throw NotchUsageFailure.unavailable }
        return data
    }

    static func retryAfter(_ response: HTTPURLResponse?, now: Date = Date()) -> TimeInterval {
        let header = response?.value(forHTTPHeaderField: "Retry-After") ?? ""
        if let value = Double(header), value.isFinite { return max(120, value) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return max(120, formatter.date(from: header)?.timeIntervalSince(now) ?? 300)
    }
}

/// Only this discovered loopback server gets a self-signed certificate exception.
/// Redirects never get a credential. Proxy settings are disabled for local RPCs.
nonisolated final class NotchAntigravityTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let ports: Set<Int>
    init(ports: Set<Int>) { self.ports = ports }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == "127.0.0.1", ports.contains(space.port), let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
