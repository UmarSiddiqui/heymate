# Persistent Hermes integration

Source status in the isolated `hermes-wrapper` worktree, 2026-10-17. This describes the current implementation, not an installed or published release. The original first-slice evaluation is historical; its test counts and live probes do not establish validation of the current candidate. The current combined tests and candidate build are tracked separately.

## Selected engine and runtime

Selecting Hermes now routes native typed and voice conversations through `HermesServeConversationClient`, not ACP. HeyMate retains its mates, chat UI, voice, appearance, permission UI and conversation ownership. Hermes owns the model/tool loop and delegation. Native handoff markers in model text cannot create duplicate legacy jobs.

When a bundled runtime manifest is present, a user with no saved engine preference defaults to Hermes. Existing explicit preferences remain respected; selecting Hermes does not silently fall back on failure. A blank executable setting chooses the bundled runtime before PATH. Native and aggregate manifests select the host architecture, bind its source commit and reject escaped resource paths. Release staging validates every included architecture, source stamp and nested binary. See [runtime packaging](hermes-runtime.md) for the pinned source, licenses, staging and optional-tool limits.

`HermesServeBackend` owns one persistent process:

```text
hermes serve --isolated --host 127.0.0.1 --port 0 --no-open
```

It supplies an explicit isolated `HERMES_HOME`, bundled or explicit runtime tools, a fresh cryptographic 256-bit `HERMES_DASHBOARD_SESSION_TOKEN`, `HERMES_DESKTOP=1`, and `HERMES_DISABLE_LAZY_INSTALLS=1`. It reuses only its owned process with the same configuration; profile/configuration changes require confirmed shutdown. It never attaches to a discovered server.

Readiness follows `HERMES_BACKEND_READY port=N` and authenticated HTTP checks:

- `/api/host/identity`: protocol version 1, owned child PID and headless serve role.
- `/api/health`: version/commit; bundled launches require their manifest commit.
- `/api/status`: canonical home matches the configured profile and version agrees with health.

Loopback redirects and proxies are disabled. The private token authenticates HTTP and WebSocket requests; native errors are mapped so authenticated query URLs are not displayed as diagnostics.

## Setup, skills and native progress

Settings can explicitly create a new private profile with manual approvals and skill-write review enabled. It never clones an existing profile or imports credentials. OpenAI/Anthropic API-key setup uses Hermes' credential API and canonical model assignment API; selected-provider readiness is checked separately from fallback routing. Model assignments requiring Hermes confirmation remain pending until the user confirms. This readiness check establishes configuration/credential availability, not a successful billed model request.

The native skills pane lists/enables/reads skills and displays staged skill diffs for explicit approval or rejection through Hermes' supported review commands. Hermes profile memory and skills are shared across mates using that profile; each chat retains its own conversation/workspace. Native memory and earlier native/ACP conversations are not migrated wholesale. Each turn includes bounded historical user context from the same native chat, prioritizing explicit product URLs and positioning; assistant completion claims are excluded. Selected HeyMate connector tools are forwarded through a per-turn scoped MCP bridge. Host filesystem/terminal services and native orchestration tools are not forwarded.

Native chat streams assistant text and displays tool/status/subagent progress from Hermes events. A `prompt.submit` streaming response is acceptance, not completion. The session verifies workspace and desktop contract 8 and accepts terminal output only through its completion handling.

Surfaced `approval` and `clarify` requests use native foreground UI, bound to the current backend/session/request. Unsupported host services, including secret collection, are rejected. A missing/busy host window or expired request does not imply permission. Hermes tools are not OS-sandboxed: ordinary actions and configured allowlists can bypass surfaced approval requests. Manual approval mode does not mean every command asks.

## Recovery and quit boundaries

Durable session mappings and a per-chat turn ledger retain accepted-user identity, event checkpoints and undelivered terminal results. Reconnection uses event sequence/epoch checks and bounded replay. After a backend epoch change, cold-history recovery requires an exact accepted user row, a complete bounded page without another user/compression ambiguity, and a terminal assistant boundary; interrupted-turn markers prevent treating unfinished work as complete. A recovered reply is not semantic proof the user's task succeeded.

Uncertain outcomes remain visible and block blind resubmission. Explicit recovery can reconcile prior work without inventing a new user prompt. An explicit new-context action requires confirmed shutdown before archiving unknown work and rotating the mapping; it does not claim detached external effects stopped. Corrupt or incompatible state fails visibly rather than silently creating replacement work.

