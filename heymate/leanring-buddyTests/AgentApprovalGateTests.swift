//
//  AgentApprovalGateTests.swift
//  leanring-buddyTests
//
//  The two-leg gate: leg one plans read-only, the user approves, leg two
//  resumes the same session and writes. These tests pin the argument vectors,
//  because the whole promise rests on leg one being unable to write and leg
//  two being the same conversation the user read.
//

import Foundation
import Testing
@testable import HeyMate

struct AgentApprovalLaunchSpecTests {

    @Test func explicitExecutorRequestOverridesSelectionWithoutMatchingProductNames() {
        #expect(HeadlessExecutor.explicitlyRequested(in: "Use OpenCode to build it") == .openCode)
        #expect(HeadlessExecutor.explicitlyRequested(in: "using Codex, fix this") == .codex)
        #expect(HeadlessExecutor.explicitlyRequested(in: "with Claude Code make a site") == .claudeCode)
        #expect(HeadlessExecutor.explicitlyRequested(in: "build an OpenCode dashboard") == nil)
    }

    private let workspaceURL = URL(fileURLWithPath: "/tmp/heymate-gate-test", isDirectory: true)
    private let sessionIdentifier = "4662b1f8-8da1-4865-a3a2-ecd91d20cbb0"

    private func claudeSpec(leg: AgentRunLeg, origin: AgentRunOrigin = .sandbox) -> HeadlessCLILaunchSpec {
        HeadlessCLIAdapterFactory.adapter(for: .claudeCode).launchSpec(
            workspaceURL: workspaceURL,
            leg: leg,
            origin: origin,
            title: "build a landing page",
            sessionIdentifier: sessionIdentifier
        )
    }

    private func openCodeSpec(
        leg: AgentRunLeg,
        origin: AgentRunOrigin = .sandbox,
        sessionIdentifier: String = ""
    ) -> HeadlessCLILaunchSpec {
        HeadlessCLIAdapterFactory.adapter(for: .openCode, openCodeModelIdentifier: nil).launchSpec(
            workspaceURL: workspaceURL,
            leg: leg,
            origin: origin,
            title: "build a landing page",
            sessionIdentifier: sessionIdentifier
        )
    }

    /// If leg one ever gains write permission, the gate is decoration.
    @Test func claudePlanLegIsReadOnlyAndAssignsTheSession() {
        let arguments = claudeSpec(leg: .plan(prompt: "build a landing page")).arguments
        #expect(arguments.contains("--permission-mode"))
        #expect(arguments.contains("plan"))
        #expect(arguments.contains("acceptEdits") == false)
        #expect(arguments.contains("--session-id"))
        #expect(arguments.contains(sessionIdentifier))
        #expect(arguments.contains("--resume") == false)
    }

    /// Leg two must resume, not restart. A fresh session would execute work
    /// nobody read a plan for.
    @Test func claudeExecuteLegResumesTheApprovedSession() {
        let arguments = claudeSpec(leg: .execute).arguments
        #expect(arguments.contains("--resume"))
        #expect(arguments.contains(sessionIdentifier))
        #expect(arguments.contains("--session-id") == false)
        #expect(arguments.contains("acceptEdits"))
        #expect(arguments.contains(headlessAgentExecuteInstruction))
    }

    @Test func claudeReplanLegStaysReadOnlyInTheSameSession() {
        let arguments = claudeSpec(leg: .replan(feedback: "use two columns")).arguments
        #expect(arguments.contains("--resume"))
        #expect(arguments.contains(sessionIdentifier))
        #expect(arguments.contains("plan"))
        #expect(arguments.contains("use two columns"))
        #expect(arguments.contains("acceptEdits") == false)
    }

    /// An attached folder keeps per-tool approval on top of the plan gate,
    /// which is the one place duplex stdin is needed.
    @Test func claudeAttachedExecuteKeepsPerToolApproval() {
        let spec = claudeSpec(leg: .execute, origin: .attached)
        #expect(spec.arguments.contains("manual"))
        #expect(spec.arguments.contains("--input-format"))
        #expect(spec.usesDuplexStandardInput)
    }

    @Test func claudePlanLegNeverNeedsDuplexStandardInput() {
        #expect(claudeSpec(leg: .plan(prompt: "x"), origin: .attached).usesDuplexStandardInput == false)
    }

    /// OpenCode's `plan` agent answers with a plan and calls no write tools.
    @Test func openCodePlanLegUsesThePlanAgentAndNoSession() {
        let arguments = openCodeSpec(leg: .plan(prompt: "build a landing page")).arguments
        #expect(arguments.contains("--agent"))
        #expect(arguments.contains("plan"))
        #expect(arguments.contains("--session") == false)
        #expect(arguments.contains("--auto") == false)
    }

