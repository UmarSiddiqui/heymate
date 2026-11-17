//
//  RemoteAccessCoreTests.swift
//  HeyMateTests
//
//  Phone access is a network listener on a personal machine, so its rules
//  are pinned here: the exact route list, what has no route, pairing and
//  lockout, token hashing and comparison, peer and Host checks, CSRF,
//  parsing limits, rate limits and what text may leave the Mac. Nothing
//  here opens a socket or touches UserDefaults.
//

import Foundation
import Testing
@testable import HeyMate

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let host = "192.168.1.20:47821"
private let allowedHosts: Set<String> = [host, "my-mac.local:47821"]

private func request(_ method: String, _ target: String, headers: [String: String] = [:], body: String = "") -> RemoteHTTPRequest {
    var head = "\(method) \(target) HTTP/1.1\r\nHost: \(host)\r\n"
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
    if !body.isEmpty { head += "Content-Length: \(body.utf8.count)\r\n" }
    head += "\r\n" + body
    guard case .complete(let parsed) = RemoteHTTPParser.parse(Data(head.utf8)) else {
        Issue.record("could not parse \(method) \(target)")
        return RemoteHTTPRequest(method: method, path: target, query: [:], headers: [:], body: Data())
    }
    return parsed
}

private func context(device: Bool, csrf: String? = "expected-csrf", source: Bool = true) -> RemoteGate.Context {
    RemoteGate.Context(sourceAllowed: source, allowedHosts: allowedHosts, deviceTokenValid: device, expectedCSRF: device ? csrf : nil)
}

private let sameOriginJSON = [
    "Origin": "http://\(host)",
    "Content-Type": "application/json",
    "Sec-Fetch-Site": "same-origin",
    "X-HeyMate-CSRF": "expected-csrf"
]

struct RemoteAccessCoreTests {

    // MARK: Routes

