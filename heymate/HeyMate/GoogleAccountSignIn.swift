import AppKit
import AuthenticationServices

/// The system owns browser authentication. Only a transient Google ID token
/// reaches Firebase; no Google refresh token, inbox scopes or SDK token store.
@MainActor
final class GoogleAccountSignIn: NSObject, GoogleAccountSigningIn, ASWebAuthenticationPresentationContextProviding {
    private var authentication: ASWebAuthenticationSession?
    private var window: NSWindow?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window!
    }

    func idToken() async throws -> String {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            throw FirebaseAccountError.configuration
        }
        self.window = window
        let flow = try GoogleOAuthFlow(clientID: clientID)
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let authentication = ASWebAuthenticationSession(url: flow.authorizationURL,
                                                           callbackURLScheme: flow.callbackScheme) { url, error in
                Task { @MainActor in
                    self.authentication = nil
                    if let error = error as NSError? {
                        if error.domain == ASWebAuthenticationSessionError.errorDomain,
                           error.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            continuation.resume(throwing: CancellationError())
                        } else { continuation.resume(throwing: FirebaseAccountError.service) }
                    } else if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: FirebaseAccountError.invalidResponse) }
                }
            }
            authentication.presentationContextProvider = self
            self.authentication = authentication
            if !authentication.start() {
                self.authentication = nil
                continuation.resume(throwing: FirebaseAccountError.service)
            }
        }
        let code = try flow.code(from: callback)
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.timeoutIntervalForRequest = 30
        settings.timeoutIntervalForResource = 45
        let session = URLSession(configuration: settings, delegate: GoogleOAuthNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: flow.tokenRequest(code: code))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["id_token"] as? String, !token.isEmpty else {
            throw FirebaseAccountError.service
        }
        // Firebase verifies this token; decoding a JWT locally never unlocks the app.
        return token
    }
}

private final class GoogleOAuthNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                               completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
