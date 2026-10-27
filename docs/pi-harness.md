# HeyMate's custom Pi harness

2026-10-27. Replaces the Hermes runtime, ACP prototype, setup adapter and Python runtime packaging. Historical Hermes investigation documents remain historical; they do not describe the current engine.

HeyMate owns its harness. `heymate/agent-runtime/src/harness.mjs` implements the desktop protocol, task ownership, per-chat identity, prompt acceptance, verified completion, cancellation, replay, approval requests and scoped connector registration. Pi is a dependency, pinned to `@earendil-works/pi-coding-agent` 1.4.0 with an npm lockfile. Pi supplies the model adapters, lower-level agent/tool loop, JSONL conversation history, retries and compaction. This does not launch the Pi CLI or rename Hermes.

Native SwiftUI chat, mates, speech, screen capture policy and settings use `MateAgentServeConversationClient`. One authenticated, app-owned loopback process serves separate conversations. Its token is generated for each launch, never stored in model instructions, and checked by both HTTP and WebSocket routes. Browser-origin requests are rejected. Native startup checks the owned PID, private home, version and packaged revision. Missing configuration fails explicitly rather than selecting a different engine.

## Sessions and context

- One Pi session stays alive per chat across turns. It is rebuilt only when the turn's instructions or tool set change (for example a connector turn), and Brain changes dispose it. Pi's JSONL history is the conversation memory.
- The native app sends interface instructions, mate identity and connector notes as `system` on `prompt.submit`; the harness appends them to Pi's system prompt. The user message holds only the user's words (plus a screen-availability note when relevant), so instructions are not stored or resent in history.
- `prompt.submit` may carry `seed`: earlier native chat rows (user and assistant, newest 60, 200 KB budget). The harness writes them once, as a single labeled context message, only into a Pi session that has no history yet. Chats from before Pi, and chats reset after recovery, keep their context. Seeded assistant text is labeled as not proving actions happened.
- Pi thinking, compaction and retry events reach the app as `agent.thinking`, `agent.compacting` and `agent.retrying` activity.
- Failed turns keep the generic message in history, add a short redacted `error_detail`, show that reason in the app, and append the full redacted error to `pi-agent/logs/turn-failures.log` (0600, rotated at 1 MB).

## Tools and state

- HeyMate wraps Pi's read/bash/edit/write tools. Every shell command and file mutation requires a native one-time approval. Reads do not prompt. Tools use the user's macOS access; approval is not an OS sandbox.
- `ask_user` presents native clarification UI. Missing UI, denial, disconnection, expiry and cancellation never grant permission.
- Enabled HeyMate connectors are delivered through the existing per-turn MCP bridge. Registration is ephemeral; stale cached tool calls fail after revocation. Native action checks and receipt validation remain in place. Connector discovery is not evidence that an action succeeded.
- Agent files, credentials, model selection and skills live in `Application Support/HeyMate/pi-agent`. Session mappings, per-chat workspaces and native recovery ledgers live under `pi-sessions`. Pi's own global profile, third-party extensions and global MCP configuration are not imported.
- Only explicitly enabled skills from this private profile enter the system prompt. Tool policy still applies to file changes. No automatic skill-learning or pending-diff workflow is claimed.
- A durable user row is written before prompt acceptance. Terminal results are persisted before completion events. Reconnecting can replay a bounded event ring in the same process epoch. A process restart never resends an uncertain prompt or automatically resumes unfinished side effects. Native recovery requires an exact durable completed boundary; otherwise it asks for review and a fresh context.

Brain is the only intelligence settings page. Old `accounts` and `agents` links resolve to `brain`. It offers three subscriptions, each a separate option: ChatGPT (OAuth), Claude (OAuth) and Custom API. Pick the subscription, then the model, then the effort. Effort is Pi's thinking level (off, minimal, low, medium, high, extra high, max); the list shows only levels the chosen model supports, and the runtime clamps any saved level to the model. Custom APIs offer every level and are marked reasoning-capable only when effort is above off. Custom APIs support OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, and Google Generative AI formats. Keys live only in the private credential store, separate from endpoint/model configuration. HTTPS is required except for loopback development endpoints; changing a custom API destination requires entering its key explicitly. Switching provider/model discards idle in-memory sessions while retaining durable chat history. Active work blocks configuration changes. No model request is sent by the readiness check. Existing Hermes profiles and tokens remain untouched; users sign in explicitly to the new profile.

There is one runtime: HeyMate’s custom Pi harness. Startup discards the retired engine preference, including native and Hermes selections. No engine picker or alternate conversation backend is available. Runtime paths are internal; setup creates the private profile automatically. Existing native chat history is retained as same-chat user context; Hermes sessions are not presented as Pi sessions.

## Build and verification

```sh
cd heymate/agent-runtime
npm ci --ignore-scripts --no-audit --no-fund
npm test
```

Prepare a payload using a trusted Node distribution (Node >=22.19; CI pins 24.21.0). The distribution must include its LICENSE next to `bin/`:

```sh
python3 heymate/scripts/pi-runtime-build.py --out build/pi-runtime-local
python3 heymate/scripts/pi-runtime-stage.py --source build/pi-runtime-local --destination /tmp/pi-check --verify-only
python3 heymate/scripts/pi-runtime-smoke.py --payload build/pi-runtime-local
```

Set `HEYMATE_PI_RUNTIME` to that absolute payload path when building. Xcode embeds it under `Contents/Resources/MateAgent` and signs its nested executables with the build's identity. The manifest hashes resource files and binds native architecture and source revision. Release CI builds both Mac architectures and verifies the signed payload and app seal. The builder and smoke test never use real provider credentials or submit model requests.

For a local install, use only `heymate/script/build_and_run.sh --verify`, following `heymate/docs/local-development.md`. Preserve the installed signing certificate and mutually compatible designated requirements. Do not use ad-hoc signing or reset TCC.

The automated harness tests include a real Pi agent/tool loop with an in-process fixture provider, one-time approval, an actual scratch-file artifact, and persisted follow-up context. Native transport tests cover acceptance, replay, approvals, shutdown, recovery and migration. These establish local contracts, not live provider availability, real Gmail delivery, microphone quality or audible timing. Those require explicit live checks after sign-in.
