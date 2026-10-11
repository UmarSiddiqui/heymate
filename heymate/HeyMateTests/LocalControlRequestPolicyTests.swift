//
//  LocalControlRequestPolicyTests.swift
//  HeyMateTests
//
//  The bridge refuses requests a web page could make: foreign Host (DNS
//  rebinding), foreign Origin, and bodies that aren't JSON (no-preflight
//  cross-site POSTs).
//

import Foundation
import Testing
@testable import HeyMate

struct LocalControlRequestPolicyTests {

    private func request(_ headerLines: [String], body: String = "") -> LocalControlHTTPRequest {
        var raw = "POST /caption HTTP/1.1\r\n" + headerLines.joined(separator: "\r\n")
        raw += "\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        guard case .request(let parsed) = LocalControlHTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("request did not parse")
            fatalError()
        }
        return parsed
    }

    @Test func heyMatesOwnClientIsAllowed() {
        let allowed = request(["Host: 127.0.0.1:18732", "Content-Type: application/json"], body: #"{"text":"hi"}"#)
        #expect(LocalControlRequestPolicy.refusal(for: allowed) == nil)
    }

    @Test func rebindingHostIsRefused() {
        let rebound = request(["Host: attacker.example:18732", "Content-Type: application/json"], body: "{}")
        #expect(LocalControlRequestPolicy.refusal(for: rebound) != nil)
    }

    @Test func missingHostIsRefused() {
        #expect(LocalControlRequestPolicy.refusal(for: request(["Content-Type: application/json"], body: "{}")) != nil)
    }

    @Test func foreignOriginIsRefused() {
        let crossSite = request(
            ["Host: 127.0.0.1:18732", "Origin: https://evil.example", "Content-Type: application/json"],
            body: "{}"
        )
        #expect(LocalControlRequestPolicy.refusal(for: crossSite) != nil)
        #expect(!LocalControlRequestPolicy.isLoopbackOrigin("null"))
    }

    @Test func simpleCrossSitePostIsRefused() {
        let plain = request(["Host: 127.0.0.1:18732", "Content-Type: text/plain"], body: #"{"text":"hi"}"#)
        #expect(LocalControlRequestPolicy.refusal(for: plain) != nil)
    }

    @Test func loopbackAuthorities() {
        #expect(LocalControlRequestPolicy.isLoopbackAuthority("localhost"))
        #expect(LocalControlRequestPolicy.isLoopbackAuthority("[::1]:18732"))
        #expect(!LocalControlRequestPolicy.isLoopbackAuthority("127.0.0.1.evil.example"))
        #expect(!LocalControlRequestPolicy.isLoopbackAuthority("127.0.0.1:80:90"))
        #expect(LocalControlRequestPolicy.isLoopbackOrigin("http://localhost:3000"))
    }
}
