import CryptoKit
import Foundation
import OSLog

/// Sends only generic Live Activity state. The APNs key stays on the Mac.
@MainActor
final class PhoneActivityPush {
    static let shared = PhoneActivityPush()

    private struct Credential: Decodable {
        let teamID: String
        let keyID: String
        let privateKey: String
    }

    enum Stage: String {
        case ready, failed, stopped
    }

    private let log = Logger(subsystem: "com.heymate.app", category: "PhoneActivityPush")
    private let session: URLSession
    private let credentialURL = HeyMateDataDirectory.url.appending(path: "phone-live-activity-apns.json")
    private var bearer: [PhoneLiveActivityTarget.Environment: (keyID: String, value: String, created: Date)] = [:]

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration, delegate: PhonePilotNoRedirects(), delegateQueue: nil)
    }

    var isConfigured: Bool {
        (try? credentials())?.isEmpty == false
    }

    func finish(_ target: PhoneLiveActivityTarget, stage: Stage, stillPaired: @MainActor () -> Bool) async {
        guard target.hasValidToken, let credentials = try? credentials(),
              let key = credentials[target.environment.rawValue] else { return }
        let timestamp = Int(Date.now.timeIntervalSince1970)
        let token = target.token.map { String(format: "%02x", $0) }.joined()
        let host = target.environment == .sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)"),
              let authorization = try? jwt(key, environment: target.environment) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(authorization)", forHTTPHeaderField: "authorization")
        request.setValue("com.heymate.app.ios.push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(timestamp + 300), forHTTPHeaderField: "apns-expiration")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "aps": [
                "timestamp": timestamp, "event": "end", "dismissal-date": timestamp + 300,
                "content-state": ["stage": stage.rawValue]
            ]
        ])
        guard request.httpBody != nil else { return }

        for attempt in 0..<3 {
            guard !Task.isCancelled, stillPaired() else { return }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 200 {
                    log.notice("APNs accepted Live Activity completion (\(target.environment.rawValue, privacy: .public))")
                    return
                }
                let reason = (try? JSONDecoder().decode(APNSRejection.self, from: data))?.reason ?? "Unknown"
                log.info("APNs completion response \(http.statusCode): \(reason, privacy: .public)")
                guard http.statusCode == 429 || http.statusCode >= 500 else { return }
            } catch is CancellationError { return }
            catch { log.info("APNs completion transport unavailable") }
            guard attempt < 2 else { return }
            do { try await Task.sleep(for: .seconds(attempt == 0 ? 3 : 10)) } catch { return }
        }
    }

    private struct APNSRejection: Decodable { let reason: String }

    private func credentials() throws -> [String: Credential] {
        let values = try credentialURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: credentialURL.path)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 16_384,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
              let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else {
            throw PhonePilotError.secureStorage
        }
        return try JSONDecoder().decode([String: Credential].self, from: Data(contentsOf: credentialURL))
    }

    private func jwt(_ key: Credential, environment: PhoneLiveActivityTarget.Environment) throws -> String {
        let now = Date.now
        if let saved = bearer[environment], saved.keyID == key.keyID, now.timeIntervalSince(saved.created) < 2_700 {
            return saved.value
        }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": key.keyID])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": key.teamID, "iat": Int(now.timeIntervalSince1970)])
        let message = base64URL(header) + "." + base64URL(claims)
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: key.privateKey)
        let signature = try privateKey.signature(for: Data(message.utf8)).rawRepresentation
        let value = message + "." + base64URL(signature)
        bearer[environment] = (key.keyID, value, now)
        return value
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
