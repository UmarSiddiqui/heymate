# HeyMate

HeyMate is an AI buddy that lives at the top of your Mac, sees your screen when you ask, talks back, and can hand real coding work to Claude Code, Codex, or OpenCode.

Its main advantage is simple: Claude and Codex run through the CLI accounts you already use. HeyMate does not need a second API key or a separate token bill for its default Talk and coding-agent paths.

> **Current status:** HeyMate is source-first. This repository does not yet include a signed public installer. The app builds and runs, but first-time setup still assumes some comfort with Xcode and macOS privacy permissions.

## What it does

- Lives over the MacBook notch, with a top-center fallback on Macs without one.
- Uses push-to-talk or typed chat to answer questions, including questions about the visible screen.
- Uses Apple Speech and the macOS system voice by default, so voice input and playback need no third-party service.
- Creates coding-agent work in a new folder under `~/Projects/heymate`, or works in a folder you explicitly choose.
- Makes an agent produce a read-only plan first. Files are writable only after you approve that plan.
- Streams agent activity into the app and lets you cancel, continue, undo snapshotted work, or hand a CLI session to Terminal.
- Keeps optional memory, skills, connectors, timers, clipboard history, and other companion features local to the Mac unless their feature explicitly uses an external service.

## Existing subscriptions first

HeyMate discovers CLI executables through your login-shell `PATH`, including common Homebrew, npm, Bun, and local-bin locations.

| Brain | Local command | Sign-in command | Notes |
| --- | --- | --- | --- |
| Claude | `claude` | `claude auth login --claudeai` | Fresh installs select Claude and Sonnet by default. The `--claudeai` flow uses a Claude subscription rather than Anthropic Console billing. |
| Codex | `codex` | `codex login` | Uses the Codex CLI credential store. Being signed in to the ChatGPT Mac app does not sign in the CLI. Models and reasoning levels come from the live Codex model catalog. |
| OpenCode | `opencode` | `opencode auth login` | Can run free OpenCode models with no provider credential. Headless jobs allow file edits but deny shell and subagent tools because OpenCode has no host-level workspace sandbox. Talk and model browsing also require `opencode serve`. |

When Claude or Codex runs a job, HeyMate removes documented app secrets plus provider API-key and base-URL variables from that child process. This prevents accidental metered billing and avoids automatically exposing Worker or voice credentials through the child environment. HeyMate never merges its local secrets file into a coding-agent child. OpenCode may still inherit provider credentials from the environment used to launch HeyMate because bringing your own provider is part of that executor's design.

## Requirements

- macOS 14.2 or later.
- Xcode 26 recommended for source builds; the current project was last upgraded with Xcode 26 and has been verified with Xcode 26.6.
- Internet access on the first build so Swift Package Manager can fetch Sparkle, PostHog, and PLCrashReporter.
- At least one supported CLI above for CLI-backed Talk and coding-agent jobs. A Custom API is an optional Talk-only alternative.
- A signed-in Claude or Codex CLI, or a working OpenCode installation. OpenCode's free models do not require a provider credential.

Node.js or Bun is optional. Coding jobs use each CLI's native toolset and do not depend on HeyMate's local MCP bridge, so background execution keeps working after HeyMate quits.

## Quick source setup

1. Clone the repository and open the Xcode project:

   ```bash
   git clone https://github.com/UmarSiddiqui/heymate.git heyMate
   cd heyMate/heymate
   open leanring-buddy.xcodeproj
   ```

2. Select the `leanring-buddy` scheme and the **My Mac** destination.

3. Check **Signing & Capabilities** before the first Run. The project uses automatic signing but does not check in a development team, so Xcode may ask you to select your Personal Team or another team. A stable signed app matters because macOS ties Accessibility and Screen Recording grants to the app identity.

4. Press Run. HeyMate has no normal menu-bar item; look at the notch or the top center of the active display.

5. Before pressing **Start**, use the model chip to choose Claude, Codex, or OpenCode. If that CLI is signed out, open the gear button, go to **Brain**, and use **Sign in**. HeyMate opens Terminal with the CLI's own login flow and never receives your password or token.

6. Grant the setup card's three required permissions:

   - Microphone
   - Accessibility
   - Screen Recording

   Screen Recording may require an app restart before macOS reports the grant. With the default Apple Speech listener, macOS also asks for Speech Recognition permission when you first talk.