    @Test func openCodeExecuteLegResumesTheSessionAndEnablesWrites() {
        let arguments = openCodeSpec(leg: .execute, sessionIdentifier: "ses_abc123").arguments
        #expect(arguments.contains("--session"))
        #expect(arguments.contains("ses_abc123"))
        #expect(arguments.contains("--auto"))
        #expect(arguments.contains("--agent") == false)
        #expect(arguments.contains(headlessAgentExecuteInstruction))
    }

    @Test func openCodeAttachedExecuteDoesNotAutoApprove() {
        let arguments = openCodeSpec(
            leg: .execute,
            origin: .attached,
            sessionIdentifier: "ses_abc123"
        ).arguments
        #expect(arguments.contains("--auto") == false)
    }

    @Test func onlyClaudeCodePreassignsItsSession() {
        #expect(HeadlessCLIAdapterFactory.adapter(for: .claudeCode).preassignsSessionIdentifier)
        #expect(HeadlessCLIAdapterFactory.adapter(for: .openCode).preassignsSessionIdentifier == false)
    }
}

struct AgentFollowUpTests {

    private let workspaceURL = URL(fileURLWithPath: "/tmp/heymate-gate-test", isDirectory: true)

    /// "Also make it dark mode" has to land in the session that built the
    /// thing, or the agent is a stranger being asked to extend work it has
    /// never seen.
    @Test func claudeFollowUpResumesTheSessionAndStaysReadOnly() {
        let arguments = HeadlessCLIAdapterFactory.adapter(for: .claudeCode).launchSpec(
            workspaceURL: workspaceURL,
            leg: .followUp(instruction: "also add a dark mode"),
            origin: .sandbox,
            title: "build a landing page",
            sessionIdentifier: "4662b1f8-8da1-4865-a3a2-ecd91d20cbb0"
        ).arguments

        #expect(arguments.contains("--resume"))
        #expect(arguments.contains("4662b1f8-8da1-4865-a3a2-ecd91d20cbb0"))
        #expect(arguments.contains("plan"))
        #expect(arguments.contains("acceptEdits") == false)
        #expect(arguments.contains("also add a dark mode"))
    }

    @Test func openCodeFollowUpResumesTheSessionWithThePlanAgent() {
        let arguments = HeadlessCLIAdapterFactory.adapter(for: .openCode).launchSpec(
            workspaceURL: workspaceURL,
            leg: .followUp(instruction: "also add a dark mode"),
            origin: .sandbox,
            title: "build a landing page",
            sessionIdentifier: "ses_abc123"
        ).arguments

        #expect(arguments.contains("--session"))
        #expect(arguments.contains("ses_abc123"))
        #expect(arguments.contains("--agent"))
        #expect(arguments.contains("plan"))
        #expect(arguments.contains("--auto") == false)
    }

    @Test func onlyTheFirstPlanOpensAFreshSession() {
        #expect(AgentRunLeg.plan(prompt: "x").resumesSession == false)
        #expect(AgentRunLeg.execute.resumesSession)
        #expect(AgentRunLeg.replan(feedback: "x").resumesSession)
        #expect(AgentRunLeg.followUp(instruction: "x").resumesSession)
    }

    /// A follow-up is more work, so it goes through the gate like everything
    /// else rather than executing straight away.
    @Test func followUpIsReadOnly() {
        #expect(AgentRunLeg.followUp(instruction: "x").isReadOnly)
    }
}

struct HeyMateMCPServerTests {

    private let workspaceURL = URL(fileURLWithPath: "/tmp/heymate-gate-test", isDirectory: true)
    private let mcpConfiguration = #"{"mcpServers":{"heymate":{"command":"/usr/bin/node","args":["/tmp/heymate-mcp.mjs"]}}}"#

    /// Verified against a live child: without the allow-list, the call is
    /// refused with "you haven't granted it yet" and never reaches the bridge.
    @Test func toolNamesAreNamespacedTheWayClaudeCodeExpects() {
        let names = HeyMateMCPServer.claudeCodeToolNames()
        #expect(names.contains("mcp__heymate__heymate_point"))
        #expect(names.count == HeyMateMCPServer.toolNames.count)
        #expect(names.allSatisfy { $0.hasPrefix("mcp__heymate__") })
    }

    /// The bridge refuses click, drag, and type. The server must not smuggle
    /// them back in under a different name.
    @Test func noToolCanPressAnything() {
        for name in HeyMateMCPServer.toolNames {
            #expect(name.contains("click") == false)
            #expect(name.contains("drag") == false)
            #expect(name.contains("type") == false)
        }
    }

