//
//  RemoteAccessCore.swift
//  HeyMate
//
//  Pure rules for Phone access (RemoteAccessController.swift): which peers
//  may connect, which Host headers are ours, pairing codes and their lockout,
//  device tokens (hashed, compared in constant time), the CSRF check, the
//  fixed route table, request parsing, rate limits, and what text may cross
//  the wire. Nothing here opens a socket or touches app state, so every rule
//  is unit tested (RemoteAccessCoreTests.swift).
//
//  The route table is the whole remote surface. Tool approvals, settings,
//  approval rules or mode, browser takeover, files, memory, sign-in, brain,
//  skills and connectors have no route, by construction.
//

import CryptoKit
import Darwin
import Foundation

nonisolated enum RemoteAccessPolicy {
    static let port: UInt16 = 47_821
    static let pairingCodeLength = 8
    /// No 0/O, 1/I/L: read off a screen and typed on a phone.
    static let pairingCodeAlphabet: [Character] = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
    static let pairingCodeLifetime: TimeInterval = 5 * 60
    static let pairingAttemptsPerCode = 5
    static let pairingLockout: TimeInterval = 10 * 60
    static let maxHeaderBytes = 8 * 1024
    static let maxHeaderCount = 40
    static let maxBodyBytes = 4 * 1024
    static let maxTargetLength = 256
    static let maxMessageCharacters = 1_000
    static let maxAnswerCharacters = 600
    static let deviceIdleExpiry: TimeInterval = 30 * 24 * 3600
    static let maxDevices = 5
    static let maxConnections = 16
    static let connectionTimeout: TimeInterval = 10
    static let cookieName = "hm_phone"
    static let cookieMaxAge = 30 * 24 * 3600
    static let csrfHeader = "x-heymate-csrf"
    static let pairHeader = "x-heymate-pair"
    static let tokenByteCount = 32
}

// MARK: - Peers and hosts

nonisolated enum RemoteAddressPolicy {
    /// Private, link-local and VPN-style addresses only: 10/8, 172.16/12,
    /// 192.168/16, 169.254/16, 100.64/10 (carrier-grade NAT space that
    /// Tailscale uses), IPv6 unique-local fc00::/7 and link-local fe80::/10,
    /// and IPv4-mapped forms of those. Loopback, multicast and every public
    /// address are refused.
    static func isAllowedPeer(_ bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4:
            return isPrivateIPv4(bytes)
        case 16:
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isPrivateIPv4(Array(bytes[12..<16]))
            }
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return true }
            if bytes[0] & 0xfe == 0xfc { return true }
            return false
        default:
            return false
        }
    }

    static func isPrivateIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch b[0] {
        case 10: return true
        case 172: return (16...31).contains(b[1])
        case 192: return b[1] == 168
        case 169: return b[1] == 254
        case 100: return (64...127).contains(b[1])
        default: return false
        }
    }

    /// Parses "192.168.1.4", "fe80::1%en0" or "[fd00::1]".
    static func bytes(fromLiteral text: String) -> [UInt8]? {
        var literal = text.trimmingCharacters(in: .whitespaces)
        if literal.hasPrefix("["), literal.hasSuffix("]") { literal = String(literal.dropFirst().dropLast()) }
        if let percent = literal.firstIndex(of: "%") { literal = String(literal[..<percent]) }
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, literal, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    static func isAllowedPeer(literal: String) -> Bool {
        bytes(fromLiteral: literal).map(isAllowedPeer) ?? false
    }
}

