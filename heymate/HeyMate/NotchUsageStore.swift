// Provider response mappings adapted from vinzdg/codenotch (MIT, copyright 2026 Vinz).
// See Codenotch-LICENSE.txt. Credentials stay local and go only to their owning provider.
import Foundation
import Combine
import Security
import SQLite3

/// A usage source the user added themselves: any HTTPS (or localhost) JSON endpoint.
/// The token lives in the Keychain, never in preferences.
nonisolated struct NotchCustomProviderSpec: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
    var glyph: String = "generic"
    var headerName: String = "Authorization"
    /// Dot path to a 0–100 number, e.g. `data.usage.percent`. Or leave empty and use used/limit.
    var percentPath: String = ""
    var usedPath: String = ""
    var limitPath: String = ""
    var resetPath: String = ""

    var endpoint: URL? {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
              components.user == nil, components.password == nil else { return nil }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        return components.url
    }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && endpoint != nil
            && (!percentPath.isEmpty || (!usedPath.isEmpty && !limitPath.isEmpty))
    }
}

nonisolated enum NotchCustomProviderRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var specs: [String: NotchCustomProviderSpec] = [:]
    static func set(_ list: [NotchCustomProviderSpec]) {
        lock.lock(); defer { lock.unlock() }
        specs = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }
    static func spec(_ id: String) -> NotchCustomProviderSpec? {
        lock.lock(); defer { lock.unlock() }
        return specs[id]
    }
}

nonisolated struct NotchUsageProvider: Hashable, Identifiable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let codex = NotchUsageProvider(rawValue: "codex")
    static let claude = NotchUsageProvider(rawValue: "claude")
    static let cursor = NotchUsageProvider(rawValue: "cursor")
    /// The providers HeyMate reads natively. Custom ones come from the store.
    static var allCases: [NotchUsageProvider] { [.codex, .claude, .cursor] }
    var id: String { rawValue }
    var isBuiltIn: Bool { Self.allCases.contains(self) }
    var spec: NotchCustomProviderSpec? { NotchCustomProviderRegistry.spec(rawValue) }
    var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        default: return spec?.name ?? "Custom"
        }
    }
    var initials: String {
        switch self {
        case .codex: return "CX"
        case .claude: return "CL"
        case .cursor: return "CU"
        default: return String(name.prefix(2)).uppercased()
        }
    }
    var glyphKey: String {
        switch self {
        case .codex: return "openai"
        case .claude: return "claude"
        case .cursor: return "cursor"
        default: return spec?.glyph ?? "generic"
        }
    }
}

nonisolated struct NotchUsageWindow: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
    var fraction: Double { min(1, max(0, usedPercent / 100)) }
    func hasReset(at date: Date) -> Bool { resetsAt.map { $0 <= date } ?? false }
}

nonisolated struct NotchUsageReading: Codable {
    let windows: [NotchUsageWindow]
    let fetchedAt: Date
    func isStale(at date: Date) -> Bool { date.timeIntervalSince(fetchedAt) > 300 || windows.contains { $0.hasReset(at: date) } }
}

nonisolated enum NotchUsageFailure: Error {
    case signIn, keychainAccess, unavailable, rateLimited(TimeInterval)
}

