# HeyMate harness plan: the open-source HeyClicky alternative

Date: 12 October 2026. Branch: `feat/heyclicky-parity`.

Positioning: **HeyMate is the open-source HeyClicky. Bring your own AI. Your existing Claude, ChatGPT, or OpenCode subscription does the work; nothing is metered by us, nothing leaves your Mac that you did not choose to send.** Every item below either closes a felt gap against HeyClicky 1.0.53 or strengthens that position.

## What we learned (evidence in `HeyMate_HeyClicky_Research_Pack/rea/`, gitignored)

Sources: HeyClicky's public changelog; the OpenClicky source (same codebase lineage, confirmed by shared class names `CompanionManager`, `CodexAgentSession`, `CodexHomeManager`, `ElementLocationDetector`); the HeyClicky bundle (`ClickyModelInstructions.md`, skills, Codex model catalog, binary strings); and its local Codex home on this Mac (`config.toml`, five Clicky workspaces, session rollouts with every injected turn).

1. **Agent memory is a folder.** Each Clicky owns a workspace with `AGENTS.md`: Identity, Standing preferences, dated Notes. The CLI loads it natively at thread start; the brief tells the agent to keep Notes current and that the newest dated fact wins. Deliverables go to `output/`, scratch to `tmp/`.
2. **The standing agent brief is 4.3 KB** (`developer_instructions` in `config.toml`). Everything else arrives as short, state-driven notes in the user message: lease metadata, role note, today's date, "no screenshot attached", workspace rules, the complete routine list, then `User transcript:`.
3. **A fixed output contract** parsed from the final message: `<SUMMARY>` (under 200 chars, spoken), `<NEXT_ACTIONS>` (1 to 4 tappable imperatives under 40 chars), `<ARTIFACTS>` (up to 8, first auto-opened), `<DONE_TITLE>`, `<ROUTINE>` (JSON: action create/update/pause/resume/delete, `every_minutes`, `title`, `task`), `<COMPUTER_USE_REQUEST>`.
4. **Ask-once policy.** Do the part that does not depend on the answer, then one bundled set of questions; SUMMARY becomes the question; never invent the user's facts; confirm only before delete, overwrite, send, spend. Email is draft-first.
5. **Consent is a message, not a modal.** Computer-use observation tools always work; input tools return a refusal that tells the agent to finish the rest and end with a request block; approval arrives as a prefix on the next turn and lasts the conversation. A local AX-element picker (`jev-use` `drive_until`) runs the click loop at ~0.5 s a step without an LLM turn per click, with a code-enforced deny list.
6. **Voice owns the session tools.** The realtime model calls `sessions_spawn` (with `new_clicky`), `sessions_send`, `sessions_answer_request`, `send_to_higher_model`; fast/deep is a tool call, not a separate classifier. Recent companion turns are passed to a new agent as `<RECENT_COMPANION_CONTEXT>` with "use only if the transcript refers to it".
7. **Routines are declared by the agent and owned by the app.** The agent emits `<ROUTINE>`; the scheduler injects the authoritative list every turn.
8. **Quiet rules and recovery notes**: calls and screen share silence everything; retry notes say "check what is done, continue"; stale-screenshot notes say "the new screenshot is the only truth"; stop within 10 s is refunded.



## Where HeyMate stands

Talk: `VoiceRouter` regex, Haiku `VoiceIntentClassifier` on ambiguity, `BehaviorContract.combinedSystemPrompt`, 10-pair history, 8 memory items, `WarmTalkPool` for CLI brains, four local tools plus connector MCP tools (tool loop only on the custom-API client). Agents: Claude Code, Codex, OpenCode behind plan, approve, execute; detached runner; `heymate-mcp.mjs` tools; routines with offline wait and three-failure pause. Gaps: memory is session digests only (`preference`/`projectFact` never written); the CLI child gets only the `[WORK]` string; `.hybrid` and `.confirmDestructive` collapse to Talk; approvals do not carry; no clock; no quiet policy; no output contract; no next actions; skills never reach agents.

## Waves

Each wave is a set of tasks that touch disjoint files so they can run in parallel. Every task ships with unit tests in `heymate/HeyMateTests/` and passes `./heymate/scripts/typecheck.sh --tests`. Repo rules: imports at the top, exhaustive `switch` with a `never`-style default for enums, no prompt text copied from HeyClicky.

### Wave 1: foundations (parallel, no edits to `CompanionManager.swift`)