nonisolated enum RemoteHostPolicy {
    /// Host header values this Mac answers to: its own private addresses and
    /// its Bonjour name, each with the port. Anything else (a rebinding
    /// domain pointed at this Mac) is refused.
    static func allowedHosts(addresses: [String], localHostName: String?, port: UInt16) -> Set<String> {
        var hosts = Set<String>()
        for address in addresses where RemoteAddressPolicy.isAllowedPeer(literal: address) {
            let bare = String(address.split(separator: "%", maxSplits: 1).first ?? Substring(address)).lowercased()
            hosts.insert((bare.contains(":") ? "[\(bare)]" : bare) + ":\(port)")
        }
        if let name = localHostName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty,
           name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }) {
            hosts.insert("\(name).local:\(port)")
        }
        return hosts
    }

    static func isAllowed(hostHeader: String?, allowed: Set<String>) -> Bool {
        guard let host = hostHeader?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty else { return false }
        return allowed.contains(host)
    }

    static func isSameOrigin(origin: String?, host: String) -> Bool {
        guard let origin = origin?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return origin == "http://" + host.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

// MARK: - Tokens and pairing

nonisolated enum RemoteToken {
    /// A 256-bit random token, base64url without padding (43 characters).
    static func make<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let bytes = (0..<RemoteAccessPolicy.tokenByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return make(using: &generator)
    }

    static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == 43 && token.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }

    /// Only this hash is stored. A token is 256 random bits, so a plain
    /// SHA-256 is enough; a slow password hash adds nothing here.
    static func hash(_ token: String) -> String {
        hex(SHA256.hash(data: Data(token.utf8)))
    }

    /// The per-session header value the page must echo on every change.
    static func csrf(for token: String) -> String {
        hex(SHA256.hash(data: Data("heymate-phone-csrf\u{0}\(token)".utf8)))
    }

    /// Time depends only on the longer length, never on where bytes differ.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference: UInt8 = x.count == y.count ? 0 : 1
        for index in 0..<max(x.count, y.count) {
            difference |= (index < x.count ? x[index] : 0) ^ (index < y.count ? y[index] : 0)
        }
        return difference == 0
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct RemotePairing: Equatable {
    enum Outcome: Equatable {
        case paired
        case wrongCode(attemptsLeft: Int)
        case expired
        case noCode
        case lockedOut(until: Date)
    }

    private(set) var code: String?
    private(set) var expiresAt: Date?
    private(set) var attemptsLeft = 0
    private(set) var lockedUntil: Date?

    static func makeCode<G: RandomNumberGenerator>(using generator: inout G) -> String {
        String((0..<RemoteAccessPolicy.pairingCodeLength).map { _ in
            RemoteAccessPolicy.pairingCodeAlphabet.randomElement(using: &generator)!
        })
    }

    static func makeCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return makeCode(using: &generator)
    }

    /// Uppercases and drops spaces and dashes a person might type.
    static func normalize(_ input: String) -> String {
        String(input.uppercased().filter { RemoteAccessPolicy.pairingCodeAlphabet.contains($0) }.prefix(32))
    }

    func isActive(now: Date) -> Bool {
        guard code != nil, let expiresAt else { return false }
        return now < expiresAt
    }

    func isLockedOut(now: Date) -> Bool {
        lockedUntil.map { now < $0 } ?? false
    }

    /// Started only from the Mac, so it also clears an earlier lockout.
    mutating func start(code: String, now: Date) {
        self.code = code
        expiresAt = now.addingTimeInterval(RemoteAccessPolicy.pairingCodeLifetime)
        attemptsLeft = RemoteAccessPolicy.pairingAttemptsPerCode
        lockedUntil = nil
    }

    mutating func cancel() {
        code = nil
        expiresAt = nil
        attemptsLeft = 0
    }

    /// Single use: success voids the code. Too many wrong tries void it and
    /// lock pairing until the lockout ends or the Mac starts a new code.
    mutating func attempt(_ input: String, now: Date) -> Outcome {
        if let lockedUntil, now < lockedUntil { return .lockedOut(until: lockedUntil) }
        guard let code, let expiresAt else { return .noCode }
        guard now < expiresAt else {
            cancel()
            return .expired
        }
        if RemoteToken.constantTimeEquals(Self.normalize(input), code) {
            cancel()
            return .paired
        }
        attemptsLeft -= 1
        if attemptsLeft <= 0 {
            cancel()
            let until = now.addingTimeInterval(RemoteAccessPolicy.pairingLockout)
            lockedUntil = until
            return .lockedOut(until: until)
        }
        return .wrongCode(attemptsLeft: attemptsLeft)
    }
}

nonisolated struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let tokenHash: String
    let pairedAt: Date
    var lastSeenAt: Date
}