/// Never substitutes zero for missing fields or a changed provider response.
nonisolated enum NotchUsageParser {
    static func parse(_ data: Data, provider: NotchUsageProvider) throws -> [NotchUsageWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotchUsageFailure.unavailable }
        var windows: [NotchUsageWindow] = []
        func add(_ id: String, _ title: String, percent: Any?, reset: Any?) {
            guard let number = percent as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...100_000).contains(number.doubleValue) else { return }
            windows.append(NotchUsageWindow(id: id, title: title, usedPercent: number.doubleValue, resetsAt: date(reset)))
        }
        if let spec = provider.spec {
            let found = try parseCustom(root, spec: spec)
            return found
        }
        switch provider {
        case .codex:
            let limits = root["rate_limit"] as? [String: Any] ?? [:]
            for (id, title) in [("primary_window", "Session"), ("secondary_window", "Weekly")] {
                if let window = limits[id] as? [String: Any] {
                    add(id, title, percent: window["used_percent"], reset: window["reset_at"])
                }
            }
        case .claude:
            for (id, title) in [("five_hour", "5 hours"), ("seven_day", "Weekly"), ("seven_day_sonnet", "Sonnet weekly")] {
                if let window = root[id] as? [String: Any] {
                    add(id, title, percent: window["utilization"], reset: window["resets_at"])
                }
            }
        default:
            let usage = root["individualUsage"] as? [String: Any] ?? [:]
            let plan = usage["plan"] as? [String: Any] ?? [:]
            add("auto", "Auto", percent: plan["autoPercentUsed"], reset: root["billingCycleEnd"])
            add("api", "API", percent: plan["apiPercentUsed"], reset: root["billingCycleEnd"])
            if windows.isEmpty, let overall = usage["overall"] as? [String: Any],
               let used = overall["used"] as? Double, let limit = overall["limit"] as? Double, limit > 0 {
                add("included", "Included", percent: used / limit * 100, reset: root["billingCycleEnd"])
            }
        }
        guard !windows.isEmpty else { throw NotchUsageFailure.unavailable }
        return windows
    }
    static func value(at path: String, in root: Any) -> Any? {
        var current: Any? = root
        for part in path.split(separator: ".").map(String.init) {
            if let object = current as? [String: Any] { current = object[part] }
            else if let list = current as? [Any], let index = Int(part), list.indices.contains(index) { current = list[index] }
            else { return nil }
        }
        return current
    }
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    static func parseCustom(_ root: [String: Any], spec: NotchCustomProviderSpec) throws -> [NotchUsageWindow] {
        var percent = spec.percentPath.isEmpty ? nil : number(value(at: spec.percentPath, in: root))
        if percent == nil, !spec.usedPath.isEmpty, !spec.limitPath.isEmpty,
           let used = number(value(at: spec.usedPath, in: root)),
           let limit = number(value(at: spec.limitPath, in: root)), limit > 0 { percent = used / limit * 100 }
        guard let percent, percent.isFinite, (0...100_000).contains(percent) else { throw NotchUsageFailure.unavailable }
        let reset = spec.resetPath.isEmpty ? nil : date(value(at: spec.resetPath, in: root))
        return [NotchUsageWindow(id: "usage", title: "Usage", usedPercent: percent, resetsAt: reset)]
    }
    static func date(_ value: Any?) -> Date? {
        if let epoch = value as? Double, epoch.isFinite, epoch > 0 {
            return Date(timeIntervalSince1970: epoch > 1e11 ? epoch / 1000 : epoch)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Refuse redirects so a provider session can never follow a redirect to another host.
nonisolated final class NotchUsageRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class NotchUsageStore: ObservableObject {
    static let shared = NotchUsageStore()
    private static let enabledKey = "heymate.notch.usageProviders.v1"
    private static let customKey = "heymate.notch.customUsageProviders.v1"
    @Published private(set) var enabled: Set<NotchUsageProvider> = []
    @Published private(set) var customProviders: [NotchCustomProviderSpec] = []
    /// Native providers first, then the ones the user added.
    var providers: [NotchUsageProvider] { NotchUsageProvider.allCases + customProviders.map { NotchUsageProvider(rawValue: $0.id) } }
    @Published private(set) var readings: [NotchUsageProvider: NotchUsageReading] = [:]
    @Published private(set) var status: [NotchUsageProvider: String] = [:]
    @Published private(set) var refreshing: Set<NotchUsageProvider> = []
    private var tasks: [NotchUsageProvider: Task<Void, Never>] = [:]
    private var generations: [NotchUsageProvider: UUID] = [:]
    private var timer: Timer?
    private let defaults: UserDefaults
    private let client: URLSession

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        client = URLSession(configuration: configuration, delegate: NotchUsageRedirectGuard(), delegateQueue: nil)
        if let data = defaults.data(forKey: Self.customKey),
           let list = try? JSONDecoder().decode([NotchCustomProviderSpec].self, from: data) {
            customProviders = list.filter(\.isValid)
        }
        NotchCustomProviderRegistry.set(customProviders)
        let known = Set(providers)
        enabled = Set((defaults.stringArray(forKey: Self.enabledKey) ?? []).map(NotchUsageProvider.init(rawValue:)).filter(known.contains))
        for provider in enabled {
            if let data = defaults.data(forKey: "heymate.notch.usage.\(provider.rawValue)"),
               let reading = try? JSONDecoder().decode(NotchUsageReading.self, from: data) { readings[provider] = reading }
        }
    }
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll(); generations.removeAll(); refreshing.removeAll()
    }
    func setEnabled(_ value: Bool, provider: NotchUsageProvider) {
        if value {
            enabled.insert(provider)
            refresh(provider, interactive: true)
        } else {
            enabled.remove(provider)
            generations[provider] = UUID()
            tasks.removeValue(forKey: provider)?.cancel()
            refreshing.remove(provider)
            readings.removeValue(forKey: provider)
            status.removeValue(forKey: provider)
            defaults.removeObject(forKey: "heymate.notch.usage.\(provider.rawValue)")
        }
        defaults.set(enabled.map(\.rawValue), forKey: Self.enabledKey)
    }
    func addCustom(_ spec: NotchCustomProviderSpec, token: String) {
        guard spec.isValid else { return }
        if let index = customProviders.firstIndex(where: { $0.id == spec.id }) { customProviders[index] = spec }
        else { customProviders.append(spec) }
        NotchCustomProviderRegistry.set(customProviders)
        NotchCustomToken.save(token, id: spec.id)
        persistCustom()
        let provider = NotchUsageProvider(rawValue: spec.id)
        defaults.removeObject(forKey: "heymate.notch.usageRetry.\(spec.id)")
        if enabled.contains(provider) { tasks.removeValue(forKey: provider)?.cancel(); refresh(provider) }
        else { setEnabled(true, provider: provider) }
    }
    func removeCustom(id: String) {
        let provider = NotchUsageProvider(rawValue: id)
        setEnabled(false, provider: provider)
        customProviders.removeAll { $0.id == id }
        NotchCustomProviderRegistry.set(customProviders)
        NotchCustomToken.delete(id: id)
        persistCustom()
    }
    private func persistCustom() {
        if let data = try? JSONEncoder().encode(customProviders) { defaults.set(data, forKey: Self.customKey) }
    }
    func refresh() { for provider in enabled { refresh(provider) } }
    func refresh(_ provider: NotchUsageProvider, interactive: Bool = false) {
        guard enabled.contains(provider), tasks[provider] == nil else { return }
        let retryKey = "heymate.notch.usageRetry.\(provider.rawValue)"
        if defaults.double(forKey: retryKey) > Date().timeIntervalSince1970 {
            status[provider] = "Rate limited — waiting to retry"
            return
        }
        let generation = UUID()
        generations[provider] = generation
        refreshing.insert(provider)
        tasks[provider] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generations[provider] == generation {
                    self.tasks[provider] = nil
                    self.refreshing.remove(provider)
                }
            }
            do {
                let request = try Self.request(provider, interactive: interactive)
                let (data, response) = try await self.client.data(for: request)
                try Task.checkCancellation()
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                if code == 401 || code == 403 { throw NotchUsageFailure.signIn }
                if code == 429 {
                    let delay = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300
                    throw NotchUsageFailure.rateLimited(max(120, delay))
                }
                guard (200..<300).contains(code) else { throw NotchUsageFailure.unavailable }
                let reading = NotchUsageReading(windows: try NotchUsageParser.parse(data, provider: provider), fetchedAt: Date())
                guard self.enabled.contains(provider), self.generations[provider] == generation else { return }
                self.readings[provider] = reading
                self.status[provider] = nil
                self.defaults.set(try JSONEncoder().encode(reading), forKey: "heymate.notch.usage.\(provider.rawValue)")
            } catch is CancellationError { return }
            catch {
                guard self.enabled.contains(provider), self.generations[provider] == generation else { return }
                switch error {
                case NotchUsageFailure.signIn:
                    self.readings[provider] = nil
                    self.defaults.removeObject(forKey: "heymate.notch.usage.\(provider.rawValue)")
                    self.status[provider] = "Sign in to \(provider.name)"
                case NotchUsageFailure.keychainAccess: self.status[provider] = "Allow Keychain access to read usage"
                case NotchUsageFailure.rateLimited(let delay):
                    self.defaults.set(Date().addingTimeInterval(delay).timeIntervalSince1970, forKey: retryKey)
                    self.status[provider] = "Rate limited — waiting to retry"
                default: self.status[provider] = "Usage unavailable"
                }
            }
        }
    }

    private static func request(_ provider: NotchUsageProvider, interactive: Bool) throws -> URLRequest {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var request: URLRequest
        if let spec = provider.spec {
            guard let url = spec.endpoint else { throw NotchUsageFailure.unavailable }
            request = URLRequest(url: url)
            if let token = NotchCustomToken.load(id: spec.id), !token.isEmpty {
                let header = spec.headerName.trimmingCharacters(in: .whitespaces)
                let name = header.isEmpty ? "Authorization" : header
                let bearer = name.lowercased() == "authorization" && !token.lowercased().hasPrefix("bearer ")
                request.setValue(bearer ? "Bearer \(token)" : token, forHTTPHeaderField: name)
            }
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        }
        switch provider {
        case .codex:
            let root = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            guard let data = try? Data(contentsOf: root.appendingPathComponent("auth.json")),
                  let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = auth["tokens"] as? [String: Any],
                  let token = tokens["access_token"] as? String, !token.isEmpty else { throw NotchUsageFailure.signIn }
            request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let id = tokens["account_id"] as? String { request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        case .claude:
            var result: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Claude Code-credentials", kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                throw status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled
                    ? NotchUsageFailure.keychainAccess : NotchUsageFailure.signIn
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else { throw NotchUsageFailure.signIn }
            request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        default:
            let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
            var database: OpaquePointer?
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                if let database { sqlite3_close(database) }
                throw NotchUsageFailure.signIn
            }
            defer { sqlite3_close(database) }
            func value(_ key: String) -> String? {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(statement) }
                return key.withCString { pointer in
                    sqlite3_bind_text(statement, 1, pointer, -1, nil)
                    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
                    return String(cString: text)
                }
            }
            guard let token = value("cursorAuth/accessToken"), !token.isEmpty else { throw NotchUsageFailure.signIn }
            var account = value("cursorAuth/stripeMembershipAuthId")
            if account?.isEmpty != false {
                let parts = token.split(separator: ".")
                if parts.count == 3 {
                    var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    body += String(repeating: "=", count: (4 - body.count % 4) % 4)
                    if let data = Data(base64Encoded: body), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        account = claims["sub"] as? String
                    }
                }
            }
            guard let account, !account.isEmpty else { throw NotchUsageFailure.signIn }
            request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
            request.setValue("WorkosCursorSessionToken=\(account)::\(token)", forHTTPHeaderField: "Cookie")
        }
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// Tokens for custom usage sources. Keychain only; never preferences, logs or analytics.
nonisolated enum NotchCustomToken {
    private static let service = "HeyMate Notch Usage"
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    static func save(_ token: String, id: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, load(id: id) != nil { return }   // keep the saved token when the field is left blank
        delete(id: id)
        guard !trimmed.isEmpty else { return }
        var item = query(id)
        item[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
    static func load(id: String) -> String? {
        var item = query(id)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(id: String) { SecItemDelete(query(id) as CFDictionary) }
}
