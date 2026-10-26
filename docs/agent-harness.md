> Current implementation: [HeyMate custom Pi harness](pi-harness.md). Hermes integration below is historical.

# HeyMate harness decision

Research date: 2026-10-17. This document records a development decision and acceptance criteria, not a production release or successful live-provider verification.

Update, 2026-10-17: the initial comparison below omitted an existing Hermes evaluation from the other voice chat. That evaluation passed build/reopen/revision/restart continuity with the matched model. The user chose to explore one app-wide Hermes engine option, separate from provider/model selection. An isolated [Hermes wrapper prototype](/Users/umarsiddiqui/.codex/worktrees/hermes-wrapper/heyMate/docs/hermes-wrapper.md) now implements ACP-backed conversations and passed a real two-turn process-restart/session-recall smoke test. The initial keep-native recommendation below is historical, not a decision to reject Hermes. Native repairs remain separate and unshipped.

## Decision

Keep HeyMate's native orchestration and durable runner. Extend the provider integrations already present rather than replace the application runtime with another agent framework.

HeyMate should own task identity, chat ownership, delegation return addresses, approvals, persistence and user-visible evidence. Provider harnesses should own their model/tool loop and any provider-native subagents. A request accepted by a specialist is not a completed task; completion needs a recorded final result and relevant verification.

The immediate work is useful task coordination: preserve the requesting chat when a specialist launches a job, deliver later updates to that exact chat, and let the conductor inspect persisted job status without launching or approving work.

## Existing implementation

- `heymate/HeyMate/CodexAppServerExecutionSession.swift` already resumes an approved execution thread, starts a turn, scopes approvals to that execution, and supports steering and interruption. `HeadlessAgentLauncher.codexLiveExecutionEnabled` defaults to true. Extend this implementation; do not introduce a competing Codex client.
- `HeadlessCLIAdapter.swift` retains read-only planning and CLI fallback paths. Claude uses streamed JSON and session resume. OpenCode explicitly denies shell commands and its task tool in execution permissions.
- `DetachedAgentRunnerEngine.swift` and the runtime persistence/journal files already manage detached execution. Replacing them creates migration and recovery work unrelated to the immediate coordination problem.
- `AgentEvent` provides session, activity, text, approval and terminal events. It does not provide a normalized child-agent identity or child lifecycle. Native provider delegation and HeyMate's named-mate handoffs are distinct mechanisms.

## Current changes and remaining gaps

The working tree introduces a persisted return address for specialist work while retaining the specialist's own job/chat ownership. Updates must reach both the owner and the recorded requester when appropriate. Missing or deleted chats must not be silently replaced with the currently visible chat.

Follow-ups select the newest owned active job, then the newest resumable session. Retries select the newest owned failure. Status questions are recognized as whole questions, so instructions such as "add a status page" and mixed status/work requests reach the agent instead of being swallowed by the local status shortcut.

The working tree also introduces `get_mate_status` backed by a read-only status formatter. It reports persisted state, pending approvals, recent activity and bounded final answers. Reading status must never start a job, send a follow-up, approve a plan, or turn an agent's claim into verified success.

These changes do not establish cross-provider live steering, a full child-agent dashboard, automatic verification, or unrestricted OpenCode execution. Those require separate implementation and acceptance evidence.

Next improvements should remain incremental:

1. Add an internal conductor review turn when a specialist returns. Reports currently append to the requesting chat but do not resume its model automatically. This needs a bounded, deduplicated review queue tied to the original chat and authorization; reusing the user-message entry point would fabricate a new user instruction.
2. Expose provider capabilities explicitly, including live steering, approval transport and native delegation.
3. Normalize child-agent progress only where the provider supplies reliable identity and lifecycle events.
4. Bound delegation concurrency and preserve parent approval/sandbox restrictions.
5. Include verification evidence with completion receipts; distinguish failed, blocked, interrupted and completed outcomes.

## Alternatives considered

