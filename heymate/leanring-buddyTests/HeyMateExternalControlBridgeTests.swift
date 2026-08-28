//
//  HeyMateExternalControlBridgeTests.swift
//  leanring-buddyTests
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

    @Test func defaultPortIsNotOpenClickyPort() {
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
