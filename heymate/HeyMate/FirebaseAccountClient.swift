import Foundation

/// Only Firebase's public project configuration belongs in this client.
/// No Admin SDK credentials, analytics SDK, or automatic event collection.
struct FirebaseAccountConfiguration {
    let projectID: String
    let apiKey: String

    static var bundled: Self? {
        guard let url = Bundle.main.url(forResource: "FirebaseAccount", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let projectID = values["PROJECT_ID"], !projectID.isEmpty,
              let apiKey = values["API_KEY"], !apiKey.isEmpty else { return nil }
        return Self(projectID: projectID, apiKey: apiKey)
    }
}

struct FirebaseAccountTokens: Codable, Equatable {
    var uid: String
    var email: String
    var refreshToken: String
    var idToken: String
    var verifiedAt: Date?
    var releaseEmails: Bool = false
    var pendingReleaseEmails: Bool? = nil
    var displayName: String? = nil

    /// Grace applies only to an email confirmed by a successful server lookup,
    /// never to an unverified sign-up, a decoded JWT, or a UserDefaults flag.
    func permitsOfflineUse(at now: Date) -> Bool {
        guard let verifiedAt else { return false }
        return (0...(7 * 24 * 60 * 60)).contains(now.timeIntervalSince(verifiedAt))
    }
}

@MainActor
protocol GoogleAccountSigningIn {
    func idToken() async throws -> String
}

enum FirebaseAccountError: Error, LocalizedError, Equatable {
    case configuration, invalidResponse, service, credentials, expired, throttled
    case emailInUse, weakPassword, unverified, persistence, consent

    var errorDescription: String? {
        switch self {
        case .configuration: "Account setup is missing in this build. Please contact HeyMate support."
        case .invalidResponse, .service: "Firebase could not complete this request. Try again shortly."
        case .credentials: "Email or password is incorrect. Try again or reset your password."
        case .expired: "Your session is no longer valid. Please sign in again."
        case .throttled: "Too many attempts. Wait a little before trying again."
        case .emailInUse: "An account already uses this email. Sign in or reset your password."
        case .weakPassword: "Choose a stronger password with at least 8 characters."
        case .unverified: "Email is not verified yet. Open the link in your inbox, then check again."
        case .persistence: "HeyMate could not save your session securely in Keychain. Unlock Keychain and try again."
        case .consent: "Your email preference has not synced. Retry when connected."
        }
    }

    static func from(code: String) -> Self {
        switch code.components(separatedBy: " : ")[0] {
        case "EMAIL_EXISTS": .emailInUse
        case "WEAK_PASSWORD": .weakPassword
        case "INVALID_LOGIN_CREDENTIALS", "INVALID_PASSWORD", "EMAIL_NOT_FOUND", "INVALID_EMAIL": .credentials
        case "TOKEN_EXPIRED", "INVALID_REFRESH_TOKEN", "INVALID_ID_TOKEN", "USER_DISABLED", "USER_NOT_FOUND", "CREDENTIAL_TOO_OLD_LOGIN_AGAIN": .expired
        case "TOO_MANY_ATTEMPTS_TRY_LATER", "RESET_PASSWORD_EXCEED_LIMIT": .throttled
        default: .service
        }
    }
}

@MainActor
protocol FirebaseAccountServing {
    func authenticateGoogle(idToken: String) async throws -> FirebaseAccountTokens
    func authenticate(email: String, password: String, create: Bool) async throws -> FirebaseAccountTokens
    func refresh(_ tokens: FirebaseAccountTokens) async throws -> FirebaseAccountTokens
    func sendVerification(_ tokens: FirebaseAccountTokens) async throws
    func sendPasswordReset(email: String) async throws
    func readReleaseEmails(_ tokens: FirebaseAccountTokens) async throws -> Bool
    func writeReleaseEmails(_ value: Bool, tokens: FirebaseAccountTokens) async throws
}

/// Documented Auth REST API keeps the Mac client small and avoids SDK analytics.
/// URLSession's ephemeral store keeps tokens/passwords out of URL cache/cookies.
@MainActor
final class FirebaseAccountClient: FirebaseAccountServing {
    private let configuration: FirebaseAccountConfiguration?
    private let session: URLSession
    private let now: () -> Date

    init(configuration: FirebaseAccountConfiguration? = .bundled,
         session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.now = now
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.timeoutIntervalForRequest = 20
        settings.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: settings, delegate: FirebaseNoRedirects(), delegateQueue: nil)
    }

    func authenticate(email: String, password: String, create: Bool) async throws -> FirebaseAccountTokens {
        let data = try await auth(create ? "signUp" : "signInWithPassword", body: [
            "email": email, "password": password, "returnSecureToken": true
        ])
        guard let uid = data["localId"] as? String, let email = data["email"] as? String,
              let refresh = data["refreshToken"] as? String, let id = data["idToken"] as? String else {
            throw FirebaseAccountError.invalidResponse
        }
        return try await lookup(FirebaseAccountTokens(uid: uid, email: email, refreshToken: refresh, idToken: id))
    }