nonisolated enum RemoteDeviceRegistry {
    /// Compares the presented token against every stored hash without
    /// stopping early, so timing does not reveal which device matched.
    static func match(token: String?, in devices: [RemoteDevice], now: Date) -> RemoteDevice? {
        guard let token, RemoteToken.isWellFormed(token) else { return nil }
        let presented = RemoteToken.hash(token)
        var found: RemoteDevice?
        for device in devices {
            if RemoteToken.constantTimeEquals(presented, device.tokenHash), found == nil { found = device }
        }
        guard let found, !isExpired(found, now: now) else { return nil }
        return found
    }

    static func isExpired(_ device: RemoteDevice, now: Date) -> Bool {
        now.timeIntervalSince(device.lastSeenAt) > RemoteAccessPolicy.deviceIdleExpiry
    }

    static func pruned(_ devices: [RemoteDevice], now: Date) -> [RemoteDevice] {
        devices.filter { !isExpired($0, now: now) }
    }

    /// Adds a device, dropping the least recently seen one past the limit.
    static func adding(_ device: RemoteDevice, to devices: [RemoteDevice]) -> [RemoteDevice] {
        var all = devices + [device]
        while all.count > RemoteAccessPolicy.maxDevices,
              let oldest = all.filter({ $0.id != device.id }).min(by: { $0.lastSeenAt < $1.lastSeenAt }) {
            all.removeAll { $0.id == oldest.id }
        }
        return all
    }

    /// A plain label from the User-Agent. Never the raw string.
    static func label(userAgent: String?, existing: [RemoteDevice]) -> String {
        let agent = (userAgent ?? "").lowercased()
        let base: String
        if agent.contains("iphone") { base = "iPhone" }
        else if agent.contains("ipad") { base = "iPad" }
        else if agent.contains("android") { base = "Android phone" }
        else { base = "Phone" }
        let taken = Set(existing.map(\.name))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}

// MARK: - Rate limits

nonisolated struct RemoteRateLimiter {
    let capacity: Double
    let refillPerSecond: Double
    let maxKeys: Int
    private var buckets: [String: (tokens: Double, updated: Date)] = [:]

    init(capacity: Double, refillPerSecond: Double, maxKeys: Int = 256) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.maxKeys = maxKeys
    }

    mutating func allow(_ key: String, now: Date, cost: Double = 1) -> Bool {
        var bucket = buckets[key] ?? (capacity, now)
        bucket.tokens = min(capacity, bucket.tokens + max(0, now.timeIntervalSince(bucket.updated)) * refillPerSecond)
        bucket.updated = now
        let allowed = bucket.tokens >= cost
        if allowed { bucket.tokens -= cost }
        buckets[key] = bucket
        if buckets.count > maxKeys, let stale = buckets.min(by: { $0.value.updated < $1.value.updated })?.key {
            buckets.removeValue(forKey: stale)
        }
        return allowed
    }

    mutating func reset() { buckets.removeAll() }
    var trackedKeys: Int { buckets.count }
}

// MARK: - HTTP

nonisolated struct RemoteHTTPRequest: Equatable, Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var cookies: [String: String] {
        var result: [String: String] = [:]
        for part in (header("cookie") ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, result[pair[0]] == nil { result[pair[0]] = pair[1] }
        }
        return result
    }
}

nonisolated enum RemoteHTTPParser {
    enum Result: Equatable {
        case incomplete
        case complete(RemoteHTTPRequest)
        case rejected(Int)
    }

    /// One request per connection; no chunked bodies, no pipelining.
    static func parse(_ data: Data) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > RemoteAccessPolicy.maxHeaderBytes ? .rejected(431) : .incomplete
        }
        guard end.lowerBound <= RemoteAccessPolicy.maxHeaderBytes else { return .rejected(431) }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8),
              head.unicodeScalars.allSatisfy({ $0.isASCII }) else { return .rejected(400) }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard requestLine.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(requestLine[2]) else { return .rejected(400) }
        let method = requestLine[0]
        guard ["GET", "POST"].contains(method) else { return .rejected(405) }
        let target = requestLine[1]
        guard target.hasPrefix("/"), target.utf8.count <= RemoteAccessPolicy.maxTargetLength,
              target.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }),
              !target.contains("#") else { return .rejected(400) }
        guard lines.count <= RemoteAccessPolicy.maxHeaderCount else { return .rejected(431) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .rejected(400) }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(" "), !name.contains("\t") else { return .rejected(400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil {
                if ["host", "content-length", "cookie", "origin", RemoteAccessPolicy.csrfHeader].contains(name) {
                    return .rejected(400)
                }
                headers[name]! += ", " + value
            } else {
                headers[name] = value
            }
        }
        guard headers["transfer-encoding"] == nil else { return .rejected(400) }
        var length = 0
        if let declared = headers["content-length"] {
            guard !declared.isEmpty, declared.utf8.count <= 6, declared.allSatisfy(\.isASCII), declared.allSatisfy(\.isNumber),
                  let value = Int(declared) else { return .rejected(400) }
            length = value
        }
        guard length <= RemoteAccessPolicy.maxBodyBytes else { return .rejected(413) }
        if method == "GET", length > 0 { return .rejected(400) }
        let bodyStart = end.upperBound
        let available = data.endIndex - bodyStart
        if available < length { return .incomplete }
        guard available == length else { return .rejected(400) }
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = String(kv[0]).removingPercentEncoding else { return .rejected(400) }
                let value = kv.count == 2 ? String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding : ""
                guard let value else { return .rejected(400) }
                if query[key] == nil { query[key] = value }
            }
        }
        return .complete(RemoteHTTPRequest(method: method, path: String(parts[0]), query: query, headers: headers,
                                           body: Data(data[bodyStart..<data.endIndex])))
    }
}