7. Press **Start**, then hold **Control + Option**, speak, and release. The first-run intro will also point at something visible when the selected brain is ready.

No Cloudflare Worker and no API key are required for this default path.

## Coding-agent workflow

Voice or typed construction requests create a sandbox folder with a `TASK.md` file. A run has two legs:

1. The selected CLI inspects the task and workspace with writes disabled.
2. HeyMate shows the plan and waits.
3. Approval creates an undo snapshot, resumes the same CLI session, and enables workspace writes.

Choosing an existing folder uses the same plan gate and adds per-tool approval where the CLI supports it. Sandbox work is created under:

```text
~/Projects/heymate/<task-slug>-<short-id>
```

Agent run cards and session identifiers are persisted in Application Support. Planning stays attached to HeyMate, but approved execution moves into the separately signed `HeyMateAgentRunner` command-line helper embedded at `HeyMate.app/Contents/Helpers`. The helper has its own code-sign identity and no app, camera, microphone, ScreenCaptureKit, Sparkle, or LaunchServices lifecycle. After startup verification, work survives Cmd-Q; reopening HeyMate reattaches its card from a private durable journal. Cancel, approval, and Terminal takeover commands still reach the helper. When approval or terminal review needs attention, the helper wakes HeyMate hidden; the main app recovers the journal and posts through its existing notification permission. HeyMate blocks Cmd-Q during planning, launch races, or any state it cannot prove safe to detach. Approval-ready plans have no live process and also survive a normal quit. A crash-interrupted attached run is marked interrupted on next launch, while its pre-write Undo snapshot remains recoverable. Planning is limited to five awake minutes and an execution leg to fifteen awake minutes; Mac sleep does not consume that budget.

OpenCode jobs intentionally cannot run shell commands or spawn subagents; its CLI currently lacks an OS-enforced workspace-write sandbox. Use Claude Code or Codex when work must build or test itself.

## Permissions and privacy

HeyMate has broad macOS permissions because screen-aware help needs them, but the code keeps several boundaries explicit:

- Talk skips screenshot capture for text-only requests. Screen-related requests capture the focused window or displays according to your setting.
- Excluded apps are not captured by Talk, Smart Dictation, onboarding screen demos, or screen-text standing orders.
- Screenshot files created for subscription CLI turns live in a temporary directory and are deleted after the turn. Screenshots are not added to saved chat history.
- Conversation memory is stored locally in Application Support and is enabled by default. You can turn it off or clear saved chats and memory in Settings.
- Custom endpoint and connector credentials use Keychain storage.
- Coding agents cannot write before plan approval. Attached folders remain explicit user choices.
- Coding CLIs still run as your macOS user and may read files that account can read. Plan mode limits writes, not reads; local secrets files are not a sandbox boundary against an untrusted model or tool.
- Analytics is off unless a build supplies `POSTHOG_API_KEY` in its app configuration.

Terminal sign-in and session takeover use macOS Automation to control Terminal, so macOS may ask for that permission when you first use either action.

## Optional advanced services

These are not part of the quick setup.

### Cloudflare Worker for cloud voice providers

The worker in [`heymate/worker`](heymate/worker) proxies provider credentials for optional AssemblyAI transcription and ElevenLabs speech. Its legacy chat route can also proxy Anthropic Messages requests.

Local worker development uses:

```bash
cd heymate/worker
npm install
npm run dev
```

Every provider-backed Worker route requires a shared `HEYMATE_CLIENT_TOKEN`; an unset token fails closed. This is a separate abuse-damping credential, not a provider API key. For a deployed Worker, set it with:

```bash
npx wrangler secret put HEYMATE_CLIENT_TOKEN
```

For local Worker development, put that token and the provider keys for the routes you use in the git-ignored `heymate/worker/.dev.vars` file:

```text
HEYMATE_CLIENT_TOKEN=<choose-a-random-value>
ANTHROPIC_API_KEY=<your-anthropic-key>
ASSEMBLYAI_API_KEY=<your-assemblyai-key>
ELEVENLABS_API_KEY=<your-elevenlabs-key>
ELEVENLABS_VOICE_ID=<your-elevenlabs-voice-id>
```