    func authenticateGoogle(idToken: String) async throws -> FirebaseAccountTokens {
        guard let configuration, !idToken.isEmpty else { throw FirebaseAccountError.configuration }
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "id_token", value: idToken),
                           URLQueryItem(name: "providerId", value: "google.com")]
        let data = try await auth("signInWithIdp", body: [
            "postBody": form.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B"),
            "requestUri": "https://\(configuration.projectID).firebaseapp.com",
            "returnSecureToken": true, "returnIdpCredential": false
        ])
        guard let uid = data["localId"] as? String, let email = data["email"] as? String,
              let refresh = data["refreshToken"] as? String, let id = data["idToken"] as? String else {
            throw FirebaseAccountError.invalidResponse
        }
        let tokens = try await lookup(FirebaseAccountTokens(uid: uid, email: email, refreshToken: refresh, idToken: id))
        guard tokens.verifiedAt != nil else { throw FirebaseAccountError.unverified }
        return tokens
    }

    func refresh(_ tokens: FirebaseAccountTokens) async throws -> FirebaseAccountTokens {
        guard let configuration else { throw FirebaseAccountError.configuration }
        var request = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(configuration.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"),
                           URLQueryItem(name: "refresh_token", value: tokens.refreshToken)]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let data = try await perform(request)
        guard let uid = data["user_id"] as? String, uid == tokens.uid,
              let refresh = data["refresh_token"] as? String, let id = data["id_token"] as? String else {
            throw FirebaseAccountError.invalidResponse
        }
        var updated = tokens
        updated.refreshToken = refresh
        updated.idToken = id
        updated = try await lookup(updated)
        // Mint a second token after lookup discovers verification. The token
        // issued before the email link was opened may lack email_verified.
        if tokens.verifiedAt == nil && updated.verifiedAt != nil {
            return try await self.refresh(updated)
        }
        return updated
    }

    private func lookup(_ tokens: FirebaseAccountTokens) async throws -> FirebaseAccountTokens {
        let response = try await auth("lookup", body: ["idToken": tokens.idToken])
        guard let users = response["users"] as? [[String: Any]], let user = users.first,
              user["localId"] as? String == tokens.uid, let email = user["email"] as? String else {
            throw FirebaseAccountError.invalidResponse
        }
        if user["disabled"] as? Bool == true { throw FirebaseAccountError.expired }
        var result = tokens
        result.email = email
        result.displayName = user["displayName"] as? String
        result.verifiedAt = user["emailVerified"] as? Bool == true ? now() : nil
        return result
    }

    func sendVerification(_ tokens: FirebaseAccountTokens) async throws {
        _ = try await auth("sendOobCode", body: ["requestType": "VERIFY_EMAIL", "idToken": tokens.idToken])
    }

    func sendPasswordReset(email: String) async throws {
        do { _ = try await auth("sendOobCode", body: ["requestType": "PASSWORD_RESET", "email": email]) }
        catch FirebaseAccountError.credentials { /* Avoid disclosing whether an account exists. */ }
    }

    private func documentName(uid: String) throws -> String {
        guard let configuration, !uid.isEmpty,
              uid.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else {
            throw FirebaseAccountError.configuration
        }
        return "projects/\(configuration.projectID)/databases/(default)/documents/accountPreferences/\(uid)"
    }

    func readReleaseEmails(_ tokens: FirebaseAccountTokens) async throws -> Bool {
        let name = try documentName(uid: tokens.uid)
        var request = URLRequest(url: URL(string: "https://firestore.googleapis.com/v1/\(name)")!)
        request.setValue("Bearer \(tokens.idToken)", forHTTPHeaderField: "Authorization")
        let response = try await perform(request, missingIsEmpty: true)
        guard !response.isEmpty else { return false }
        guard let fields = response["fields"] as? [String: [String: Any]],
              let value = fields["releaseEmails"]?["booleanValue"] as? Bool else { throw FirebaseAccountError.invalidResponse }
        return value
    }

    func writeReleaseEmails(_ value: Bool, tokens: FirebaseAccountTokens) async throws {
        guard tokens.verifiedAt != nil else { throw FirebaseAccountError.unverified }
        let name = try documentName(uid: tokens.uid)
        guard let configuration else { throw FirebaseAccountError.configuration }
        var request = URLRequest(url: URL(string: "https://firestore.googleapis.com/v1/projects/\(configuration.projectID)/databases/(default)/documents:commit")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(tokens.idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["writes": [[
            "update": ["name": name, "fields": ["releaseEmails": ["booleanValue": value],
                                                "consentVersion": ["integerValue": "1"]]],
            "updateTransforms": [["fieldPath": "updatedAt", "setToServerValue": "REQUEST_TIME"]]
        ]]])
        _ = try await perform(request)
    }

    private func auth(_ method: String, body: [String: Any]) async throws -> [String: Any] {
        guard let configuration else { throw FirebaseAccountError.configuration }
        var request = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:\(method)?key=\(configuration.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest, missingIsEmpty: Bool = false) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw FirebaseAccountError.invalidResponse }
        if response.statusCode == 404 && missingIsEmpty { return [:] }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(response.statusCode) else {
            let error = json["error"] as? [String: Any]
            if response.statusCode == 429 { throw FirebaseAccountError.throttled }
            throw FirebaseAccountError.from(code: error?["message"] as? String ?? "")
        }
        return json
    }
}

private final class FirebaseNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest,
                               completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
