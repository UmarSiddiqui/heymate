import Foundation
import Combine

/// Hermes owns OAuth and its tokens. HeyMate displays only the one-time code and
/// opens the provider page after a separate user action.
@MainActor
final class HermesSubscriptionLoginController: ObservableObject {
    enum State: Equatable { case idle, starting, awaitingApproval, connected, expired, denied, cancelled, failed }
    typealias Request = @MainActor (String, String, Duration) async throws -> JSONValue
    @Published private(set) var state: State = .idle
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var userCode: String?
    @Published private(set) var verificationURL: URL?
    private let prepare: @MainActor (HermesEngineConfiguration) async throws -> Void
    private let request: Request
    private let sleep: @MainActor (Duration) async throws -> Void
    private var generation = UUID()
    private var sessionID: String?
    private var pollTask: Task<Void, Never>?

    init(prepare: (@MainActor (HermesEngineConfiguration) async throws -> Void)? = nil,
         request: Request? = nil,
         sleep: (@MainActor (Duration) async throws -> Void)? = nil) {
        self.prepare = prepare ?? { configuration in
            let launch = try configuration.resolveLaunchConfiguration()
            let backend = HermesServeBackend.shared
            do { _ = try await backend.start(configuration: launch) }
            catch HermesServeBackend.Failure.alreadyRunningDifferentProfile {
                guard await backend.shutdown() else { throw HermesServeBackend.Failure.notRunning }
                _ = try await backend.start(configuration: launch)
            }
        }
        self.request = request ?? { path, method, timeout in
            try await HermesServeBackend.shared.requestHTTP(path: path, method: method, timeout: timeout)
        }
        self.sleep = sleep ?? { try await ContinuousClock().sleep(for: $0) }
    }

    func start(_ configuration: HermesEngineConfiguration) async {
        guard !busy else { return }
        let owned = UUID()
        generation = owned
        busy = true; state = .starting
        status = "Requesting a ChatGPT sign-in code…"
        userCode = nil; verificationURL = nil
        do {
            try await prepare(configuration)
            guard generation == owned else { return }
            let result = try await request("/api/providers/oauth/openai-codex/start", "POST", .seconds(20))
            // Even a closed view must cancel a start response that arrived late.
            guard case .object(let fields) = result,
                  case .string(let id) = fields["session_id"], Self.validSessionID(id) else { throw LoginFailure.invalidResponse }
            guard generation == owned else {
                _ = try? await request("/api/providers/oauth/sessions/" + id, "DELETE", .seconds(10))
                return
            }
            sessionID = id
            guard fields["flow"] == .string("device_code"),
                  case .string(let code) = fields["user_code"], code.range(of: #"^[A-Za-z0-9-]{3,64}$"#, options: .regularExpression) != nil,
                  case .string(let address) = fields["verification_url"], let url = Self.officialURL(address),
                  let expires = Self.integer(fields["expires_in"], range: 1...900),
                  let interval = Self.integer(fields["poll_interval"], range: 3...30) else { throw LoginFailure.invalidResponse }
            userCode = code; verificationURL = url
            state = .awaitingApproval
            status = "Open OpenAI sign-in, enter this code, then return here."
            pollTask = Task { [weak self] in
                guard let self else { return }
                await self.poll(id: id, generation: owned, expires: expires, interval: interval)
            }
        } catch {
            guard generation == owned else { return }
            if let id = sessionID { _ = try? await request("/api/providers/oauth/sessions/" + id, "DELETE", .seconds(10)) }
            sessionID = nil; busy = false; state = .failed
            userCode = nil; verificationURL = nil
            // Provider errors and status cards can contain credential fragments.
            status = "ChatGPT sign-in could not start. Check your connection and OpenAI account’s device-code authorization setting, then try again."
        }
    }

    private func poll(id: String, generation owned: UUID, expires: Int, interval: Int) async {
        let deadline = ContinuousClock.now + .seconds(expires)
        do {
            while generation == owned && ContinuousClock.now < deadline {
                try await sleep(.seconds(interval))
                try Task.checkCancellation()
                guard generation == owned else { return }
                let response = try await request("/api/providers/oauth/openai-codex/poll/" + id, "GET", .seconds(10))
                guard case .object(let fields) = response, fields["session_id"] == .string(id),
                      case .string(let value) = fields["status"] else { throw LoginFailure.invalidResponse }
                guard generation == owned else { return }
                switch value {
                case "pending": continue
                case "approved": finish(.connected, "ChatGPT sign-in connected to this private profile. Choose a subscription model below, then save model access."); return
                case "expired": finish(.expired, "The sign-in code expired. Request a new code to try again."); return
                case "denied": finish(.denied, "OpenAI sign-in was declined. You can request a new code."); return
                case "error": finish(.failed, "OpenAI could not complete sign-in. Check your account and connection, then request a new code."); return
                default: throw LoginFailure.invalidResponse
                }
            }
            guard generation == owned else { return }
            _ = try? await request("/api/providers/oauth/sessions/" + id, "DELETE", .seconds(10))
            finish(.expired, "The sign-in code expired. Request a new code to try again.")
        } catch {
            guard generation == owned else { return }
            _ = try? await request("/api/providers/oauth/sessions/" + id, "DELETE", .seconds(10))
            finish(.failed, "Could not confirm ChatGPT sign-in. Check the connection before trying again.")
        }
    }

    func cancel() async {
        guard busy else { return }
        generation = UUID()
        pollTask?.cancel(); pollTask = nil
        let id = sessionID
        sessionID = nil
        userCode = nil; verificationURL = nil
        // Keep setup locked until the server has acknowledged cancellation.
        var cancelled = true
        if let id {
            do { _ = try await request("/api/providers/oauth/sessions/" + id, "DELETE", .seconds(10)) }
            catch { cancelled = false }
        }
        finish(.cancelled, cancelled ? "Sign-in cancelled." : "Sign-in closed, but server cancellation could not be confirmed. The code will expire; do not approve it.")
    }

    func resetStatus() {
        guard !busy else { return }
        state = .idle; status = ""; userCode = nil; verificationURL = nil
    }

    private func finish(_ state: State, _ message: String) {
        self.state = state; status = message; busy = false
        userCode = nil; verificationURL = nil; sessionID = nil; pollTask = nil
    }
    private static func validSessionID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
    }
    static func officialURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host == "auth.openai.com",
              url.path == "/codex/device", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }
    private static func integer(_ value: JSONValue?, range: ClosedRange<Int>) -> Int? {
        guard case .number(let number) = value, number.isFinite, number.rounded() == number,
              number >= Double(range.lowerBound), number <= Double(range.upperBound) else { return nil }
        return Int(number)
    }
    private enum LoginFailure: Error { case invalidResponse }
}
