import Foundation
import Testing
@testable import HeyMate

@MainActor
struct GoogleOAuthFlowTests {
    private let client = "123-client.apps.googleusercontent.com"

    @Test func onlyIdentityScopesAndFreshPKCEAreRequested() throws {
        let first = try GoogleOAuthFlow(clientID: client)
        let second = try GoogleOAuthFlow(clientID: client)
        let items = URLComponents(url: first.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first(where: { $0.name == "scope" })?.value == "openid email profile")
        #expect(items.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        #expect(!items.contains(where: { $0.name == "access_type" || $0.name == "client_secret" }))
        #expect(first.state != second.state && first.verifier != second.verifier)
        #expect(first.verifier.count == 43 && first.state.count == 43)
    }

    @Test func unrelatedAndAmbiguousCallbacksAreRejected() throws {
        let flow = try GoogleOAuthFlow(clientID: client)
        for value in [
            "\(flow.redirectURI)?state=wrong&code=code",
            "\(flow.redirectURI)?state=\(flow.state)&state=\(flow.state)&code=code",
            "\(flow.redirectURI)?state=\(flow.state)&code=one&code=two",
            "\(flow.callbackScheme)://attacker/oauth2callback?state=\(flow.state)&code=code",
            "https://example.com/oauth2callback?state=\(flow.state)&code=code",
            "\(flow.redirectURI)?state=\(flow.state)&code=code#fragment"
        ] {
            #expect(throws: FirebaseAccountError.invalidResponse) { try flow.code(from: URL(string: value)!) }
        }
    }

    @Test func matchingCallbackAndEncodedCodeExchange() throws {
        let flow = try GoogleOAuthFlow(clientID: client)
        let code = try flow.code(from: URL(string: "\(flow.redirectURI)?state=\(flow.state)&code=a%2Bb%26c")!)
        #expect(code == "a+b&c")
        let request = flow.tokenRequest(code: code)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.httpMethod == "POST")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        #expect(body.contains("code=a%2Bb%26c"))
        #expect(body.contains("code_verifier=\(flow.verifier)"))
        #expect(!body.contains("client_secret"))
    }

    @Test func accessDenialIsCancellationOnlyWithMatchingState() throws {
        let flow = try GoogleOAuthFlow(clientID: client)
        #expect(throws: CancellationError.self) {
            try flow.code(from: URL(string: "\(flow.redirectURI)?state=\(flow.state)&error=access_denied")!)
        }
        #expect(throws: FirebaseAccountError.invalidResponse) {
            try flow.code(from: URL(string: "\(flow.redirectURI)?state=wrong&error=access_denied")!)
        }
    }

    @Test func malformedClientCannotChangeAuthorizationHostOrCallback() {
        #expect(throws: FirebaseAccountError.configuration) { try GoogleOAuthFlow(clientID: "attacker.example") }
        #expect(throws: FirebaseAccountError.configuration) { try GoogleOAuthFlow(clientID: "evil/?x.apps.googleusercontent.com") }
    }
}
