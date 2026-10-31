import CryptoKit
import Foundation
import Security

/// Public-client authorization code flow. State binds the browser response;
/// PKCE binds the code exchange. Tokens and codes are never persisted here.
struct GoogleOAuthFlow {
    let clientID: String
    let state: String
    let verifier: String
    var callbackScheme: String { clientID.components(separatedBy: ".").reversed().joined(separator: ".") }
    var redirectURI: String { "\(callbackScheme):/oauth2callback" }

    init(clientID: String) throws {
        guard clientID.hasSuffix(".apps.googleusercontent.com"),
              clientID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) }) else {
            throw FirebaseAccountError.configuration
        }
        self.clientID = clientID
        state = try Self.randomValue()
        verifier = try Self.randomValue()
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw FirebaseAccountError.service
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    var authorizationURL: URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: "openid email profile"),
            .init(name: "state", value: state), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
        ]
        return url.url!
    }

    func code(from callback: URL) throws -> String {
        guard let url = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              url.scheme == callbackScheme, url.host == nil, url.path == "/oauth2callback",
              url.fragment == nil, let items = url.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else {
            throw FirebaseAccountError.invalidResponse
        }
        if items.contains(where: { $0.name == "error" }) {
            if items.filter({ $0.name == "error" }).count == 1,
               items.first(where: { $0.name == "error" })?.value == "access_denied" {
                throw CancellationError()
            }
            throw FirebaseAccountError.service
        }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 8192 else { throw FirebaseAccountError.invalidResponse }
        return code
    }

    func tokenRequest(code: String) -> URLRequest {
        var form = URLComponents()
        form.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "code", value: code),
            .init(name: "code_verifier", value: verifier), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "grant_type", value: "authorization_code")
        ]
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return request
    }
}
