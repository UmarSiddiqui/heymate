# Historical ACP wrapper prototype: verified contract

Inspected 2026-10-17. **Historical transport documentation:** the implementation and validation below describe the earlier ACP prototype, not the currently selected Hermes route or current candidate validation.

The selected Hermes integration now uses one app-owned persistent `hermes serve` backend with native typed/voice routing, streamed tool/subagent progress, foreground approval/clarification UI, durable turn recovery and an active-turn quit guard. A bundled runtime is preferred for a blank executable setting; users without a saved engine preference default to Hermes when that bundle is present. Explicit existing preferences remain respected. Settings can create a private profile, configure supported provider/model access and browse/review skill changes. Native history/memory and ACP session IDs are not automatically migrated. Hermes remains unsandboxed, profile memory/skills are shared, and surfaced approval requests do not cover every action.

See [the current persistent integration](hermes-serve-slice.md) for setup, ownership, recovery and quit boundaries, and [runtime packaging](hermes-runtime.md) for the bundle contract. Current tests/builds are tracked separately; historical results below must not be used as their outcomes.

## Historical implemented ACP wrapper

HeyMate retains its native chat, voice input/output, screen-capture policy, mates and appearance. Selecting **Settings > Agents & Control > Mate engine > Hermes (experimental)** routes typed and voice conversation requests to Hermes over ACP stdio. Hermes owns its model/tool loop and delegation. The engine choice applies app-wide; native provider/model preferences remain saved separately.

- Provide a trusted direct Hermes executable and an existing prepared isolated profile. No automatic install, authentication import, or silent fallback occurs. Shell launchers explicitly assigning `HERMES_HOME` are rejected to catch the existing evaluation wrapper.
- Per-chat session IDs are stored privately under HeyMate's `hermes-wrapper` directory and scoped to the selected profile. Each turn starts an owned ACP process, creates or loads that session, and closes the process afterward. Native chat history is retained in HeyMate but not imported into Hermes.
- Hermes text streams into the existing chat. Native work/handoff markers in its replies cannot launch duplicate native jobs. New native sandbox/attached jobs are disabled while Hermes is selected.
- Images use ACP image blocks. Unknown or incompatible protocols/modes, missing sessions, corrupt maps, timeouts and incomplete stop reasons fail visibly.
- Only advertised once/deny permission options are offered. Cancellation clears pending permissions and stops the owned process. If there is no available foreground host window or another sheet already occupies it, the request is denied rather than stacking sheets or granting permission.
- Ambient native subscription API keys and app-only secrets are stripped from the child environment. Hermes loads its explicitly selected profile normally. Inherited configured MCP startup is disabled, and no HeyMate connector inventory is forwarded.

This is an interactive prototype, not a production migration. Hermes profile memory and skills are shared across its mate sessions; native private memory is not migrated. Hermes tools are not OS-sandboxed here, and ordinary shell actions need not request approval. No detached HeyMate runner/journal, child-agent dashboard, native connector bridge, or automatic transfer of existing jobs is provided. App termination during a tool action is not established as safe resumable execution merely because the conversation session is persisted. Those boundaries need resolving before making Hermes the default engine.

## Historical source and availability

Official Hermes checkout: `/Users/umarsiddiqui/HeyMateEvaluations/hermes-comparison-2026-10-16/engine`, origin `NousResearch/hermes-agent`, revision `d923a5eb487a17c0a68801bba9ef0f56c81040a8`.

The evaluation launcher is `/Users/umarsiddiqui/HeyMateEvaluations/hermes-comparison-2026-10-16/hermes`. It unconditionally sets evaluation-specific `HERMES_HOME` and `HERMES_RUNTIME_DIR` and invokes the installed engine launcher. It overrides host-supplied isolation settings and must not be used as the prototype's configurable isolated launcher. The direct official engine launcher at `engine/.hermes/bin/hermes` preserves a nonempty inherited `HERMES_HOME`.