/// The complete remote surface. Adding a case here is the only way to make
/// something reachable from a phone, and RemoteAccessCoreTests pins the list.
nonisolated enum RemoteRoute: String, CaseIterable, Sendable {
    case page
    case script
    case style
    case pair
    case state
    case approveProposal
    case skipProposal
    case answerQuestion
    case sendMessage
    case readReply
    case signOut

    var method: String {
        switch self {
        case .page, .script, .style, .state, .readReply: "GET"
        case .pair, .approveProposal, .skipProposal, .answerQuestion, .sendMessage, .signOut: "POST"
        }
    }

    var path: String {
        switch self {
        case .page: "/"
        case .script: "/app.js"
        case .style: "/app.css"
        case .pair: "/api/pair"
        case .state: "/api/state"
        case .approveProposal: "/api/proposals/approve"
        case .skipProposal: "/api/proposals/skip"
        case .answerQuestion: "/api/questions/answer"
        case .sendMessage: "/api/messages"
        case .readReply: "/api/messages/reply"
        case .signOut: "/api/sign-out"
        }
    }

    /// The page and its two assets are public; everything else needs a paired device.
    var requiresDevice: Bool {
        switch self {
        case .page, .script, .style, .pair: false
        default: true
        }
    }

    var changesState: Bool { method == "POST" }

    static func match(method: String, path: String) -> RemoteRoute? {
        allCases.first { $0.method == method && $0.path == path }
    }
}

nonisolated enum RemoteGate {
    enum Decision: Equatable {
        case allow(RemoteRoute)
        case reject(Int)
    }

    struct Context {
        var sourceAllowed: Bool
        var allowedHosts: Set<String>
        var deviceTokenValid: Bool
        var expectedCSRF: String?
    }

    /// Order matters: source, Host (DNS rebinding), route, then for changes
    /// same-origin + JSON, then the device cookie and the CSRF header.
    static func evaluate(_ request: RemoteHTTPRequest, _ context: Context) -> Decision {
        guard context.sourceAllowed else { return .reject(403) }
        guard let host = request.header("host"),
              RemoteHostPolicy.isAllowed(hostHeader: host, allowed: context.allowedHosts) else { return .reject(421) }
        guard let route = RemoteRoute.match(method: request.method, path: request.path) else { return .reject(404) }
        if route.changesState {
            guard RemoteHostPolicy.isSameOrigin(origin: request.header("origin"), host: host) else { return .reject(403) }
            if let site = request.header("sec-fetch-site"), site.lowercased() != "same-origin" { return .reject(403) }
            guard request.header("content-type")?.lowercased().hasPrefix("application/json") == true else { return .reject(415) }
        }
        if route.requiresDevice {
            guard context.deviceTokenValid else { return .reject(401) }
            if route.changesState {
                guard let expected = context.expectedCSRF, let sent = request.header(RemoteAccessPolicy.csrfHeader),
                      RemoteToken.constantTimeEquals(sent, expected) else { return .reject(403) }
            }
        } else if route == .pair {
            guard request.header(RemoteAccessPolicy.pairHeader) == "1" else { return .reject(403) }
        }
        return .allow(route)
    }
}

