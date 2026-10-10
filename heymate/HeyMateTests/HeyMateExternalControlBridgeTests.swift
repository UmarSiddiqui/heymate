//
//  HeyMateExternalControlBridgeTests.swift
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
struct HeyMateExternalControlBridgeTests {

    @Test func healthPathParsesAndRoutes() {
        let raw = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let parsed = HeyMateExternalControlHTTPRequest.parse(Data(raw.utf8))

        guard case .request(let request) = parsed else {
            Issue.record("Expected a parsed health request")
            return
        }
        #expect(request.method == "GET")
        #expect(request.path == "/health")
        #expect(request.body.isEmpty)

        let route = HeyMateExternalControlRouter.route(
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
        let parsed = HeyMateExternalControlHTTPRequest.parse(Data(raw.utf8))

        guard case .request(let request) = parsed else {
            Issue.record("Expected a parsed cursor request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/cursor")

        let route = HeyMateExternalControlRouter.route(
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
        let route = HeyMateExternalControlRouter.route(
            method: "POST",
            path: "/cursor",
            json: ["caption": "no point"]
        )
        #expect(route == .rejected(statusCode: 400, message: "Missing x and y"))
    }

    @Test func cursorRejectsNonFiniteCoordinates() {
        let route = HeyMateExternalControlRouter.route(
            method: "POST",
            path: "/cursor",
            json: ["x": "NaN", "y": "Infinity"]
        )
        #expect(route == .rejected(statusCode: 400, message: "Missing x and y"))
    }

    @Test func clickPathIsNotAFeature() {
        let route = HeyMateExternalControlRouter.route(
            method: "POST",
            path: "/click",
            json: ["x": 10, "y": 20]
        )
        #expect(route == .rejected(statusCode: 404, message: "Unknown endpoint"))
    }

    @Test func clickShapedCursorPayloadIsRejected() {
        let route = HeyMateExternalControlRouter.route(
            method: "POST",
            path: "/cursor",
            json: ["x": 10, "y": 20, "click": true]
        )
        #expect(route == .rejected(statusCode: 400, message: "Click is not supported"))
    }

    @Test func captionAndSpeakAndClearRoute() {
        #expect(
            HeyMateExternalControlRouter.route(
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
            HeyMateExternalControlRouter.route(
                method: "POST",
                path: "/speak",
                json: ["text": "hello"]
            ) == .accepted(.speak(text: "hello"))
        )
        #expect(
            HeyMateExternalControlRouter.route(
                method: "POST",
                path: "/clear",
                json: [:]
            ) == .accepted(.clear)
        )
    }

    @Test func connectorRoutesCarryTheToolAndItsRawArguments() {
        let route = HeyMateExternalControlRouter.route(
            method: "POST",
            path: "/connector/call",
            json: ["tool": "composio__COMPOSIO_SEARCH_TOOLS", "arguments": #"{"query":"youtube"}"#]
        )
        #expect(route == .accepted(.callConnectorTool(
            namespacedID: "composio__COMPOSIO_SEARCH_TOOLS",
            argumentsJSON: #"{"query":"youtube"}"#
        )))

        #expect(HeyMateExternalControlRouter.route(
            method: "POST",
            path: "/connector/tools",
            json: [:]
        ) == .accepted(.listConnectorTools))

        // A call with no tool named is a bad request, never a call against
        // whatever happens to be first in the list.
        #expect(HeyMateExternalControlRouter.route(
            method: "POST",
            path: "/connector/call",
            json: ["arguments": "{}"]
        ) == .rejected(statusCode: 400, message: "Missing tool"))
    }

    /// A job cannot edit HeyMate's configuration from its sandbox, so this
    /// route is how an approved plan actually adds a mate.
    @Test func mateCreateRoutesWithOptionalNameAndRequiresAToken() {
        #expect(HeyMateExternalControlRouter.route(
            method: "POST",
            path: "/mate/create",
            json: ["name": " Ledger ", "job": " Keeps my monthly budget "]
        ) == .accepted(.createMate(name: "Ledger", job: "Keeps my monthly budget")))

        #expect(HeyMateExternalControlRouter.route(
            method: "POST",
            path: "/mate/create",
            json: ["name": "  ", "job": "Tracks my running"]
        ) == .accepted(.createMate(name: nil, job: "Tracks my running")))

        #expect(HeyMateExternalControlRouter.route(
            method: "POST",
            path: "/mate/create",
            json: ["name": "Ledger"]
        ) == .rejected(statusCode: 400, message: "Missing job"))

        #expect(HeyMateExternalControlCommand.createMate(name: nil, job: "x").touchesConnectedAccounts)
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
        #expect(HeyMateExternalControlCommand.listConnectorTools.touchesConnectedAccounts)
        #expect(HeyMateExternalControlCommand.callConnectorTool(
            namespacedID: "composio__X",
            argumentsJSON: "{}"
        ).touchesConnectedAccounts)
        #expect(HeyMateExternalControlCommand.clear.touchesConnectedAccounts == false)

        #expect(HeyMateExternalControlAuth.isAuthorizedForConnectedAccounts(
            headers: [:],
            expectedToken: nil
        ) == false)
        #expect(HeyMateExternalControlAuth.isAuthorizedForConnectedAccounts(
            headers: [:],
            expectedToken: "tok"
        ) == false)
        #expect(HeyMateExternalControlAuth.isAuthorizedForConnectedAccounts(
            headers: ["authorization": "Bearer tok"],
            expectedToken: "tok"
        ))
        #expect(HeyMateExternalControlAuth.isAuthorizedForConnectedAccounts(
            headers: ["x-heymate-token": "wrong"],
            expectedToken: "tok"
        ) == false)
    }

    @Test func defaultPortIsHeyMatesOwn() {
        #expect(HeyMateExternalControlBridge.defaultPort == 18732)
        #expect(
            HeyMateExternalControlBridge.resolvedPort(environment: [:]) == 18732
        )
        #expect(
            HeyMateExternalControlBridge.resolvedPort(
                environment: ["HEYMATE_BRIDGE_PORT": "19001"]
            ) == 19001
        )
        #expect(HeyMateExternalControlLoopback.isAllowed(host: "127.0.0.1"))
        #expect(!HeyMateExternalControlLoopback.isAllowed(host: "8.8.8.8"))
    }

    @Test func occupiedDefaultGetsAProcessLocalFallback() {
        let selected = HeyMateExternalControlBridge.selectAvailablePort(
            preferredPort: 18732,
            isAvailable: { _ in false },
            fallbackPort: { 49152 }
        )
        #expect(selected == 49152)
    }

    @Test func availableDefaultStaysStableForExternalClients() {
        let selected = HeyMateExternalControlBridge.selectAvailablePort(
            preferredPort: 18732,
            isAvailable: { $0 == 18732 },
            fallbackPort: { 49152 }
        )
        #expect(selected == 18732)
    }

    @Test func missingBridgeTokenIsAuthorizedWhenNoneIsConfigured() {
        #expect(
            HeyMateExternalControlAuth.isAuthorized(
                headers: [:],
                configuredToken: nil
            )
        )
    }

    @Test func configuredBridgeTokenRequiresBearerOrHeader() {
        #expect(
            !HeyMateExternalControlAuth.isAuthorized(
                headers: [:],
                configuredToken: "secret-token"
            )
        )
        #expect(
            HeyMateExternalControlAuth.isAuthorized(
                headers: ["authorization": "Bearer secret-token"],
                configuredToken: "secret-token"
            )
        )
        #expect(
            HeyMateExternalControlAuth.isAuthorized(
                headers: ["x-heymate-token": "secret-token"],
                configuredToken: "secret-token"
            )
        )
        #expect(
            !HeyMateExternalControlAuth.isAuthorized(
                headers: ["authorization": "Bearer other"],
                configuredToken: "secret-token"
            )
        )
    }
}