    private func claudeArguments(leg: AgentRunLeg) -> [String] {
        HeadlessCLIAdapterFactory.adapter(
            for: .claudeCode,
            mcpConfigurationJSON: mcpConfiguration
        ).launchSpec(
            workspaceURL: workspaceURL,
            leg: leg,
            origin: .sandbox,
            title: "build a landing page",
            sessionIdentifier: "4662b1f8-8da1-4865-a3a2-ecd91d20cbb0"
        ).arguments
    }

    @Test func theWorkingLegGetsTheHeyMateTools() {
        let arguments = claudeArguments(leg: .execute)
        #expect(arguments.contains("--mcp-config"))
        #expect(arguments.contains(mcpConfiguration))
        #expect(arguments.contains("--allowedTools"))
        #expect(arguments.contains("mcp__heymate__heymate_point"))
    }

    /// Otherwise a sandbox job inherits every MCP server the user configured
    /// for their own Claude Code — Gmail, Stripe, Figma.
    @Test func theChildGetsNoOtherMCPServers() {
        #expect(claudeArguments(leg: .execute).contains("--strict-mcp-config"))
    }

    /// A planning leg is supposed to be invisible; speaking and moving the
    /// cursor are the opposite of that.
    @Test func planningLegsGetNoTools() {
        for leg in [AgentRunLeg.plan(prompt: "x"), .replan(feedback: "x"), .followUp(instruction: "x")] {
            #expect(claudeArguments(leg: leg).contains("--mcp-config") == false)
        }
    }

    @Test func aMissingRuntimeSimplyMeansNoTools() {
        let arguments = HeadlessCLIAdapterFactory.adapter(
            for: .claudeCode,
            mcpConfigurationJSON: nil
        ).launchSpec(
            workspaceURL: workspaceURL,
            leg: .execute,
            origin: .sandbox,
            title: "t",
            sessionIdentifier: "s"
        ).arguments
        #expect(arguments.contains("--mcp-config") == false)
        #expect(arguments.contains("--resume"))
    }

    @Test func bridgeSecretStaysOutOfClaudeArguments() {
        let secret = "do-not-put-me-in-argv"
        let spec = HeadlessCLIAdapterFactory.adapter(
            for: .claudeCode,
            mcpConfigurationJSON: mcpConfiguration,
            mcpChildEnvironment: ["HEYMATE_BRIDGE_TOKEN": secret]
        ).launchSpec(
            workspaceURL: workspaceURL,
            leg: .execute,
            origin: .sandbox,
            title: "t",
            sessionIdentifier: "s"
        )
        #expect(spec.arguments.contains(where: { $0.contains(secret) }) == false)
        #expect(spec.environmentOverrides["HEYMATE_BRIDGE_TOKEN"] == secret)
    }

    @Test func openCodeGetsInlineToolsOnlyOnWorkingLeg() {
        let configuration = #"{"mcp":{"heymate":{"type":"local"}}}"#
        func spec(_ leg: AgentRunLeg) -> HeadlessCLILaunchSpec {
            HeadlessCLIAdapterFactory.adapter(
                for: .openCode,
                openCodeMCPConfigurationJSON: configuration,
                mcpChildEnvironment: ["HEYMATE_BRIDGE_URL": "http://127.0.0.1:18732"]
            ).launchSpec(
                workspaceURL: workspaceURL,
                leg: leg,
                origin: .sandbox,
                title: "t",
                sessionIdentifier: "ses_test"
            )
        }
        #expect(spec(.plan(prompt: "x")).environmentOverrides.isEmpty)
        #expect(spec(.execute).environmentOverrides["OPENCODE_CONFIG_CONTENT"] == configuration)
        #expect(spec(.execute).environmentOverrides["HEYMATE_BRIDGE_URL"] != nil)
    }
}

struct AgentRunStatusTests {

    @Test func onlyApprovalStatesNeedTheUser() {
        #expect(AgentRunStatus.awaitingPlanApproval.needsUser)
        #expect(AgentRunStatus.waitingForApproval.needsUser)
        #expect(AgentRunStatus.planning.needsUser == false)
        #expect(AgentRunStatus.running.needsUser == false)
        #expect(AgentRunStatus.succeeded.needsUser == false)
    }

    /// A job waiting on a decision is not finished, or it would drop out of
    /// the live section before anyone answered it.
    @Test func planStatesAreNotTerminal() {
        #expect(AgentRunStatus.planning.isTerminal == false)
        #expect(AgentRunStatus.awaitingPlanApproval.isTerminal == false)
    }

