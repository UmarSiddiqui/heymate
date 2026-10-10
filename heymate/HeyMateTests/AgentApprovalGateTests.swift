//
//  AgentApprovalGateTests.swift
//  HeyMateTests
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

    @Test func attachedPlanningDoesNotDirtyTheUserWorkspaceWithATaskFile() {
        #expect(AgentTaskMarkdown.shouldPersist(in: .sandbox))
        #expect(AgentTaskMarkdown.shouldPersist(in: .attached) == false)
    }

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
        HeadlessCLIAdapterFactory.adapter(
            for: .openCode,
            openCodeModelIdentifier: nil,
            openCodeIsolatedConfigurationHomePath: "/tmp/heymate-opencode-test-config"
        ).launchSpec(
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
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--setting-sources"))
        #expect(arguments.contains(""))
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
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains(headlessAgentExecuteInstruction))
    }

    @Test func claudeReplanLegStaysReadOnlyInTheSameSession() {
        let arguments = claudeSpec(leg: .replan(feedback: "use two columns")).arguments
        #expect(arguments.contains("--resume"))
        #expect(arguments.contains(sessionIdentifier))
        #expect(arguments.contains("plan"))
        #expect(arguments.contains("use two columns"))
        #expect(arguments.contains("--safe-mode"))
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

    /// OpenCode gets explicit late permissions instead of its ambient `plan`
    /// agent, which can be replaced by user/project configuration.
    @Test func openCodePlanLegIsIsolatedAndHasNoSession() {
        let spec = openCodeSpec(leg: .plan(prompt: "build a landing page"))
        let arguments = spec.arguments
        #expect(arguments.contains("--agent") == false)
        #expect(arguments.contains("--session") == false)
        #expect(arguments.contains("--auto") == false)
        #expect(arguments.contains(where: { $0.contains(AgentPlanBrief.planningContract) }))
        #expect(spec.environmentOverrides["XDG_CONFIG_HOME"] == "/tmp/heymate-opencode-test-config")
        #expect(spec.environmentOverrides["HOME"] == "/tmp/heymate-opencode-test-config")
        #expect(spec.environmentOverrides["OPENCODE_TEST_HOME"] == "/tmp/heymate-opencode-test-config")
        #expect(
            spec.environmentOverrides["OPENCODE_TEST_MANAGED_CONFIG_DIR"]
                == "/tmp/heymate-opencode-test-config/managed"
        )
        #expect(spec.environmentOverrides["OPENCODE_DISABLE_PROJECT_CONFIG"] == "true")
        #expect(spec.environmentOverrides["OPENCODE_CONFIG_CONTENT"] == #"{"mcp":{},"plugin":[]}"#)
        let permissions = spec.environmentOverrides["OPENCODE_PERMISSION"] ?? ""
        #expect(permissions.contains(#""edit":"allow""#) == false)
        #expect(permissions.contains(#""bash":"allow""#) == false)
        #expect(permissions.contains(#""*":"deny""#))
    }

    @Test func openCodeKeepsRuntimeDataExplicitWhileIsolatingHomeConfig() {
        let runtime = OpenCodeRuntimeIsolation.persistentRuntimeEnvironment(
            processEnvironment: ["HOME": "/Users/tester"]
        )

        #expect(runtime["XDG_DATA_HOME"] == "/Users/tester/.local/share")
        #expect(runtime["XDG_STATE_HOME"] == "/Users/tester/.local/state")
        #expect(runtime["XDG_CACHE_HOME"] == "/Users/tester/.cache")
        #expect(runtime["HOME"] == nil)
        #expect(runtime["XDG_CONFIG_HOME"] == nil)
    }

    @Test func openCodeExecuteLegResumesTheSessionAndEnablesWrites() {
        let arguments = openCodeSpec(leg: .execute, sessionIdentifier: "ses_abc123").arguments
        #expect(arguments.contains("--session"))
        #expect(arguments.contains("ses_abc123"))
        #expect(arguments.contains("--auto") == false)
        #expect(arguments.contains("--agent") == false)
        #expect(arguments.contains(headlessAgentExecuteInstruction))
        let permissions = openCodeSpec(
            leg: .execute,
            sessionIdentifier: "ses_abc123"
        ).environmentOverrides["OPENCODE_PERMISSION"] ?? ""
        #expect(permissions.contains(#""edit":"allow""#))
        #expect(permissions.contains(#""bash":"deny""#))
        #expect(permissions.contains(#""task":"deny""#))
        #expect(permissions.contains(#""external_directory":"deny""#))
    }

    @Test func openCodeAttachedExecuteDoesNotAutoApprove() {
        let arguments = openCodeSpec(
            leg: .execute,
            origin: .attached,
            sessionIdentifier: "ses_abc123"
        ).arguments
        #expect(arguments.contains("--auto") == false)
    }

    @Test func openCodeProcessesCannotShareSeededConfiguration() throws {
        func spec() -> HeadlessCLILaunchSpec {
            HeadlessCLIAdapterFactory.adapter(for: .openCode).launchSpec(
                workspaceURL: workspaceURL,
                leg: .plan(prompt: "inspect only"),
                origin: .sandbox,
                title: "inspect",
                sessionIdentifier: ""
            )
        }

        let first = spec()
        let second = spec()
        defer {
            for directory in first.temporaryDirectoriesToRemove + second.temporaryDirectoriesToRemove {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let firstPath = first.environmentOverrides["XDG_CONFIG_HOME"]
        let secondPath = second.environmentOverrides["XDG_CONFIG_HOME"]
        #expect(firstPath != nil)
        #expect(firstPath != secondPath)
        #expect(first.temporaryDirectoriesToRemove.count == 1)
        #expect(second.temporaryDirectoriesToRemove.count == 1)

        let attributes = try FileManager.default.attributesOfItem(atPath: firstPath!)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
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

    @Test func openCodeFollowUpResumesTheSessionWithIsolatedReadOnlyPermissions() {
        let spec = HeadlessCLIAdapterFactory.adapter(
            for: .openCode,
            openCodeIsolatedConfigurationHomePath: "/tmp/heymate-opencode-test-config"
        ).launchSpec(
            workspaceURL: workspaceURL,
            leg: .followUp(instruction: "also add a dark mode"),
            origin: .sandbox,
            title: "build a landing page",
            sessionIdentifier: "ses_abc123"
        )
        let arguments = spec.arguments

        #expect(arguments.contains("--session"))
        #expect(arguments.contains("ses_abc123"))
        #expect(arguments.contains("--agent") == false)
        #expect(arguments.contains(where: { $0.contains(AgentPlanBrief.followUpContract) }))
        #expect(arguments.contains("--auto") == false)
        #expect(spec.environmentOverrides["OPENCODE_PERMISSION"]?.contains(#""*":"deny""#) == true)
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

    /// Verified against a live child: without the allow-list, the call is
    /// refused with "you haven't granted it yet" and never reaches the bridge.
    @Test func toolNamesAreNamespacedTheWayClaudeCodeExpects() {
        let names = HeyMateMCPServer.claudeCodeToolNames()
        #expect(names.contains("mcp__heymate__heymate_point"))
        // The bare server name rides along because the connector tools this
        // server proxies are discovered at `tools/list` time and cannot be
        // enumerated when the allow-list is built.
        #expect(names.first == "mcp__heymate")
        #expect(names.count == HeyMateMCPServer.toolNames.count + 1)
        #expect(names.allSatisfy { $0.hasPrefix("mcp__heymate") })
    }

    /// A Talk turn's connector tools are discovered from the user's live
    /// sessions when the child asks for `tools/list`, so naming an allow-list
    /// up front would filter out exactly the tools the turn exists to reach.
    @Test func omittingTheEnabledToolsListLeavesConnectorToolsReachable() {
        let withList = HeyMateMCPServer.codexConfigurationArguments(
            runtimeURL: URL(fileURLWithPath: "/usr/bin/node"),
            scriptURL: URL(fileURLWithPath: "/tmp/heymate-mcp.mjs"),
            bridgeEnvironment: ["HEYMATE_BRIDGE_URL": "http://127.0.0.1:18732"]
        )
        let withoutList = HeyMateMCPServer.codexConfigurationArguments(
            runtimeURL: URL(fileURLWithPath: "/usr/bin/node"),
            scriptURL: URL(fileURLWithPath: "/tmp/heymate-mcp.mjs"),
            bridgeEnvironment: ["HEYMATE_BRIDGE_URL": "http://127.0.0.1:18732"],
            enabledTools: nil
        )
        #expect(withList.contains { $0.contains("enabled_tools") })
        #expect(withoutList.contains { $0.contains("enabled_tools") } == false)
        // "auto" still asks under `codex exec`, whose approval policy is
        // `never` — the call is refused before it reaches the bridge.
        #expect(withoutList.contains(#"mcp_servers.heymate.default_tools_approval_mode="approve""#))
    }

    /// The seeded server borrows HeyMate's live connector sessions instead of
    /// opening its own, which is what removes the per-turn `npx` cold start
    /// and puts the call behind the user's approval policy.
    @Test func theSeededServerProxiesConnectorToolsThroughTheBridge() {
        let source = HeyMateMCPServer.serverSource
        #expect(source.contains("/connector/tools"))
        #expect(source.contains("/connector/call"))
        // Unknown names are connector tools, so a missing static tool must
        // forward rather than error out.
        #expect(source.contains("fetchConnectorTools"))
        #expect(source.contains("respondError(id, -32602, \"Unknown tool") == false)
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

    /// Approval reaches this argument builder before the Codex child starts.
    /// Top-level strings must be encoded without the NSJSONSerialization
    /// exception that used to strand a run at "Approved — starting work".
    @Test func codexConfigurationArgumentsSafelyEncodeTopLevelStrings() {
        let arguments = HeyMateMCPServer.codexConfigurationArguments(
            runtimeURL: URL(fileURLWithPath: "/opt/Hey Mate/bin/node"),
            scriptURL: URL(fileURLWithPath: #"/tmp/heymate-"bridge".mjs"#),
            bridgeEnvironment: [
                "HEYMATE_BRIDGE_URL": "http://127.0.0.1:18732",
                "HEYMATE_BRIDGE_TOKEN": "secret"
            ]
        )

        #expect(arguments.count == 10)
        #expect(arguments[0] == "-c")
        #expect(arguments[1] == #"mcp_servers.heymate.command="/opt/Hey Mate/bin/node""#)
        #expect(arguments[3] == #"mcp_servers.heymate.args=["/tmp/heymate-\"bridge\".mjs"]"#)
        #expect(arguments[5] == #"mcp_servers.heymate.env_vars=["HEYMATE_BRIDGE_TOKEN","HEYMATE_BRIDGE_URL"]"#)
        #expect(arguments.joined(separator: " ").contains("secret") == false)
    }

    private func claudeArguments(leg: AgentRunLeg) -> [String] {
        HeadlessCLIAdapterFactory.adapter(for: .claudeCode).launchSpec(
            workspaceURL: workspaceURL,
            leg: leg,
            origin: .sandbox,
            title: "build a landing page",
            sessionIdentifier: "4662b1f8-8da1-4865-a3a2-ecd91d20cbb0"
        ).arguments
    }

    /// No runnable server means nothing to reach, so the leg keeps safe mode.
    @Test func claudeWorkingLegWithoutTheServerStaysInSafeMode() {
        let arguments = claudeArguments(leg: .execute)
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--mcp-config"))
        #expect(arguments.contains(#"{"mcpServers":{}}"#))
        #expect(arguments.contains("--allowedTools") == false)
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
            let arguments = claudeArguments(leg: leg)
            #expect(arguments.contains("--mcp-config"))
            #expect(arguments.contains(#"{"mcpServers":{}}"#))
            #expect(arguments.contains("--strict-mcp-config"))
            #expect(arguments.contains("--allowedTools") == false)
        }
    }

    @Test func aMissingRuntimeUsesStrictEmptyTools() {
        let arguments = HeadlessCLIAdapterFactory.adapter(
            for: .claudeCode
        ).launchSpec(
            workspaceURL: workspaceURL,
            leg: .execute,
            origin: .sandbox,
            title: "t",
            sessionIdentifier: "s"
        ).arguments
        #expect(arguments.contains("--mcp-config"))
        #expect(arguments.contains(#"{"mcpServers":{}}"#))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--allowedTools") == false)
        #expect(arguments.contains("--resume"))
    }

    @Test func bridgeSecretStaysOutOfClaudeArguments() {
        let secret = "do-not-put-me-in-argv"
        let spec = HeadlessCLIAdapterFactory.adapter(
            for: .claudeCode,
            mcpChildEnvironment: ["HEYMATE_BRIDGE_TOKEN": secret]
        ).launchSpec(
            workspaceURL: workspaceURL,
            leg: .execute,
            origin: .sandbox,
            title: "t",
            sessionIdentifier: "s"
        )
        #expect(spec.arguments.contains(where: { $0.contains(secret) }) == false)
        #expect(spec.environmentOverrides["HEYMATE_BRIDGE_TOKEN"] == nil)
    }

    private func claudeSpecWithServer(leg: AgentRunLeg, origin: AgentRunOrigin = .sandbox) -> HeadlessCLILaunchSpec {
        HeadlessCLIAdapterFactory.adapter(
            for: .claudeCode,
            claudeMCPConfigurationJSON: #"{"mcpServers":{"heymate":{"command":"/usr/bin/node","args":["/tmp/heymate-mcp.mjs"]}}}"#,
            claudeMCPAllowedToolNames: HeyMateMCPServer.claudeCodeToolNames(),
            mcpChildEnvironment: [
                "HEYMATE_BRIDGE_URL": "http://127.0.0.1:18732",
                "HEYMATE_BRIDGE_TOKEN": "do-not-put-me-in-argv"
            ]
        ).launchSpec(
            workspaceURL: workspaceURL,
            leg: leg,
            origin: origin,
            title: "t",
            sessionIdentifier: "4662b1f8-8da1-4865-a3a2-ecd91d20cbb0"
        )
    }

    /// Safe mode also drops explicitly supplied MCP, so a mate's Claude job
    /// that keeps it can never reach a connected app. The working leg trades
    /// it for strict MCP plus no setting sources.
    @Test func claudeWorkingLegCarriesTheServerSoMatesReachConnectedApps() {
        let spec = claudeSpecWithServer(leg: .execute)
        #expect(spec.arguments.contains("--safe-mode") == false)
        #expect(spec.arguments.contains("--strict-mcp-config"))
        #expect(spec.arguments.contains("--setting-sources"))
        #expect(spec.arguments.contains { $0.contains("\"heymate\"") })
        #expect(spec.arguments.contains(#"{"mcpServers":{}}"#) == false)
        guard let allowIndex = spec.arguments.firstIndex(of: "--allowedTools") else {
            Issue.record("working leg must allow-list the HeyMate server")
            return
        }
        let allowList = spec.arguments[allowIndex + 1].split(separator: ",").map(String.init)
        #expect(allowList.contains("mcp__heymate"))
        #expect(spec.environmentOverrides["HEYMATE_BRIDGE_URL"] == "http://127.0.0.1:18732")
        #expect(spec.arguments.contains { $0.contains("do-not-put-me-in-argv") } == false)
    }

    /// Attached folders still ask per tool; the server rides along.
    @Test func claudeAttachedWorkingLegCarriesTheServerAndKeepsManualApproval() {
        let spec = claudeSpecWithServer(leg: .execute, origin: .attached)
        #expect(spec.arguments.contains("manual"))
        #expect(spec.arguments.contains("--allowedTools"))
        #expect(spec.arguments.contains("--safe-mode") == false)
    }

    @Test func claudePlanningLegsIgnoreTheServerEvenWhenOffered() {
        for leg in [AgentRunLeg.plan(prompt: "x"), .replan(feedback: "x"), .followUp(instruction: "x")] {
            let spec = claudeSpecWithServer(leg: leg)
            #expect(spec.arguments.contains("--safe-mode"))
            #expect(spec.arguments.contains(#"{"mcpServers":{}}"#))
            #expect(spec.arguments.contains("--allowedTools") == false)
            #expect(spec.environmentOverrides.isEmpty)
        }
    }

    @Test func openCodeGetsInlineToolsOnlyOnWorkingLeg() {
        let configuration = #"{"mcp":{"heymate":{"type":"local"}}}"#
        func spec(_ leg: AgentRunLeg) -> HeadlessCLILaunchSpec {
            HeadlessCLIAdapterFactory.adapter(
                for: .openCode,
                openCodeMCPConfigurationJSON: configuration,
                mcpChildEnvironment: ["HEYMATE_BRIDGE_URL": "http://127.0.0.1:18732"],
                openCodeIsolatedConfigurationHomePath: "/tmp/heymate-opencode-test-config"
            ).launchSpec(
                workspaceURL: workspaceURL,
                leg: leg,
                origin: .sandbox,
                title: "t",
                sessionIdentifier: "ses_test"
            )
        }
        #expect(spec(.plan(prompt: "x")).environmentOverrides["OPENCODE_CONFIG_CONTENT"] == #"{"mcp":{},"plugin":[]}"#)
        #expect(spec(.plan(prompt: "x")).environmentOverrides["HEYMATE_BRIDGE_URL"] == nil)
        #expect(spec(.execute).environmentOverrides["OPENCODE_CONFIG_CONTENT"] == configuration)
        #expect(spec(.execute).environmentOverrides["HEYMATE_BRIDGE_URL"] != nil)
        #expect(spec(.execute).environmentOverrides["OPENCODE_DISABLE_PROJECT_CONFIG"] == "true")
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
        #expect(runs[0].workspaceChangeSummary == nil)
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
        run.workspaceChangeSummary = AgentWorkspaceChangeSummary(
            addedCount: 1,
            modifiedCount: 2,
            deletedCount: 0,
            displayedChanges: [
                AgentWorkspaceChange(kind: .added, path: "Sources/New.swift")
            ],
            omittedDisplayPathCount: 2
        )

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
