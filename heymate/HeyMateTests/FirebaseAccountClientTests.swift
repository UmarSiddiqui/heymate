import Foundation
import Testing
@testable import HeyMate

private final class AccountMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func startLoading() {
        do {
            let (status, value) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: value))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    nonisolated override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct FirebaseAccountClientTests {
    private func client() -> FirebaseAccountClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountMockURLProtocol.self]
        return FirebaseAccountClient(configuration: .init(projectID: "demo-heymate", apiKey: "fake-key"),
                                     session: URLSession(configuration: config))
    }

    @Test func signupDoesNotTrustTokenResponseForVerification() async throws {
        AccountMockURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("accounts:signUp") {
                return (200, ["localId": "user", "email": "test@example.invalid", "idToken": "id",
                              "refreshToken": "refresh", "emailVerified": true])
            }
            #expect(request.url!.path.hasSuffix("accounts:lookup"))
            return (200, ["users": [["localId": "user", "email": "test@example.invalid", "emailVerified": false]]])
        }
        defer { AccountMockURLProtocol.handler = nil }
        let tokens = try await client().authenticate(email: "test@example.invalid", password: "password", create: true)
        #expect(tokens.verifiedAt == nil)
    }

    @Test func refreshRotatesTokensAndMintsVerifiedClaimBeforeFirestore() async throws {
        nonisolated(unsafe) var refreshes = 0
        AccountMockURLProtocol.handler = { request in
            if request.url!.host == "securetoken.googleapis.com" {
                refreshes += 1
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                return (200, ["user_id": "user", "id_token": "id-\(refreshes)", "refresh_token": "refresh-\(refreshes)"])
            }
            return (200, ["users": [["localId": "user", "email": "test@example.invalid", "emailVerified": true]]])
        }
        defer { AccountMockURLProtocol.handler = nil }
        let tokens = try await client().refresh(.init(uid: "user", email: "test@example.invalid", refreshToken: "old", idToken: "old-id"))
        #expect(refreshes == 2)
        #expect(tokens.verifiedAt != nil)
        #expect(tokens.refreshToken == "refresh-2")
        #expect(tokens.idToken == "id-2")
    }

    @Test func missingOrMismatchedServerIdentityCannotUnlock() async {
        AccountMockURLProtocol.handler = { _ in
            (200, ["user_id": "another-user", "id_token": "id", "refresh_token": "refresh"])
        }
        defer { AccountMockURLProtocol.handler = nil }
        await #expect(throws: FirebaseAccountError.invalidResponse) {
            _ = try await client().refresh(.init(uid: "user", email: "test@example.invalid", refreshToken: "refresh", idToken: "id"))
        }
    }

    @Test func consentUsesBearerTokenAndServerTimestampWithoutEmailOrAnalyticsIdentity() async throws {
        AccountMockURLProtocol.handler = { request in
            #expect(request.url!.host == "firestore.googleapis.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer verified-id")
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let writes = json["writes"] as! [[String: Any]]
            let update = writes[0]["update"] as! [String: Any]
            #expect((update["name"] as! String).hasSuffix("/accountPreferences/user"))
            let fields = update["fields"] as! [String: Any]
            #expect(Set(fields.keys) == ["releaseEmails", "consentVersion"])
            let transforms = writes[0]["updateTransforms"] as! [[String: String]]
            #expect(transforms == [["fieldPath": "updatedAt", "setToServerValue": "REQUEST_TIME"]])
            return (200, ["commitTime": "2026-10-31T00:00:00Z"])
        }
        defer { AccountMockURLProtocol.handler = nil }
        try await client().writeReleaseEmails(false, tokens: .init(uid: "user", email: "test@example.invalid",
                                    refreshToken: "refresh", idToken: "verified-id", verifiedAt: Date()))
    }

    @Test func unverifiedConsentNeverMakesNetworkRequest() async {
        AccountMockURLProtocol.handler = { _ in
            Issue.record("Unverified consent reached network")
            return (200, [:])
        }
        defer { AccountMockURLProtocol.handler = nil }
        await #expect(throws: FirebaseAccountError.unverified) {
            try await client().writeReleaseEmails(true, tokens: .init(uid: "user", email: "test@example.invalid", refreshToken: "refresh", idToken: "id"))
        }
    }
    @Test func googleCredentialIsEncodedAndVerificationComesFromLookup() async throws {
        AccountMockURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("accounts:signInWithIdp") {
                var bytes = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        bytes.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                #expect(body["requestUri"] as? String == "https://demo-heymate.firebaseapp.com")
                #expect(body["postBody"] as? String == "id_token=google%2Btoken%26value&providerId=google.com")
                return (200, ["localId": "user", "email": "test@example.invalid", "idToken": "id",
                              "refreshToken": "refresh", "emailVerified": true])
            }
            return (200, ["users": [["localId": "user", "email": "test@example.invalid", "emailVerified": false]]])
        }
        defer { AccountMockURLProtocol.handler = nil }
        await #expect(throws: FirebaseAccountError.unverified) {
            _ = try await client().authenticateGoogle(idToken: "google+token&value")
        }
    }

}