    @Test func routeTableIsExactlyTheIntendedSurface() {
        let routes = Set(RemoteRoute.allCases.map { "\($0.method) \($0.path)" })
        #expect(routes == [
            "GET /",
            "GET /app.js",
            "GET /app.css",
            "POST /api/pair",
            "GET /api/state",
            "POST /api/proposals/approve",
            "POST /api/proposals/skip",
            "POST /api/questions/answer",
            "POST /api/messages",
            "GET /api/messages/reply",
            "POST /api/sign-out"
        ])
        #expect(RemoteRoute.allCases.count == routes.count)
    }

    @Test func onlyThePageAssetsAndPairingArePublic() {
        let open = Set(RemoteRoute.allCases.filter { !$0.requiresDevice })
        #expect(open == [.page, .script, .style, .pair])
    }

    @Test func outOfScopeActionsHaveNoRoute() {
        let forbidden = [
            "/api/approvals", "/api/approvals/approve", "/api/tools/approve", "/api/tool-calls", "/api/settings",
            "/api/approval-rules", "/api/approval-mode", "/api/mode", "/api/browser", "/api/browser/takeover",
            "/api/files", "/api/file", "/api/memory", "/api/sign-in", "/api/signin", "/api/brain", "/api/model",
            "/api/skills", "/api/connectors", "/api/proposals/adjust", "/api/inbox/undo", "/api/routines",
            "/index.html", "/app.js/", "/api/state/", "/../etc/passwd", "/api/../api/state", "/%2e%2e/", "/api"
        ]
        for path in forbidden {
            for method in ["GET", "POST", "PUT", "DELETE", "PATCH"] {
                #expect(RemoteRoute.match(method: method, path: path) == nil, "\(method) \(path) must not exist")
            }
            #expect(RemoteGate.evaluate(request("POST", path, headers: sameOriginJSON, body: "{}"), context(device: true)) == .reject(404))
            #expect(RemoteGate.evaluate(request("GET", path), context(device: true)) == .reject(404))
        }
    }

    @Test func routesMatchOnlyTheirOwnMethod() {
        #expect(RemoteRoute.match(method: "GET", path: "/api/proposals/approve") == nil)
        #expect(RemoteRoute.match(method: "POST", path: "/api/state") == nil)
        #expect(RemoteRoute.match(method: "POST", path: "/") == nil)
        #expect(RemoteRoute.match(method: "GET", path: "/api/messages/reply") == .readReply)
    }

    // MARK: Gate: source, Host, CSRF

    @Test func gateRefusesOutsidersBeforeAnythingElse() {
        #expect(RemoteGate.evaluate(request("GET", "/"), context(device: true, source: false)) == .reject(403))
    }

    @Test func gateRefusesForeignHostHeaders() {
        var rebinding = request("GET", "/api/state")
        rebinding.headers["host"] = "evil.example:47821"
        #expect(RemoteGate.evaluate(rebinding, context(device: true)) == .reject(421))
        rebinding.headers["host"] = "192.168.1.20:80"
        #expect(RemoteGate.evaluate(rebinding, context(device: true)) == .reject(421))
        rebinding.headers.removeValue(forKey: "host")
        #expect(RemoteGate.evaluate(rebinding, context(device: true)) == .reject(421))
        var bonjour = request("GET", "/")
        bonjour.headers["host"] = "MY-MAC.local:47821"
        #expect(RemoteGate.evaluate(bonjour, context(device: false)) == .allow(.page))
    }

    @Test func gateNeedsAPairedDeviceForEveryNonPublicRoute() {
        for route in RemoteRoute.allCases where route.requiresDevice {
            let probe = route.changesState
                ? request(route.method, route.path, headers: sameOriginJSON, body: "{}")
                : request(route.method, route.path)
            #expect(RemoteGate.evaluate(probe, context(device: false)) == .reject(401), "\(route) must need a device")
        }
        #expect(RemoteGate.evaluate(request("GET", "/"), context(device: false)) == .allow(.page))
        #expect(RemoteGate.evaluate(request("GET", "/app.js"), context(device: false)) == .allow(.script))
    }

    @Test func everyChangeNeedsSameOriginJSONAndTheCSRFHeader() {
        for route in RemoteRoute.allCases where route.changesState && route.requiresDevice {
            let ok = request("POST", route.path, headers: sameOriginJSON, body: "{}")
            #expect(RemoteGate.evaluate(ok, context(device: true)) == .allow(route))

            var noOrigin = sameOriginJSON; noOrigin.removeValue(forKey: "Origin")
            #expect(RemoteGate.evaluate(request("POST", route.path, headers: noOrigin, body: "{}"), context(device: true)) == .reject(403))

            var foreign = sameOriginJSON; foreign["Origin"] = "http://evil.example"
            #expect(RemoteGate.evaluate(request("POST", route.path, headers: foreign, body: "{}"), context(device: true)) == .reject(403))

            var crossSite = sameOriginJSON; crossSite["Sec-Fetch-Site"] = "cross-site"
            #expect(RemoteGate.evaluate(request("POST", route.path, headers: crossSite, body: "{}"), context(device: true)) == .reject(403))

            var form = sameOriginJSON; form["Content-Type"] = "application/x-www-form-urlencoded"
            #expect(RemoteGate.evaluate(request("POST", route.path, headers: form, body: "a=b"), context(device: true)) == .reject(415))

            var noToken = sameOriginJSON; noToken.removeValue(forKey: "X-HeyMate-CSRF")
            #expect(RemoteGate.evaluate(request("POST", route.path, headers: noToken, body: "{}"), context(device: true)) == .reject(403))

            var wrongToken = sameOriginJSON; wrongToken["X-HeyMate-CSRF"] = "expected-csrg"
            #expect(RemoteGate.evaluate(request("POST", route.path, headers: wrongToken, body: "{}"), context(device: true)) == .reject(403))
        }
    }

    @Test func pairingNeedsItsCustomHeaderAndSameOrigin() {
        var headers = sameOriginJSON
        headers.removeValue(forKey: "X-HeyMate-CSRF")
        #expect(RemoteGate.evaluate(request("POST", "/api/pair", headers: headers, body: "{}"), context(device: false)) == .reject(403))
        headers["X-HeyMate-Pair"] = "1"
        #expect(RemoteGate.evaluate(request("POST", "/api/pair", headers: headers, body: "{}"), context(device: false)) == .allow(.pair))
        headers["Origin"] = "http://evil.example"
        #expect(RemoteGate.evaluate(request("POST", "/api/pair", headers: headers, body: "{}"), context(device: false)) == .reject(403))
    }

    @Test func csrfValueIsBoundToTheDeviceToken() {
        let token = RemoteToken.make()
        let other = RemoteToken.make()
        #expect(RemoteToken.csrf(for: token) == RemoteToken.csrf(for: token))
        #expect(RemoteToken.csrf(for: token) != RemoteToken.csrf(for: other))
        #expect(RemoteToken.csrf(for: token) != RemoteToken.hash(token))
    }

    // MARK: Peers and hosts

    @Test func onlyPrivateAndLinkLocalPeersAreAllowed() {
        for allowed in ["10.0.0.5", "172.16.0.1", "172.31.255.254", "192.168.1.9", "169.254.10.10", "100.64.0.1",
                        "100.127.255.1", "fe80::1%en0", "fd7a:115c:a1e0::1", "fc00::2", "::ffff:192.168.1.2", "[fd00::1]"] {
            #expect(RemoteAddressPolicy.isAllowedPeer(literal: allowed), "\(allowed) should be allowed")
        }
        for refused in ["8.8.8.8", "1.1.1.1", "127.0.0.1", "::1", "0.0.0.0", "::", "172.32.0.1", "172.15.255.255",
                        "100.128.0.1", "100.63.255.255", "192.169.0.1", "224.0.0.251", "255.255.255.255",
                        "2001:4860:4860::8888", "ff02::1", "::ffff:8.8.8.8", "::ffff:127.0.0.1", "not-an-ip", "", "192.168.1"] {
            #expect(!RemoteAddressPolicy.isAllowedPeer(literal: refused), "\(refused) should be refused")
        }
        #expect(!RemoteAddressPolicy.isAllowedPeer([192, 168, 1]))
    }

    @Test func allowedHostsAreThisMacsPrivateAddressesAndBonjourName() {
        let hosts = RemoteHostPolicy.allowedHosts(addresses: ["192.168.1.20", "fe80::1c2b%en0", "8.8.8.8", "127.0.0.1"],
                                                  localHostName: "My-Mac", port: 47_821)
        #expect(hosts == ["192.168.1.20:47821", "[fe80::1c2b]:47821", "my-mac.local:47821"])
        #expect(RemoteHostPolicy.allowedHosts(addresses: [], localHostName: "evil.com/x", port: 1).isEmpty)
        #expect(RemoteHostPolicy.isAllowed(hostHeader: " 192.168.1.20:47821 ", allowed: hosts))
        #expect(!RemoteHostPolicy.isAllowed(hostHeader: "192.168.1.20", allowed: hosts))
        #expect(!RemoteHostPolicy.isAllowed(hostHeader: "rebind.example:47821", allowed: hosts))
        #expect(!RemoteHostPolicy.isAllowed(hostHeader: nil, allowed: hosts))
        #expect(RemoteHostPolicy.isSameOrigin(origin: "http://192.168.1.20:47821", host: "192.168.1.20:47821"))
        #expect(!RemoteHostPolicy.isSameOrigin(origin: "https://192.168.1.20:47821", host: "192.168.1.20:47821"))
        #expect(!RemoteHostPolicy.isSameOrigin(origin: "null", host: "192.168.1.20:47821"))
        #expect(!RemoteHostPolicy.isSameOrigin(origin: nil, host: "192.168.1.20:47821"))
    }

    // MARK: Pairing

    @Test func pairingCodeIsSingleUse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var pairing = RemotePairing()
        #expect(pairing.attempt("ABCD2345", now: now) == .noCode)
        pairing.start(code: "ABCD2345", now: now)
        #expect(pairing.isActive(now: now))
        #expect(pairing.attempt("abcd-2345", now: now.addingTimeInterval(10)) == .paired)
        #expect(!pairing.isActive(now: now.addingTimeInterval(10)))
        #expect(pairing.attempt("ABCD2345", now: now.addingTimeInterval(11)) == .noCode)
    }

    @Test func pairingCodeExpires() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var pairing = RemotePairing()
        pairing.start(code: "ABCD2345", now: now)
        let late = now.addingTimeInterval(RemoteAccessPolicy.pairingCodeLifetime)
        #expect(!pairing.isActive(now: late))
        #expect(pairing.attempt("ABCD2345", now: late) == .expired)
        #expect(pairing.attempt("ABCD2345", now: late) == .noCode)
    }

    @Test func wrongCodesLockPairingOut() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var pairing = RemotePairing()
        pairing.start(code: "ABCD2345", now: now)
        for left in stride(from: RemoteAccessPolicy.pairingAttemptsPerCode - 1, through: 1, by: -1) {
            #expect(pairing.attempt("ZZZZZZZZ", now: now) == .wrongCode(attemptsLeft: left))
        }
        let until = now.addingTimeInterval(RemoteAccessPolicy.pairingLockout)
        #expect(pairing.attempt("ZZZZZZZZ", now: now) == .lockedOut(until: until))
        // The right code no longer works: the code is void and pairing is locked.
        #expect(pairing.attempt("ABCD2345", now: now.addingTimeInterval(1)) == .lockedOut(until: until))
        #expect(pairing.isLockedOut(now: now.addingTimeInterval(1)))
        #expect(pairing.attempt("ABCD2345", now: until) == .noCode)
        // Only the Mac can make a new code, which also lifts the lock.
        pairing.start(code: "WXYZ6789", now: now.addingTimeInterval(2))
        #expect(!pairing.isLockedOut(now: now.addingTimeInterval(2)))
        #expect(pairing.attempt("WXYZ6789", now: now.addingTimeInterval(3)) == .paired)
    }

    @Test func pairingCodesUseTheReadableAlphabet() {
        var generator = SeededGenerator(state: 42)
        var seen = Set<String>()
        for _ in 0..<200 {
            let code = RemotePairing.makeCode(using: &generator)
            #expect(code.count == RemoteAccessPolicy.pairingCodeLength)
            #expect(code.allSatisfy { RemoteAccessPolicy.pairingCodeAlphabet.contains($0) })
            #expect(!code.contains("0") && !code.contains("O") && !code.contains("1") && !code.contains("I"))
            seen.insert(code)
        }
        #expect(seen.count == 200)
        #expect(RemotePairing.normalize(" ab cd-23 45 ") == "ABCD2345")
    }

    // MARK: Tokens and devices

    @Test func tokensAreLongRandomAndStoredOnlyAsHashes() {
        let tokens = (0..<50).map { _ in RemoteToken.make() }
        #expect(Set(tokens).count == 50)
        for token in tokens {
            #expect(token.count == 43)
            #expect(RemoteToken.isWellFormed(token))
            let hash = RemoteToken.hash(token)
            #expect(hash.count == 64)
            #expect(hash.allSatisfy { $0.isHexDigit })
            #expect(!hash.contains(token))
        }
        #expect(RemoteToken.hash("a") == "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
        #expect(!RemoteToken.isWellFormed("short"))
        #expect(!RemoteToken.isWellFormed(String(repeating: "a", count: 42) + "="))
    }

    @Test func constantTimeCompare() {
        #expect(RemoteToken.constantTimeEquals("abc", "abc"))
        #expect(RemoteToken.constantTimeEquals("", ""))
        #expect(!RemoteToken.constantTimeEquals("abc", "abd"))
        #expect(!RemoteToken.constantTimeEquals("abc", "abcd"))
        #expect(!RemoteToken.constantTimeEquals("abcd", "abc"))
        #expect(!RemoteToken.constantTimeEquals("", "a"))
        #expect(!RemoteToken.constantTimeEquals("a\u{0}", "a"))
    }

    @Test func deviceMatchUsesTheHashAndExpiresIdlePhones() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let token = RemoteToken.make()
        let phone = RemoteDevice(id: UUID(), name: "iPhone", tokenHash: RemoteToken.hash(token), pairedAt: now, lastSeenAt: now)
        let other = RemoteDevice(id: UUID(), name: "iPad", tokenHash: RemoteToken.hash(RemoteToken.make()), pairedAt: now, lastSeenAt: now)
        #expect(RemoteDeviceRegistry.match(token: token, in: [other, phone], now: now)?.id == phone.id)
        #expect(RemoteDeviceRegistry.match(token: RemoteToken.make(), in: [other, phone], now: now) == nil)
        #expect(RemoteDeviceRegistry.match(token: nil, in: [phone], now: now) == nil)
        #expect(RemoteDeviceRegistry.match(token: phone.tokenHash, in: [phone], now: now) == nil)
        let later = now.addingTimeInterval(RemoteAccessPolicy.deviceIdleExpiry + 1)
        #expect(RemoteDeviceRegistry.match(token: token, in: [phone], now: later) == nil)
        #expect(RemoteDeviceRegistry.pruned([phone], now: later).isEmpty)
    }

    @Test func deviceListIsCappedDroppingTheStalest() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var devices: [RemoteDevice] = []
        for index in 0..<RemoteAccessPolicy.maxDevices {
            devices.append(RemoteDevice(id: UUID(), name: "Phone \(index)", tokenHash: "h\(index)", pairedAt: now,
                                        lastSeenAt: now.addingTimeInterval(Double(index))))
        }
        let newest = RemoteDevice(id: UUID(), name: "New", tokenHash: "n", pairedAt: now, lastSeenAt: now.addingTimeInterval(100))
        let capped = RemoteDeviceRegistry.adding(newest, to: devices)
        #expect(capped.count == RemoteAccessPolicy.maxDevices)
        #expect(capped.contains(newest))
        #expect(!capped.contains(devices[0]))
    }

    @Test func deviceLabelsComeFromTheUserAgentOnly() {
        let iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15"
        #expect(RemoteDeviceRegistry.label(userAgent: iphone, existing: []) == "iPhone")
        let first = RemoteDevice(id: UUID(), name: "iPhone", tokenHash: "x", pairedAt: Date(), lastSeenAt: Date())
        #expect(RemoteDeviceRegistry.label(userAgent: iphone, existing: [first]) == "iPhone 2")
        #expect(RemoteDeviceRegistry.label(userAgent: "Mozilla/5.0 (Linux; Android 15)", existing: []) == "Android phone")
        #expect(RemoteDeviceRegistry.label(userAgent: "<script>alert(1)</script>", existing: []) == "Phone")
        #expect(RemoteDeviceRegistry.label(userAgent: nil, existing: []) == "Phone")
    }

    // MARK: Parsing and limits

    @Test func parserReadsOneBoundedRequest() {
        let raw = "POST /api/messages HTTP/1.1\r\nHost: \(host)\r\nCookie: a=1; hm_phone=tok\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let parsed) = RemoteHTTPParser.parse(Data(raw.utf8)) else {
            Issue.record("expected complete"); return
        }
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/api/messages")
        #expect(parsed.body == Data("{}".utf8))
        #expect(parsed.cookies["hm_phone"] == "tok")
        #expect(RemoteHTTPParser.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)) == .incomplete)
        #expect(RemoteHTTPParser.parse(Data("POST /api/messages HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n{}".utf8)) == .incomplete)

        let query = request("GET", "/api/messages/reply?id=AB%2DCD&x=1&id=other")
        #expect(query.path == "/api/messages/reply")
        #expect(query.query["id"] == "AB-CD")
    }

    @Test func parserRejectsOversizedAndAmbiguousRequests() {
        let bigHeader = "GET / HTTP/1.1\r\nHost: x\r\nX-Pad: " + String(repeating: "a", count: RemoteAccessPolicy.maxHeaderBytes) + "\r\n\r\n"
        #expect(RemoteHTTPParser.parse(Data(bigHeader.utf8)) == .rejected(431))
        #expect(RemoteHTTPParser.parse(Data(String(repeating: "a", count: RemoteAccessPolicy.maxHeaderBytes + 1).utf8)) == .rejected(431))
        let bigBody = "POST /api/messages HTTP/1.1\r\nHost: x\r\nContent-Length: \(RemoteAccessPolicy.maxBodyBytes + 1)\r\n\r\n"
        #expect(RemoteHTTPParser.parse(Data(bigBody.utf8)) == .rejected(413))
        let chunked = "POST /api/messages HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        #expect(RemoteHTTPParser.parse(Data(chunked.utf8)) == .rejected(400))
        let twoHosts = "GET / HTTP/1.1\r\nHost: \(host)\r\nHost: evil.example\r\n\r\n"
        #expect(RemoteHTTPParser.parse(Data(twoHosts.utf8)) == .rejected(400))
        let twoLengths = "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}"
        #expect(RemoteHTTPParser.parse(Data(twoLengths.utf8)) == .rejected(400))
        #expect(RemoteHTTPParser.parse(Data("PUT / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) == .rejected(405))
        #expect(RemoteHTTPParser.parse(Data("GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}".utf8)) == .rejected(400))
        #expect(RemoteHTTPParser.parse(Data("POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}GET".utf8)) == .rejected(400))
        #expect(RemoteHTTPParser.parse(Data("GET http://evil/ HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) == .rejected(400))
        #expect(RemoteHTTPParser.parse(Data("GET / HTTP/2\r\nHost: x\r\n\r\n".utf8)) == .rejected(400))
        #expect(RemoteHTTPParser.parse(Data("GET / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n".utf8)) == .rejected(400))
        #expect(RemoteHTTPParser.parse(Data("GET /é HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) == .rejected(400))
    }

    @Test func rateLimiterRefusesBurstsAndRefills() {
        var limiter = RemoteRateLimiter(capacity: 3, refillPerSecond: 1, maxKeys: 2)
        let now = Date(timeIntervalSince1970: 0)
        var results: [Bool] = []
        for _ in 0..<4 { results.append(limiter.allow("a", now: now)) }
        #expect(results == [true, true, true, false])
        let other = limiter.allow("b", now: now)
        #expect(other)
        let refilled = limiter.allow("a", now: now.addingTimeInterval(1))
        let drained = limiter.allow("a", now: now.addingTimeInterval(1))
        #expect(refilled && !drained)
        let third = limiter.allow("c", now: now.addingTimeInterval(2))
        #expect(third)
        #expect(limiter.trackedKeys <= 2)
        limiter.reset()
        #expect(limiter.trackedKeys == 0)
    }

    // MARK: Responses

    @Test func responsesCarryStrictHeadersAndGenericErrors() {
        let page = String(decoding: RemoteHTTPResponse.text(RemoteAccessPage.html, type: "text/html; charset=utf-8").serialized(), as: UTF8.self)
        #expect(page.contains("Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'"))
        #expect(page.contains("frame-ancestors 'none'"))
        #expect(page.contains("X-Content-Type-Options: nosniff"))
        #expect(page.contains("Cache-Control: no-store"))
        #expect(!RemoteHTTPResponse.contentSecurityPolicy.contains("unsafe"))
        #expect(!RemoteHTTPResponse.contentSecurityPolicy.contains("http"))
        for status in [400, 401, 403, 404, 409, 413, 421, 429, 431, 500] {
            let body = String(decoding: RemoteHTTPResponse.error(status).body, as: UTF8.self)
            #expect(body.hasPrefix("{\"error\":\"") && body.count < 30, "\(status) body must stay generic")
        }
        let cookie = RemoteHTTPResponse.sessionCookie(token: "tok")
        #expect(cookie.contains("HttpOnly") && cookie.contains("SameSite=Strict") && cookie.contains("Path=/"))
        #expect(!cookie.contains("Domain"))
        #expect(RemoteHTTPResponse.clearingCookie.contains("Max-Age=0"))
    }

    @Test func thePageNeverBuildsHTMLFromData() {
        #expect(!RemoteAccessPage.script.contains("innerHTML"))
        #expect(!RemoteAccessPage.script.contains("outerHTML"))
        #expect(!RemoteAccessPage.script.contains("insertAdjacentHTML"))
        #expect(!RemoteAccessPage.script.contains("document.write"))
        #expect(!RemoteAccessPage.script.contains("eval("))
        #expect(!RemoteAccessPage.html.contains("<script>"))
        #expect(!RemoteAccessPage.html.contains("style="))
        #expect(!RemoteAccessPage.html.contains("http://") && !RemoteAccessPage.html.contains("https://"))
        #expect(!RemoteAccessPage.css.contains("url("))
        #expect(!RemoteAccessPage.css.contains("gradient"))
    }

    // MARK: What crosses the wire

    @Test func excludedAppsAreNeverNamed() {
        let names = RemoteRedaction.excludedNames(bundleIDs: ["com.1password.1password", "com.apple.systempreferences", "com.acme.app"],
                                                  displayNames: ["1Password 8"])
        #expect(names.contains("1password"))
        #expect(names.contains("system settings"))
        #expect(!names.contains("app"))
        #expect(RemoteRedaction.line("Rotate the key in 1Password tonight", limit: 200, excludedNames: names) == RemoteRedaction.privateNotice)
        #expect(RemoteRedaction.line("Open System  Settings first", limit: 200, excludedNames: names) == RemoteRedaction.privateNotice)
        #expect(RemoteRedaction.line("Draft the weekly report", limit: 200, excludedNames: names) == "Draft the weekly report")

        let hiddenProposal = RemotePayload.inboxEntry(RemoteInboxInput(id: UUID(), mateName: "Ops", createdAt: Date(),
            source: .proposal(title: "Clean up 1Password vault", whyNow: "Old items")), excludedNames: names)
        #expect(hiddenProposal.actions.isEmpty)
        #expect(hiddenProposal.atMac)
        #expect(hiddenProposal.detail == nil)

        let hiddenQuestion = RemotePayload.inboxEntry(RemoteInboxInput(id: UUID(), mateName: "Ops", createdAt: Date(),
            source: .question(prompt: "Which 1Password vault?", choices: ["Work", "Home"])), excludedNames: names)
        #expect(hiddenQuestion.actions.isEmpty)
        #expect(hiddenQuestion.choices.isEmpty)
    }

    @Test func untrustedTextLosesSecretsPathsAndLinks() {
        let raw = "Saved to /Users/me/Projects/Secret/plan.md\nmail bob@example.com api_key=sk-ant-abc123 see https://x.example/a"
        let line = RemoteRedaction.line(raw, limit: 500, excludedNames: [])
        #expect(!line.contains("/Users/me"))
        #expect(!line.contains("bob@example.com"))
        #expect(!line.contains("sk-ant-abc123"))
        #expect(!line.contains("https://"))
        #expect(!line.contains("\n"))
        #expect(RemoteRedaction.line(String(repeating: "word ", count: 100), limit: 20, excludedNames: []).count == 20)
        let reply = RemotePayload.reply(.finished("Done.\nFile at ~/Projects/x.txt"), excludedNames: [])
        #expect(reply.state == "done")
        #expect(reply.text?.contains("~/Projects") == false)
        #expect(reply.text?.contains("\n") == true)
    }

    @Test func inboxEntriesSendOnlyTheMinimum() {
        let id = UUID()
        let at = Date(timeIntervalSince1970: 3_000_000)
        let proposal = RemotePayload.inboxEntry(RemoteInboxInput(id: id, mateName: "Writer\nInjected", createdAt: at,
            source: .proposal(title: "Draft the newsletter", whyNow: "It's Thursday.\nSecond line")), excludedNames: [])
        #expect(proposal == RemoteInboxEntry(id: id.uuidString, mate: "Writer Injected", kind: "proposal", title: "Draft the newsletter",
            detail: "It's Thursday. Second line", choices: [], actions: ["approve", "skip"], atMac: false, createdAt: at))

        let question = RemotePayload.inboxEntry(RemoteInboxInput(id: id, mateName: "Ops", createdAt: at,
            source: .question(prompt: "Which day?", choices: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])), excludedNames: [])
        #expect(question.actions == ["answer"])
        #expect(question.choices.count == 6)

        for source in [RemoteInboxSource.signIn(site: "github.com"), .routineFailed(summary: "Timed out"), .waitingForPermission] {
            let entry = RemotePayload.inboxEntry(RemoteInboxInput(id: id, mateName: "Ops", createdAt: at, source: source), excludedNames: [])
            #expect(entry.actions.isEmpty, "\(source) is not actionable remotely")
            #expect(entry.atMac)
        }
        let permission = RemotePayload.inboxEntry(RemoteInboxInput(id: id, mateName: "Ops", createdAt: at, source: .waitingForPermission), excludedNames: [])
        #expect(permission.detail == nil)
    }

    @Test func mateStatusAndLastLine() {
        let id = UUID()
        func entry(working: Bool, waiting: Bool, line: String?) -> RemoteMateEntry {
            RemotePayload.mateEntry(RemoteMateInput(id: id, name: "Ops", isWorking: working, isWaiting: waiting, lastLine: line), excludedNames: [])
        }
        #expect(entry(working: false, waiting: false, line: nil).status == "idle")
        #expect(entry(working: true, waiting: false, line: nil).status == "working")
        #expect(entry(working: true, waiting: true, line: nil).status == "waiting")
        #expect(entry(working: false, waiting: false, line: "Sent 3 invoices.\nDetails follow").line == "Sent 3 invoices.")
        #expect(entry(working: false, waiting: false, line: "   ").line == nil)
    }

    @Test func replyStatesMapToPlainWords() {
        #expect(RemotePayload.reply(.queued, excludedNames: []) == RemoteReplyPayload(state: "queued", text: nil))
        #expect(RemotePayload.reply(.working, excludedNames: []).state == "working")
        #expect(RemotePayload.reply(.waitingAtMac, excludedNames: []).state == "atMac")
        #expect(RemotePayload.reply(.needsAnswer, excludedNames: []).state == "question")
        #expect(RemotePayload.reply(.failed("Network\nerror"), excludedNames: []) == RemoteReplyPayload(state: "failed", text: "Network error"))
    }

    @Test func remoteActionLogKeepsTheNewestFifty() {
        var log: [RemoteAuditEntry] = []
        for index in 0..<60 {
            log = RemoteAuditEntry.appending(RemoteAuditEntry(id: UUID(), date: Date(timeIntervalSince1970: Double(index)),
                                                              device: "iPhone", action: "a\(index)"), to: log)
        }
        #expect(log.count == RemoteAuditEntry.kept)
        #expect(log.first?.action == "a59")
    }
}