Cancellation attempts bounded `session.interrupt` and escalates to the owned process when confirmation fails. Closing a WebSocket is not proof work stopped. Normal quit is blocked while a Hermes turn is active; backend ownership ends with HeyMate. There is no independent service that keeps Hermes work running after app quit, and persisted conversation state alone does not guarantee safe replay of interrupted side effects.

## Gateway contract and historical evaluation

This gateway is distinct from ACP. Methods include `client.capabilities`, `session.create`, `session.resume`, `prompt.submit`, `session.events.since`, and `session.interrupt`. Events use `method: event` and `params: {type, session_id, payload}`. Creation accepts `cwd` and returns `stored_session_id`; resume takes the durable ID and restores its stored workspace, rather than accepting a new `cwd`. Runtime IDs and durable IDs must remain separate.

Native WebSocket responses can precede send completion. Resolved-request cancellation must not close a healthy socket; process callbacks are generation-scoped so an old exit cannot kill a replacement. The transport bounds frames/pending requests, handles interleaved events and fails pending requests on disconnect.

The original first slice denied all approvals and lacked app routing, recovery, setup and native activity UI. Those descriptions are superseded above. Earlier prepared-profile probes verified two turns across WebSocket reconnect with the same owned PID; those probes were development evidence for that slice, not the present candidate's regression results. Optional live tests remain opt-in and may incur provider usage; deterministic fake tests do not call models.

`HERMES_DESKTOP=1` enables Hermes cron and configured MCP discovery. The earlier evaluated profile had zero cron jobs/MCP servers at inspection; arbitrary profiles may contain scheduled work or integrations. No supported general cron-disable flag was found in the pinned source. An isolated home separates state, not OS access.

## Gmail bridge regression, 2026-10-17

Hermes now receives the selected connector inventory and registers a temporary MCP server before each connector-enabled turn. The gateway reloads MCP discovery and probes the scoped tools before prompt submission. Failed delivery is reported as a bridge problem, not evidence that Gmail is disconnected. The bridge uses HeyMate's existing connector sessions, toolkit selection and approval checks. Authentication travels through a private 0600 temporary context file, never model instructions or persisted Hermes MCP configuration. Completion, cancellation and navigation revoke the scope; registration and context files are cleaned up. Cached tools cannot execute after scope expiry.

Common affirmative Gmail draft/send completion claims are checked against successful action receipts containing distinct draft/message identifiers. Tool searches, failures, unidentified results and earlier assistant prose do not qualify. Two claimed drafts require two distinct identifiers. Streaming is held until validation; the checked answer is used for both chat delivery and the recovery ledger. This is a targeted Gmail language guard, not a universal semantic verifier for arbitrary wording or external tools.

Validation: 88 focused Swift tests passed (`/tmp/heymate-gmail-final-tests.log`). `heymate/scripts/hermes-gmail-bridge-smoke.py` exercised the real Node server's scoped discovery/call/expiry paths and the installed Hermes runtime's add/reload/test/remove API using an isolated scratch profile and local Gmail fixtures. These checks made zero model calls and did not read or mutate a real Gmail account.

Installed and verified local candidate 1.0.67 at `/Applications/HeyMate.app`, with previous 1.0.66 preserved at `/private/tmp/HeyMate-before-gmail-1.0.66.app`. Installed source digest: `00ef39f74e3156e464e23ee6cb116e2932c5f59efaea5d7f2bd29f7d2b0f1ae9`.

Live native test in the existing Creator Connect chat searched Gmail for an exact synthetic subject. Hermes invoked `COMPOSIO_SEARCH_TOOLS` and `COMPOSIO_MULTI_EXECUTE_TOOL` with `GMAIL_FETCH_EMAILS`. Persisted execution receipt showed success and zero matching messages; no Gmail create/update/delete/send action was invoked. The reply recalled `https://getheymate.vercel.app/` and the user's open-source HeyClicky positioning with notch capabilities. No real draft mutation or send was tested. The local ad-hoc update caused macOS to report Accessibility/Screen Recording and related permissions unavailable; typed chat and Gmail testing worked without granting them again. Voice/screen workflows may require user reauthorization in System Settings.