- **1A Mate workspace memory.** `MateWorkspaceMemory` writes `AGENTS.md` (Identity, Standing preferences, Notes) and a `CLAUDE.md` that includes it into each mate's folder on create/rename/job change; `output/` and `tmp/` created. Talk reads Notes into `MateSoul.promptBlock` in place of the manual `memoryNote`; the settings editor edits the same file. Files: `MateWorkspace.swift`, `MateStore.swift`, `CompanionManager+Mates.swift` (only the mate create/update sites), new `MateWorkspaceMemory.swift`, `MateSettingsSheet.swift`.
- **1B Agent output contract.** `AgentReplyBlocks` parses `SUMMARY`, `NEXT_ACTIONS`, `ARTIFACTS`, `DONE_TITLE`, `ROUTINE`, `COMPUTER_USE_REQUEST` out of the final message; `AgentFinalResult` exposes them; the execute instruction in `HeadlessCLIAdapter` asks for them; `MateRunReport.finished` renders summary, chips, and artifacts. Files: new `AgentReplyBlocks.swift`, `AgentFinalResult.swift`, `HeadlessCLIAdapter.swift`, `MateAgentBrief.swift` (`MateRunReport` only), `AgentRuntimeTypes.swift` if a field is needed.
- **1C Lean standing brief and ask-once.** Rewrite `AgentPlanBrief` and the agent half of `MateAgentBrief` in HeyMate's own words to: act on the request, confirm only for delete/overwrite/send/spend, draft-first email, ask-once with the independent part done first, deliverables in `output/`, never invent user facts, final message leads with the result. Target under 5 KB total. Files: `AgentPlanBrief.swift`, `MateAgentBrief.swift` (brief half).
- **1D Consent that carries.** `ComputerUseCoordinator` gains a per-conversation grant (allow once, allow for this chat, always) and a refusal message that instructs the model to finish and emit a request block; `BehaviorContract.computerControlSection` describes it; `HeyMateMCPServer` returns the same refusal text to agent children. Files: `ComputerUseCoordinator.swift`, `ComputerUseApprovalCard.swift`, `BehaviorContract.swift` (that section only), `HeyMateMCPServer.swift`.
- **1E Memory extractor.** `MemoryExtractor` turns a finished Talk exchange into zero or more `preference` / `projectFact` items using the configured brain's cheapest text path (same proxy as `VoiceIntentClassifier` when available, on-device Foundation Models otherwise), deduplicated against existing items; `FileMemoryRepository.append` is the writer. No call-site wiring yet. Files: new `MemoryExtractor.swift`, `MemoryRepository.swift` (dedupe helper only).
- **1F Positioning.** README, `website/` hero and feature copy, `marketing/LAUNCH.md`: "the open-source HeyClicky; bring your own AI; your existing subscription does the work". No superiority claims without a recording. Files: `README.md`, `website/index.html`, `website/css`, `marketing/LAUNCH.md`.



### Wave 2: wiring in `CompanionManager` (sequential within the file)

- **2A Situational notes.** Replace prompt growth with per-turn notes appended to the user message: today's date and timezone every turn; "no screenshot attached" when none; "the user acted while you were thinking" when a guided click lands mid-turn; retry note on failed-run retry; "this brief was written by HeyMate" on routine and standing-order turns.
- **2B Running-jobs block and recent context.** Every Talk turn carries a compact list of running and waiting mate runs; a spawned run receives the last three companion exchanges tagged as context only.
- **2C Wire the memory extractor** after each Talk turn (behind the existing remember-conversations switch) and show new items in Settings.
- **2D Honour the model's choice.** Add Talk tools `start_mate_work`, `send_to_mate`, `answer_request`, `ask_deeper`; route by tool call before regex; `.hybrid` runs both; `.confirmDestructive` shows a confirm card. `ask_deeper` is the fast/deep split for CLI brains (text-only fast model when no images).
- **2E Next-action chips and artifacts** in `MateHomeView` and `NotchChatView`; tapping sends the phrase as a follow-up.
- **2F Routines by declaration.** `<ROUTINE>` blocks register with `MateRoutineStore`; every mate turn injects the live routine list as authoritative; routine runs after the first carry "report only what is new".



### Wave 3: quiet, recovery, speed

- Quiet policy: detect calls and screen sharing (CoreAudio input in use by another process, `SCShareableContent` presenters), Focus modes; silence chimes, cursor captions, routine announcements, auto-offers.
- Stop-within-10-seconds refund and "didn't count" message; retry button on failed runs resumes the same session with the retry note.
- Terminal takeover keeps `sessionIdentifier` so follow-ups still work.
- Fast click loop: an AX-tree element picker for single-window goals inside `ComputerUseExecutor`, deny list enforced in code.
- Skills reach agents: install matched `SKILL.md` into the mate workspace before an execute leg.



### Wave 4: onboarding and first week

- Four-question interview that writes `PROFILE.md`; three proposed mates from it (already prototyped in `MateCast`); first three asks that end differently (a file, a chat answer, work inside an app).
- Daily suggestions from connected apps and recent work, with per-card approve/skip/adjust and fatigue back-off.



## Verification

- `./heymate/scripts/typecheck.sh --tests` after every task.
- Unit tests per task; `xcodebuild test` for touched test files with a scratch DerivedData path.
- Manual: one recorded walkthrough per wave (Final Cut export, Gmail draft via mate, a routine run) kept under `docs/walkthroughs/`.