    @Test func onlyExecuteIsWriteEnabled() {
        #expect(AgentRunLeg.plan(prompt: "x").isReadOnly)
        #expect(AgentRunLeg.replan(feedback: "x").isReadOnly)
        #expect(AgentRunLeg.execute.isReadOnly == false)
    }
}

struct AgentPlanTextTests {

    /// `claude -p` disables ExitPlanMode and then narrates that fact. True,
    /// and not the user's problem.
    @Test func toolPlumbingIsStrippedFromThePlan() {
        let plan = HeadlessAgentLauncher.presentablePlanText(from: [
            "Plan: two files — index.html and styles.css.",
            "ExitPlanMode disabled this session. Plan written to ~/.claude/plans/x.md"
        ])
        #expect(plan.contains("index.html"))
        #expect(plan.localizedCaseInsensitiveContains("ExitPlanMode") == false)
    }

    @Test func fragmentsAreJoinedAndDeduplicated() {
        let plan = HeadlessAgentLauncher.presentablePlanText(from: [
            "Step one.",
            "Step one.",
            "Step two."
        ])
        #expect(plan == "Step one.\n\nStep two.")
    }

    /// An empty plan must stay empty, so the launcher can fail the job rather
    /// than ask the user to approve nothing.
    @Test func aPlanOfNothingButPlumbingIsEmpty() {
        let plan = HeadlessAgentLauncher.presentablePlanText(from: [
            "ExitPlanMode disabled this session.",
            "   "
        ])
        #expect(plan.isEmpty)
    }
}

struct AgentRunPersistenceTests {

    /// `FileAgentRunStore` falls back to an empty history when decoding
    /// throws, so a run stored before the approval gate shipped has to keep
    /// decoding — otherwise shipping this erases the user's whole history.
    @Test func runsStoredBeforeTheApprovalGateStillDecode() throws {
        let legacyJSON = """
        [{
          "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
          "title": "build a landing page",
          "prompt": "build a landing page",
          "workspacePath": "/tmp/heymate/landing",
          "executor": "openCode",
          "origin": "sandbox",
          "status": "succeeded",
          "latestAction": "Done",
          "summary": "Done",
          "error": "",
          "pendingApprovalID": "",
          "createdAt": 771000000
        }]
        """

        let runs = try JSONDecoder().decode([AgentRun].self, from: Data(legacyJSON.utf8))
        #expect(runs.count == 1)
        #expect(runs[0].title == "build a landing page")
        #expect(runs[0].sessionIdentifier.isEmpty)
        #expect(runs[0].planText.isEmpty)
    }

    @Test func newFieldsSurviveARoundTrip() throws {
        var run = AgentRun.queued(
            id: UUID(),
            title: "build a landing page",
            prompt: "build a landing page",
            workspaceURL: URL(fileURLWithPath: "/tmp/heymate/landing", isDirectory: true),
            executor: .claudeCode,
            origin: .sandbox,
            sessionIdentifier: "4662b1f8-8da1-4865-a3a2-ecd91d20cbb0"
        )
        run.status = .awaitingPlanApproval
        run.planText = "Two files: index.html and styles.css."

        let encoded = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(AgentRun.self, from: encoded)
        #expect(decoded == run)
        #expect(decoded.sessionIdentifier == "4662b1f8-8da1-4865-a3a2-ecd91d20cbb0")
        #expect(decoded.status == .awaitingPlanApproval)
    }
}

struct AgentSessionIdentityTests {

    /// Leg two has nothing to resume without this.
    @Test func claudeInitLineCarriesTheSessionIdentifier() {
        let line = #"{"type":"system","subtype":"init","session_id":"4662b1f8-8da1-4865-a3a2-ecd91d20cbb0","cwd":"/tmp"}"#
        let events = ClaudeStreamJSONParser.events(fromStdoutLine: line)
        #expect(events == [.sessionIdentified("4662b1f8-8da1-4865-a3a2-ecd91d20cbb0")])
    }

    @Test func claudeSystemLinesWithoutASessionAreIgnored() {
        let line = #"{"type":"system","subtype":"hook_started"}"#
        #expect(ClaudeStreamJSONParser.events(fromStdoutLine: line).isEmpty)
    }

    /// OpenCode assigns its own id and stamps it on every event.
    @Test func openCodeEventsCarryTheSessionIdentifier() {
        let line = #"{"type":"step_start","sessionID":"ses_abc123","part":{"type":"step-start"}}"#
        let events = OpenCodeRunParser.events(fromStdoutLine: line)
        #expect(events.contains(.sessionIdentified("ses_abc123")))
    }
}
