//
//  AgentUserNotifierTests.swift
//  leanring-buddyTests
//

import Testing
@testable import HeyMate

struct AgentUserNotifierTests {
    @Test func mapsOnlyMilestonesThatNeedAttention() {
        #expect(AgentNotificationPayload.make(for: .started, runTitle: "Ship it") == nil)
        #expect(AgentNotificationPayload.make(for: .tool(summary: "Reading"), runTitle: "Ship it") == nil)
        #expect(
            AgentNotificationPayload.make(for: .planReady(text: "Plan"), runTitle: "Ship it")
                == AgentNotificationPayload(
                    kind: .planReady,
                    title: "Plan ready",
                    body: "Ship it is waiting for your approval."
                )
        )
        #expect(
            AgentNotificationPayload.make(
                for: .approvalRequested(id: "tool-1", summary: "Allow writing Package.swift"),
                runTitle: "Ship it"
            )?.title == "Agent needs approval"
        )
        #expect(
            AgentNotificationPayload.make(for: .finished(summary: "All tests pass"), runTitle: "Ship it")
                == AgentNotificationPayload(
                    kind: .finished,
                    title: "Agent finished",
                    body: "All tests pass"
                )
        )
        #expect(
            AgentNotificationPayload.make(for: .failed(message: "Signed out"), runTitle: "Ship it")
                == AgentNotificationPayload(
                    kind: .failed,
                    title: "Agent stopped",
                    body: "Signed out"
                )
        )
    }

    @Test func bodyIsSingleLineAndBounded() {
        let longBody = Array(repeating: "word", count: 100).joined(separator: "\n")
        let payload = AgentNotificationPayload.make(
            for: .finished(summary: longBody),
            runTitle: "Task"
        )
        #expect(payload?.body.contains("\n") == false)
        #expect((payload?.body.count ?? 0) <= 180)
    }
}