Give the app the same client token through its process environment or an untracked local secrets file at `~/.config/heymate/secrets.env`:

```text
HEYMATE_CLIENT_TOKEN=<the-same-random-value>
```

Restrict both local secret files after creating them:

```bash
chmod 600 heymate/worker/.dev.vars ~/.config/heymate/secrets.env
```

Do not put this token or any provider key in `Info.plist`. The app reads the process environment first, then the local secrets file. Provider keys remain Worker-side.

The checked-in app configuration points `WorkerBaseURL` at `http://localhost:8787`, but the default Apple Speech and macOS voice providers do not call it.

### Custom API

The **Custom API** brain accepts an Anthropic Messages-compatible endpoint, model name, and optional API key. The key is stored in Keychain. This endpoint can answer Talk requests, but it does not run coding-agent jobs.

### OpenCode Talk

OpenCode agent jobs launch `opencode run` directly. Using OpenCode as the conversational brain is different: start its local HTTP server first.

```bash
opencode serve
```

HeyMate defaults to `http://127.0.0.1:4096`.
Plain HTTP is accepted only for loopback addresses. A non-loopback OpenCode server must use HTTPS because Talk can send screenshots and prompts.

### Connectors and analytics

Apple-native connectors request their own macOS permissions. MCP and Composio connectors are optional and require their own local command or API key. PostHog remains disabled unless a build explicitly supplies its key and host.

## Development

The repository contains one Xcode app target, unit tests, UI tests, and a separate TypeScript Worker.

Build the app without touching or re-signing the Xcode-managed app bundle:

```bash
cd heymate
./scripts/typecheck.sh
```

Build the app and test targets without executing tests:

```bash
./scripts/typecheck.sh --tests
```

The script uses a fresh temporary DerivedData directory for every run, disables signing, and removes that directory when finished. Run tests from Xcode with **Product > Test** when execution rather than compilation is required.

Build, launch, and verify a stable project-local app bundle:

```bash
./script/build_and_run.sh --verify
```

The Codex desktop project exposes this command as its **Run** action. Verification resolves the launched PID to this build's executable and requires it to remain alive through a short startup window. Other modes are `--debug`, `--logs`, and `--telemetry`.

The run script uses the first local Apple Development identity it finds, preserving macOS permission grants across rebuilds. Set `HEYMATE_DEVELOPMENT_TEAM` to choose another local team, or `HEYMATE_SIGNING_IDENTITY` to provide an exact local identity hash or name. Without a development identity it falls back to ad-hoc signing, which can require granting Accessibility and Screen Recording again after a rebuild. Every local build and public release gate also verifies the embedded runner exists, has hardened runtime, uses the distinct `com.heymate.app.agent-runner` code-sign identity, and carries no app-only entitlements. Release gates additionally reject `get-task-allow`.

Public release automation separately requires a Developer ID Application certificate. `scripts/release.sh` discovers one from Keychain or accepts `HEYMATE_DEVELOPMENT_TEAM` plus `HEYMATE_RELEASE_SIGNING_IDENTITY`; neither value belongs in source control. Release feed continuity is explicit: choose one permanent public repository and Sparkle public key, then commit both public values in `heymate/ReleaseChannel.plist`. The checked-in blank file intentionally blocks release until that decision is reviewed.

Useful paths:

- App source: [`heymate/leanring-buddy`](heymate/leanring-buddy)
- Unit tests: [`heymate/leanring-buddyTests`](heymate/leanring-buddyTests)
- UI tests: [`heymate/leanring-buddyUITests`](heymate/leanring-buddyUITests)
- Worker: [`heymate/worker`](heymate/worker)

## Known limitations

- No signed public download is included yet; source builds require Xcode and local signing setup.
- Fresh installs default to Claude even if another supported CLI is the one already signed in. Choose the brain before starting onboarding.
- Cmd-Q remains blocked during agent planning and background-runner startup. Once approved execution shows as verified background work, it survives quit and reconnects on next launch.
- OpenCode Talk requires `opencode serve` to remain running.
- Screen Recording permission can lag until the next app launch after granting it.
- The default Apple Speech path adds a Speech Recognition prompt after the three-item setup card.

## License

See [`heymate/LICENSE`](heymate/LICENSE).