**Codex App Server: extend existing integration.** Official OpenAI documentation recommends App Server for custom clients needing authentication, history, approvals and streamed events. Its bidirectional JSON-RPC supports stdio, resume, steering and interruption. Dynamic tools and descendant-thread filters require experimental opt-in. Keep the existing MCP bridge before relying on experimental dynamic tools. [App Server](https://learn.chatgpt.com/docs/app-server), [Codex SDK](https://learn.chatgpt.com/docs/codex-sdk).

**Codex native subagents: use where available.** Current documentation exposes enabled-by-default agents and a concurrency cap. Subagents inherit parent permissions; a reviewer prompt does not establish a separate read-only sandbox. Confirm installed CLI capabilities before configuring version-specific settings. [Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents).

**Claude Agent SDK: capable, but no immediate migration.** It supports named subagents, parallel work, resumption and permission hooks. It adds a JavaScript or Python integration layer. Its documentation says third-party products cannot offer claude.ai login or rate limits without prior approval; use supported API authentication instead. This makes a subscription-first SDK migration a separate product/access decision. This document does not determine the status of existing CLI use. [SDK overview](https://code.claude.com/docs/en/agent-sdk/overview), [Subagents](https://code.claude.com/docs/en/agent-sdk/subagents), [Permissions](https://code.claude.com/docs/en/agent-sdk/permissions).

**OpenCode server/SDK: future adapter upgrade.** Its API exposes sessions and permission replies; agents support task permissions and named subagents. This alone does not establish an OS-enforced sandbox. Keep HeyMate's existing restrictions until isolation and permission handling are deliberately implemented and verified. [SDK](https://opencode.ai/docs/sdk/), [Agents](https://opencode.ai/docs/agents/).

**LangGraph/Deep Agents: no replacement now.** LangGraph provides durable execution, streaming and human intervention; Deep Agents adds planning, subagents and filesystem tools. Adopting it would add another runtime and overlap HeyMate's existing durable execution responsibilities. Consider only if a concrete workflow exceeds the current runtime. [Official overview](https://docs.langchain.com/oss/python/langgraph/overview).

## Acceptance workflow

Use deterministic test clients first. Live-provider verification is a separate step and must not be inferred from unit tests or a successful build.

1. In a conductor chat, delegate a task to a specialist. Confirm the specialist owns its job and the requester chat is persisted separately.
2. Leave the specialist chat before planning finishes. Confirm the plan notification reaches the recorded requester with an actionable job identity.
3. Read `get_mate_status`. Confirm it names the pending approval and does not approve or launch anything.
4. Approve through the existing job approval UI. Confirm subsequent progress and final outcome return to the exact recorded chats even after switching the visible mate.
5. Repeat with failure and cancellation. Confirm neither is reported as verified completion.
6. Remove the requester chat or archive its mate. Confirm updates do not leak into an unrelated active chat.
7. Relaunch during an active detached job. Confirm ownership survives persistence and later status remains inspectable.
8. Check status with no recorded jobs and with multiple live/terminal jobs. Confirm bounded output, live-job discoverability and privacy sanitization.
9. For live Codex execution, verify approval responses and steering affect only the matching thread/turn. For providers without live steering, confirm the UI reports queued follow-up accurately.

Record the actual tests run, build result and any live-provider evidence in the change report. Do not label this workflow passed merely because it is documented.

## Development validation, 2026-10-17

- Xcode compiled the app and test targets using scratch DerivedData and ad hoc signing, leaving the installed app bundle untouched.
- 21 launcher, status-rendering and harness-wiring tests passed. Parameterized follow-up cases cover status questions and work instructions containing status/progress words.
- Six focused manager tests passed, including two ownership/return-delivery cases for visible and background requester chats. They cover the launch boundary, exact result destination, generated-task history, privacy-off storage, newest-run selection and typed status without launching work.
- A broader `ChatTurnNavigationTests` run was interrupted after repeated `IntentRequestDidNotStart` timeouts in navigation classification tests. The broader suite is not green; these failures were not repaired or established as pre-existing by this change.
- `git diff --check` passed. No live-provider end-to-end workflow, deployment or release was performed.