Dependency `agent-client-protocol` 0.9.0 is installed in the evaluation's selected environment. Its `acp/meta.py` declares wire protocol version 1 and schema reference v0.11.2.

Read-only dependency/import check passed:

```sh
PYTHONDONTWRITEBYTECODE=1 HERMES_DISABLE_LAZY_INSTALLS=1 \
  /Users/umarsiddiqui/HeyMateEvaluations/hermes-comparison-2026-10-16/hermes acp --check
# Hermes ACP check OK
```

No installation, provider authentication or config changes were requested. `--check` exits before normal ACP environment loading and server startup; it proves imports, not credentials or a working model call. `HERMES_DISABLE_LAZY_INSTALLS=1` prevents source-update dependency completion during launch.

Two further no-model-call probes establish readiness limits:

1. The direct official engine launcher, with a new scratch `HERMES_HOME`, the existing evaluation tools directory as `HERMES_RUNTIME_DIR`, and lazy installs disabled, exits before initialization: ``hermes: no dependency environment is committed for this install; run `hermes pm repair` ``. The tools directory alone does not provide a new profile's committed Python dependency environment.
2. The already-installed evaluation virtualenv's `bin/python -m acp_adapter`, with another new scratch home and a sanitized environment containing no provider keys, successfully responds to JSON-RPC `initialize` with protocol version 1. `session/new` then returns JSON-RPC error -32603: `Hermes is not connected to any AI provider yet.` The scratch profile's `state.db` exists; no prompt/model request was sent. Session creation, mode selection, loading and cancellation were not verified on a usable session because creation failed. The private evaluation profile and credentials were not copied.

The second probe uses an already-prepared interpreter to test the server; it does not prove the app's `hermes acp` launcher works with an unprepared profile. The prototype requires an explicitly prepared isolated Hermes profile with its own dependency selection and provider access. Preparing that profile remains separate work.

## Transport

Launch a trusted official Hermes executable that respects the explicit isolated home, with arguments `["acp"]`. Stdout is newline-delimited JSON-RPC 2.0; stderr carries logs. Unlike Codex's transport, ACP includes `"jsonrpc":"2.0"`. Requests have `id`, notifications do not. Responses echo the exact request ID. Keep reading during outstanding requests: updates and permission requests can arrive before the prompt response.

Minimal handshake:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientInfo":{"name":"heymate","version":"prototype"},"clientCapabilities":{}}}
```

The result includes `protocolVersion`, `agentInfo`, `agentCapabilities` and `authMethods`. Hermes advertises session loading and image prompt capability. Empty client capabilities avoid promising client filesystem/terminal services. Hermes has its own tools. Do not run the advertised setup authentication method automatically: it opens interactive provider configuration.

## Session lifecycle

```json
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/absolute/workspace","mcpServers":[]}}
{"jsonrpc":"2.0","id":3,"method":"session/load","params":{"sessionId":"saved-id","cwd":"/absolute/workspace","mcpServers":[]}}
{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"saved-id","prompt":[{"type":"text","text":"User task"}]}}
{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"saved-id"}}
```

`session/new` returns `sessionId`, optional `models`, `modes`, and `_meta`. Persist the returned ID. `session/load` returns session fields without a new public session ID and replays history through `session/update` **before** responding. Reject a null load response: this Hermes revision returns `None` for a missing session. Do not silently create a replacement session.

Avoid the unstable `session/resume` method in the prototype: its missing-session path creates a new session. Hermes persists ACP sessions in its configured home database; the public ACP ID remains stable across internal compression continuations. Optional `_meta.hermes.sessionProvenance` describes internal lineage.

The prompt response contains `stopReason`: `end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, or `cancelled`. A completed RPC or `end_turn` alone is not proof that the user's task succeeded. Cancellation sets a session cancellation event and invokes the agent's interrupt path. There is no standard `turn/steer` method here; don't map Codex steering blindly onto ACP.

