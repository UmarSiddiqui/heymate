//
//  LocalControlTests.swift
//  HeyMateTests
//
//  Parser/router tests for the loopback control bridge. No live listener
//  and no window-server choreography — HTTP bytes in, route/command out.
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct LocalControlTests {

    @Test func healthPathParsesAndRoutes() {
        let raw = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let parsed = LocalControlHTTPRequest.parse(Data(raw.utf8))

        guard case .request(let request) = parsed else {
            Issue.record("Expected a parsed health request")
            return
        }
        #expect(request.method == "GET")
        #expect(request.path == "/health")
        #expect(request.body.isEmpty)

        let route = LocalControlRouter.route(
            method: request.method,
            path: request.path,
            json: request.jsonBody
        )
        #expect(route == .accepted(.health))
    }

    @Test func cursorJSONRoutesToShowCursor() {
        let body = #"{"x":120,"y":340,"caption":"the button","durationMs":1500}"#
        let raw = """
        POST /cursor HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """
        let parsed = LocalControlHTTPRequest.parse(Data(raw.utf8))

        guard case .request(let request) = parsed else {
            Issue.record("Expected a parsed cursor request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/cursor")

        let route = LocalControlRouter.route(
            method: request.method,
            path: request.path,
            json: request.jsonBody
        )
        #expect(
            route == .accepted(.showCursor(
                point: CGPoint(x: 120, y: 340),
                caption: "the button",
                duration: 1.5
            ))
        )
    }

    @Test func cursorRejectsMissingCoordinates() {
        let route = LocalControlRouter.route(
            method: "POST",
            path: "/cursor",
            json: ["caption": "no point"]
        )
        #expect(route == .rejected(statusCode: 400, message: "Missing x and y"))
    }

    @Test func cursorRejectsNonFiniteCoordinates() {
        let route = LocalControlRouter.route(
            method: "POST",
            path: "/cursor",
            json: ["x": "NaN", "y": "Infinity"]
        )
        #expect(route == .rejected(statusCode: 400, message: "Missing x and y"))
    }

    @Test func clickPathIsNotAFeature() {
        let route = LocalControlRouter.route(
            method: "POST",
            path: "/click",
            json: ["x": 10, "y": 20]
        )
        #expect(route == .rejected(statusCode: 404, message: "Unknown endpoint"))
    }

    @Test func clickShapedCursorPayloadIsRejected() {
        let route = LocalControlRouter.route(
            method: "POST",
            path: "/cursor",
            json: ["x": 10, "y": 20, "click": true]
        )
        #expect(route == .rejected(statusCode: 400, message: "Click is not supported"))
    }

    @Test func captionAndSpeakAndClearRoute() {
        #expect(
            LocalControlRouter.route(
                method: "POST",
                path: "/caption",
                json: ["text": "look here", "x": 8, "y": 16]
            ) == .accepted(.showCaption(
                text: "look here",
                point: CGPoint(x: 8, y: 16),
                duration: 4
            ))
        )
        #expect(
            LocalControlRouter.route(
                method: "POST",
                path: "/speak",
                json: ["text": "hello"]
            ) == .accepted(.speak(text: "hello"))
        )
        #expect(
            LocalControlRouter.route(
                method: "POST",
                path: "/clear",
                json: [:]
            ) == .accepted(.clear)
        )
    }

    @Test func connectorRoutesCarryTheToolAndItsRawArguments() {
        let route = LocalControlRouter.route(
            method: "POST",
            path: "/connector/call",
            json: ["tool": "composio__COMPOSIO_SEARCH_TOOLS", "arguments": #"{"query":"youtube"}"#]
        )
        #expect(route == .accepted(.callConnectorTool(
            namespacedID: "composio__COMPOSIO_SEARCH_TOOLS",
            argumentsJSON: #"{"query":"youtube"}"#
        )))

        #expect(LocalControlRouter.route(
            method: "POST",
            path: "/connector/tools",
            json: [:]
        ) == .accepted(.listConnectorTools))

        // A call with no tool named is a bad request, never a call against
        // whatever happens to be first in the list.
        #expect(LocalControlRouter.route(
            method: "POST",
            path: "/connector/call",
            json: ["arguments": "{}"]
        ) == .rejected(statusCode: 400, message: "Missing tool"))
    }

    /// A job cannot edit HeyMate's configuration from its sandbox, so this
    /// route is how an approved plan actually adds a mate.
    @Test func mateCreateRoutesWithOptionalNameAndRequiresAToken() {
        #expect(LocalControlRouter.route(
            method: "POST",
            path: "/mate/create",
            json: ["name": " Ledger ", "job": " Keeps my monthly budget "]
        ) == .accepted(.createMate(name: "Ledger", job: "Keeps my monthly budget")))

        #expect(LocalControlRouter.route(
            method: "POST",
            path: "/mate/create",
            json: ["name": "  ", "job": "Tracks my running"]
        ) == .accepted(.createMate(name: nil, job: "Tracks my running")))

        #expect(LocalControlRouter.route(
            method: "POST",
            path: "/mate/create",
            json: ["name": "Ledger"]
        ) == .rejected(statusCode: 400, message: "Missing job"))

        #expect(LocalControlCommand.createMate(name: nil, job: "x").touchesConnectedAccounts)
        #expect(HeyMateMCPServer.toolNames.contains("heymate_create_mate"))
        #expect(HeyMateMCPServer.serverSource.contains("name: \"heymate_create_mate\""))
    }

    /// A CLI exits 0 whether or not the plan got done, so the final-message
    /// marker is what keeps a blocked job from reading as "Work completed".
    @Test func blockedMarkerIsReadOnlyFromTheStartOfTheFinalMessage() {
        #expect(headlessAgentExecuteInstruction.contains(headlessAgentBlockedMarker))
        #expect(headlessAgentReportsBlocked("\n  HEYMATE_BLOCKED: no permission to write mates.json"))
        #expect(!headlessAgentReportsBlocked("Created three mates."))
        #expect(!headlessAgentReportsBlocked("Done. I avoided HEYMATE_BLOCKED: entirely."))
    }

    /// Pointing at the screen is harmless if some other local process does
    /// it; reading the user's mail is not. So the connector routes cannot
    /// inherit the "no token configured means everyone is welcome" rule.
    @Test func connectorRoutesRefuseWhenNoTokenIsResolved() {
        #expect(LocalControlCommand.listConnectorTools.touchesConnectedAccounts)
        #expect(LocalControlCommand.callConnectorTool(
            namespacedID: "composio__X",
            argumentsJSON: "{}"
        ).touchesConnectedAccounts)
        #expect(LocalControlCommand.clear.touchesConnectedAccounts == false)

        #expect(LocalControlAuth.isAuthorizedForConnectedAccounts(
            headers: [:],
            expectedToken: nil
        ) == false)
        #expect(LocalControlAuth.isAuthorizedForConnectedAccounts(
            headers: [:],
            expectedToken: "tok"
        ) == false)
        #expect(LocalControlAuth.isAuthorizedForConnectedAccounts(
            headers: ["authorization": "Bearer tok"],
            expectedToken: "tok"
        ))
        #expect(LocalControlAuth.isAuthorizedForConnectedAccounts(
            headers: ["x-heymate-token": "wrong"],
            expectedToken: "tok"
        ) == false)
    }

    @Test func defaultPortIsHeyMatesOwn() {
        #expect(LocalControlPort.defaultPort == 18732)
        #expect(
            LocalControlPort.configured(environment: [:]) == 18732
        )
        #expect(
            LocalControlPort.configured(
                environment: ["HEYMATE_BRIDGE_PORT": "19001"]
            ) == 19001
        )
        #expect(LocalControlLoopback.isAllowed(host: "127.0.0.1"))
        #expect(!LocalControlLoopback.isAllowed(host: "8.8.8.8"))
    }

    @Test func occupiedDefaultGetsAProcessLocalFallback() {
        let selected = LocalControlPort.choose(
            preferred: 18732,
            isFree: { _ in false },
            fallback: { 49152 }
        )
        #expect(selected == 49152)
    }

    @Test func availableDefaultStaysStableForExternalClients() {
        let selected = LocalControlPort.choose(
            preferred: 18732,
            isFree: { $0 == 18732 },
            fallback: { 49152 }
        )
        #expect(selected == 18732)
    }

    @Test func missingBridgeTokenIsAuthorizedWhenNoneIsConfigured() {
        #expect(
            LocalControlAuth.isAuthorized(
                headers: [:],
                configuredToken: nil
            )
        )
    }

    @Test func configuredBridgeTokenRequiresBearerOrHeader() {
        #expect(
            !LocalControlAuth.isAuthorized(
                headers: [:],
                configuredToken: "secret-token"
            )
        )
        #expect(
            LocalControlAuth.isAuthorized(
                headers: ["authorization": "Bearer secret-token"],
                configuredToken: "secret-token"
            )
        )
        #expect(
            LocalControlAuth.isAuthorized(
                headers: ["x-heymate-token": "secret-token"],
                configuredToken: "secret-token"
            )
        )
        #expect(
            !LocalControlAuth.isAuthorized(
                headers: ["authorization": "Bearer other"],
                configuredToken: "secret-token"
            )
        )
    }

    @Test func tokenComparisonMatchesOnlyIdenticalTokens() {
        #expect(LocalControlAuth.constantTimeEqual("secret-token", "secret-token"))
        #expect(!LocalControlAuth.constantTimeEqual("secret-token", "secret-tokem"))
        #expect(!LocalControlAuth.constantTimeEqual("secret", "secret-token"))
        #expect(!LocalControlAuth.constantTimeEqual("", "x"))
        #expect(LocalControlAuth.constantTimeEqual("", ""))
    }

    @Test func requestsSmugglingASecondLengthOrChunkedBodyAreRefused() {
        let doubleLength = "POST /clear HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}"
        guard case .malformed = LocalControlHTTPRequest.parse(Data(doubleLength.utf8)) else {
            Issue.record("Two Content-Length headers must be refused")
            return
        }
        let chunked = "POST /clear HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        guard case .malformed = LocalControlHTTPRequest.parse(Data(chunked.utf8)) else {
            Issue.record("Chunked bodies must be refused")
            return
        }
        let partial = "POST /clear HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"
        guard case .incomplete = LocalControlHTTPRequest.parse(Data(partial.utf8)) else {
            Issue.record("A short body means wait for more")
            return
        }
    }
}