nonisolated struct RemoteHTTPResponse: Equatable, Sendable {
    var status: Int
    var contentType: String
    var body: Data
    var setCookie: String?

    static let contentSecurityPolicy = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; "
        + "img-src 'self'; manifest-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    static let securityHeaders: [(String, String)] = [
        ("Content-Security-Policy", contentSecurityPolicy),
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
        ("Cross-Origin-Opener-Policy", "same-origin"),
        ("Cross-Origin-Resource-Policy", "same-origin"),
        ("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()"),
        ("Cache-Control", "no-store"),
        ("Connection", "close")
    ]

    static func text(_ body: String, type: String) -> Self {
        Self(status: 200, contentType: type, body: Data(body.utf8))
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> Self {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return Self(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    /// Generic bodies only: a word the page can branch on, never a reason.
    static func error(_ status: Int) -> Self {
        let word = switch status {
        case 401: "unpaired"
        case 404: "not_found"
        case 409: "unavailable"
        case 429: "slow_down"
        default: "refused"
        }
        return json(["error": word], status: status)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 421: "Misdirected Request"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in Self.securityHeaders { head += "\(name): \(value)\r\n" }
        if let setCookie { head += "Set-Cookie: \(setCookie)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    /// HttpOnly + SameSite=Strict. Not Secure: this is plain HTTP on the LAN.
    static func sessionCookie(token: String) -> String {
        "\(RemoteAccessPolicy.cookieName)=\(token); Path=/; Max-Age=\(RemoteAccessPolicy.cookieMaxAge); HttpOnly; SameSite=Strict"
    }

    static let clearingCookie = "\(RemoteAccessPolicy.cookieName)=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"
}

// MARK: - What crosses the wire

nonisolated enum RemoteRedaction {
    static let privateNotice = "Mentions an app you keep private. Open HeyMate on your Mac to see it."

    /// Names that mark text as about an excluded app: each bundle id, its
    /// last part when it is a real word, and the app's display name.
    static func excludedNames(bundleIDs: [String], displayNames: [String]) -> [String] {
        var names = Set<String>()
        for id in bundleIDs {
            let lower = id.lowercased()
            names.insert(lower)
            if let last = lower.split(separator: ".").last, last.count >= 4 { names.insert(String(last)) }
            if lower == "com.apple.systempreferences" {
                names.formUnion(["system settings", "system preferences"])
            }
        }
        for name in displayNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.count >= 3 { names.insert(trimmed) }
        }
        return names.sorted()
    }

    static func mentionsExcluded(_ text: String, names: [String]) -> Bool {
        let haystack = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let squeezed = haystack.filter { !$0.isWhitespace }
        return names.contains { name in
            let needle = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard needle.count >= 3 else { return false }
            return haystack.contains(needle) || squeezed.contains(needle.filter { !$0.isWhitespace })
        }
    }

    /// Untrusted mate text, made safe to show as plain text: credentials,
    /// paths, links and emails removed, one line, bounded.
    static func line(_ text: String, limit: Int, excludedNames: [String]) -> String {
        if mentionsExcluded(text, names: excludedNames) { return privateNotice }
        let safe = AgentReceiptPrivacy.safeResult(text)
        let flat = safe.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(max(1, limit - 1))) + "…" : flat
    }

    /// Like `line`, keeping paragraph breaks for a chat reply.
    static func reply(_ text: String, excludedNames: [String]) -> String {
        if mentionsExcluded(text, names: excludedNames) { return privateNotice }
        return AgentReceiptPrivacy.safeResult(text)
    }
}

nonisolated enum RemoteInboxSource: Equatable, Sendable {
    case proposal(title: String, whyNow: String)
    case question(prompt: String, choices: [String])
    case routineFailed(summary: String)
    case signIn(site: String)
    case waitingForPermission
}

nonisolated struct RemoteInboxInput: Equatable, Sendable {
    let id: UUID
    let mateName: String
    let createdAt: Date
    let source: RemoteInboxSource
}

nonisolated struct RemoteInboxEntry: Encodable, Equatable, Sendable {
    let id: String
    let mate: String
    let kind: String
    let title: String
    let detail: String?
    let choices: [String]
    let actions: [String]
    let atMac: Bool
    let createdAt: Date
}

nonisolated struct RemoteMateInput: Equatable, Sendable {
    let id: UUID
    let name: String
    let isWorking: Bool
    let isWaiting: Bool
    let lastLine: String?
}

nonisolated struct RemoteMateEntry: Encodable, Equatable, Sendable {
    let id: String
    let name: String
    let status: String
    let line: String?
}

nonisolated struct RemoteStatePayload: Encodable, Sendable {
    let csrf: String
    let device: String
    let mates: [RemoteMateEntry]
    let inbox: [RemoteInboxEntry]
}

nonisolated enum RemoteReplyStatus: Equatable, Sendable {
    case queued
    case working
    case waitingAtMac
    case needsAnswer
    case finished(String?)
    case failed(String?)
}

nonisolated struct RemoteReplyPayload: Encodable, Equatable, Sendable {
    let state: String
    let text: String?
}

nonisolated enum RemotePayload {
    static func mateName(_ name: String) -> String {
        let flat = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? "Mate" : String(flat.prefix(40))
    }

    static func inboxEntry(_ input: RemoteInboxInput, excludedNames: [String]) -> RemoteInboxEntry {
        let mate = mateName(input.mateName)
        func entry(_ kind: String, _ title: String, _ detail: String?, choices: [String] = [], actions: [String] = [], atMac: Bool) -> RemoteInboxEntry {
            RemoteInboxEntry(id: input.id.uuidString, mate: mate, kind: kind, title: title, detail: detail,
                             choices: choices, actions: actions, atMac: atMac, createdAt: input.createdAt)
        }
        switch input.source {
        case .proposal(let title, let whyNow):
            let safeTitle = RemoteRedaction.line(title, limit: 80, excludedNames: excludedNames)
            let hidden = safeTitle == RemoteRedaction.privateNotice
            return entry("proposal", safeTitle,
                         hidden ? nil : RemoteRedaction.line(whyNow, limit: 240, excludedNames: excludedNames),
                         actions: hidden ? [] : ["approve", "skip"], atMac: hidden)
        case .question(let prompt, let choices):
            let safePrompt = RemoteRedaction.line(prompt, limit: 300, excludedNames: excludedNames)
            // A question you cannot read is not answered from the phone.
            if safePrompt == RemoteRedaction.privateNotice {
                return entry("question", safePrompt, nil, atMac: true)
            }
            let safeChoices = choices.prefix(6).map { RemoteRedaction.line($0, limit: 80, excludedNames: excludedNames) }
            return entry("question", safePrompt, nil,
                         choices: safeChoices.contains(RemoteRedaction.privateNotice) ? [] : safeChoices,
                         actions: ["answer"], atMac: false)
        case .routineFailed(let summary):
            return entry("failed", "A routine couldn't finish",
                         RemoteRedaction.line(summary, limit: 200, excludedNames: excludedNames), atMac: true)
        case .signIn(let site):
            return entry("signin", "Sign-in needed",
                         RemoteRedaction.line("Sign in to \(site)", limit: 120, excludedNames: excludedNames), atMac: true)
        case .waitingForPermission:
            return entry("permission", "Waiting for your permission", nil, atMac: true)
        }
    }

    static func mateEntry(_ input: RemoteMateInput, excludedNames: [String]) -> RemoteMateEntry {
        let status = input.isWaiting ? "waiting" : (input.isWorking ? "working" : "idle")
        let line = input.lastLine.flatMap { text -> String? in
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let safe = RemoteRedaction.line(first, limit: 160, excludedNames: excludedNames)
            return safe.isEmpty ? nil : safe
        }
        return RemoteMateEntry(id: input.id.uuidString, name: mateName(input.name), status: status, line: line)
    }

    static func reply(_ status: RemoteReplyStatus, excludedNames: [String]) -> RemoteReplyPayload {
        switch status {
        case .queued: RemoteReplyPayload(state: "queued", text: nil)
        case .working: RemoteReplyPayload(state: "working", text: nil)
        case .waitingAtMac: RemoteReplyPayload(state: "atMac", text: nil)
        case .needsAnswer: RemoteReplyPayload(state: "question", text: nil)
        case .finished(let text):
            RemoteReplyPayload(state: "done", text: text.map { RemoteRedaction.reply($0, excludedNames: excludedNames) })
        case .failed(let text):
            RemoteReplyPayload(state: "failed", text: text.map { RemoteRedaction.line($0, limit: 200, excludedNames: excludedNames) })
        }
    }
}

// MARK: - Local log of remote actions

nonisolated struct RemoteAuditEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let device: String
    let action: String

    static let kept = 50

    static func appending(_ entry: RemoteAuditEntry, to log: [RemoteAuditEntry]) -> [RemoteAuditEntry] {
        Array(([entry] + log).prefix(kept))
    }
}