## Updates and approvals

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"saved-id","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Reply fragment"}}}}
{"jsonrpc":"2.0","id":17,"method":"session/request_permission","params":{"sessionId":"saved-id","toolCall":{"toolCallId":"perm-check-1","title":"Command","kind":"execute","status":"pending"},"options":[{"optionId":"allow_once","kind":"allow_once","name":"Allow once"},{"optionId":"deny","kind":"reject_once","name":"Deny"}]}}
{"jsonrpc":"2.0","id":17,"result":{"outcome":{"outcome":"selected","optionId":"allow_once"}}}
{"jsonrpc":"2.0","id":18,"result":{"outcome":{"outcome":"cancelled"}}}
```

Other update discriminators include `agent_thought_chunk`, `user_message_chunk`, `tool_call`, `tool_call_update`, `plan`, `available_commands_update`, `current_mode_update`, `config_option_update`, `session_info_update`, and `usage_update`. Tool events use `toolCallId`; retain it for update association. Treat unknown update types as forward-compatible. History replay must not append duplicate live completion receipts.

Permission options are advertised per request. Choose only a supplied `optionId`; bind the request to the active process/session and retain its JSON-RPC ID. Hermes options can include `allow_once`, `allow_session`, `allow_always`, `deny`, and `deny_always`. `allow_session` uses ACP kind `allow_always` but has session-scoped Hermes semantics. Actual `allow_always` can persist a permanent allowlist entry. The prototype should offer once/deny and never silently choose permanent approval. Timeout, unknown options and bridge errors deny by default. Hermes currently derives timeout from its approval configuration, default 300 seconds.

## Modes, models and MCP

```json
{"jsonrpc":"2.0","id":5,"method":"session/set_mode","params":{"sessionId":"saved-id","modeId":"default"}}
{"jsonrpc":"2.0","id":6,"method":"session/set_model","params":{"sessionId":"saved-id","modelId":"provider:model"}}
```

Modes describe **file-edit approval**, not an OS sandbox:

- `default`: ask before edits.
- `accept_edits`: automatically allow workspace/temp edits; sensitive paths still ask.
- `dont_ask`: automatically allow session file edits except sensitive paths.

There is no advertised read-only planning mode. Dangerous-terminal approval is a separate bridge. Do not equate `default` with containment or claim that all shell commands require approval. `cwd` binds relative file/terminal operations but is not a filesystem boundary.

The core terminal approval mode defaults to `manual`, not `smart`. Even in manual mode, commands that do not match a dangerous pattern can run without a permission request. Configured permanent allowlists also bypass prompts. Smart mode can approve a flagged command before it reaches the host approval bridge; off/yolo modes bypass recoverable approvals. `execute_code` can run arbitrary Python and subprocesses outside shell-string pattern checks. A strict gate for every tool action requires additional enforcement; no ACP mode establishes it. This prototype trusts the configured Hermes engine and profile with host access.

Provider credentials/default model come from the configured Hermes home and runtime resolver. Model menus contain `provider:model` IDs and `custom:<name>:<model>` IDs for named custom endpoints. Select an advertised model ID while idle; a model switch can perform network validation. It changes the session rather than the global default. `session/set_config_option` accepts arbitrary values but is not a provider-configuration API; do not use it to invent auth or provider options.

`mcpServers` is a required wire list on new/load, even when empty. Supported entries:

```json
{"name":"bridge","command":"/absolute/mcp-server","args":[],"env":[{"name":"KEY","value":"value"}]}
{"type":"http","name":"bridge","url":"http://127.0.0.1:1234/mcp","headers":[{"name":"Authorization","value":"Bearer token"}]}
{"type":"sse","name":"bridge","url":"http://127.0.0.1:1234/sse","headers":[]}
```

The inspected Hermes adapter accepts HTTP/SSE/stdio server entries. Initialize does not explicitly advertise HTTP/SSE MCP capabilities; capability-aware clients should not assume generic ACP agents support these shapes merely because this adapter does.

Configured Hermes MCP servers may also start globally. `HERMES_ACP_SKIP_CONFIGURED_MCP=1` skips that global startup; it does not disable explicitly supplied per-session servers, all plugin tools or Hermes native tools. Client-provided servers are added per session. Keep secrets out of logged RPC frames.

## Historical prototype boundaries and verification

Use a trusted official launcher that preserves explicit profile settings. Do not copy credentials, modify global provider state, run setup, install dependencies or claim provider billing equivalence. An isolated config/state home does not create OS tool isolation. Preserve HeyMate's own permission UI and task/chat ownership above this transport.

ACP provenance is not profile attestation. `_meta.hermes.sessionProvenance` contains public/internal session IDs, lineage and compression metadata, but no effective home or workspace. `session/list` entries can verify cwd; reading the expected profile's database can verify session persistence afterward, but cannot prevent a misconfigured launcher from first writing elsewhere. Trust and validate the launch executable/configuration before starting it.

Before a live task: verify handshake, new/load persistence, text chunk collection, final stop-reason handling, once/deny responses with fake server fixtures, mismatched-session rejection, cancellation and process failure. Verify any live tool execution separately inside an explicitly authorized scratch workspace. The initial empty-profile probes above do not establish model execution; the separate prepared-profile smoke test below does.

## Historical ACP validation results

- Xcode compiled the native app and tests using scratch DerivedData and ad hoc signing. The installed HeyMate app was not replaced.
- All four focused suites passed: ACP transport/session, wrapper client, engine configuration and manager routing. Swift Testing reports 26 tests including the disabled-by-default live smoke test; the live test was skipped in this deterministic run. Parameterized cases additionally cover incomplete stop reasons, shell-wrapper overrides, task inputs and native marker replies.
- The separate opt-in `livePreparedHermesProfileSmoke()` passed against the already-prepared evaluation profile using the direct official launcher. It made two real model turns in a new conversation: store a random token, close the process, create another client/process, load the saved session and recall the token without retransmitting it or native history. The profile's existing credentials were used in place, with no copying or provider configuration change. This creates a new Hermes conversation; it does not modify the original evaluation conversation or generated webpage.
- The live run explicitly supplied the evaluation runtime directory; a subsequent direct `acp --check` with the prepared profile and without that runtime override also passed.
- Test instructions requested no tool actions, and the host permission callback denied any permission request. This proves real text/session continuity, not live tool execution, GUI approval behavior, image understanding, subagent orchestration or crash-interrupted action recovery.
- `git diff --check` passed. No production installation, deployment, release or default-engine change was made.

The deterministic build/test command selected `HermesACPTests`, `HermesEngineConfigurationTests`, `HermesManagerRoutingTests` and `HermesConversationClientTests`. The live test is gated by `HEYMATE_HERMES_LIVE_EXECUTABLE` and `HEYMATE_HERMES_LIVE_PROFILE`; `HEYMATE_HERMES_LIVE_RUNTIME` is optional. It must never run automatically in CI with user credentials.

## Grounding

- [Hermes ACP server at inspected revision](https://github.com/NousResearch/hermes-agent/blob/d923a5eb487a17c0a68801bba9ef0f56c81040a8/acp_adapter/server.py)
- [Hermes permission bridge](https://github.com/NousResearch/hermes-agent/blob/d923a5eb487a17c0a68801bba9ef0f56c81040a8/acp_adapter/permissions.py)
- [Hermes ACP host documentation](https://github.com/NousResearch/hermes-agent/blob/d923a5eb487a17c0a68801bba9ef0f56c81040a8/website/docs/user-guide/features/acp.md)
- Installed SDK files inspected directly: `acp/schema.py`, `acp/meta.py`, `acp/connection.py` under the evaluation's selected environment.
