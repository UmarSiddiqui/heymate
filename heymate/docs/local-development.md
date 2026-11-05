# Local development and macOS permissions

For a build you intend to use, run this from `heymate/`:

```bash
./script/build_and_run.sh --verify
```

This is the entry point for both human and coding-agent installs. It builds
before interrupting the current app, stages and verifies the result, asks known
GUI copies to quit normally, backs up the installed bundle, and installs and
launches `/Applications/HeyMate.app`. Detached `HeyMateAgentRunner` work is not
stopped. Unknown running HeyMate copies cause an error instead of silently
creating another instance. If quitting is refused, finish pending work and quit
HeyMate yourself before retrying; the script never force-kills it.

The bundled agent needs a self-contained Node distribution. Packaging rejects
Node executables linked to Homebrew or missing `@rpath` libraries, and starts
the prepared backend in a disposable profile to check identity and health.
If the shell selects Homebrew Node, set `HEYMATE_NODE_BINARY` to the absolute
`bin/node` path from an official Node distribution before running this script.
For an existing payload, run `python3 scripts/pi-runtime-smoke.py --root PATH`
to check backend startup without opening a second app or touching sign-ins.

`--debug` runs LLDB against the installed executable. `--logs` and `--telemetry`
launch that same app and stream logs. `--verify` also checks that exactly one
installed GUI instance survives startup. No mode launches a DerivedData copy.

## Check without rebuilding

```bash
./script/build_and_run.sh --check
```

Preflight verifies the installed signature and finds its **exact certificate
SHA-1** among valid private signing identities in the keychain. It reads the
actual signature's TeamIdentifier; the final parentheses in a development
certificate's name are not necessarily the Team ID. It does not build, install,
quit, launch, change app preferences, or reset privacy permissions.

If HeyMate is not installed yet, exactly one valid Apple Development identity
can be selected automatically. Otherwise choose a certificate explicitly:

```bash
security find-identity -v -p codesigning
HEYMATE_SIGNING_IDENTITY='<certificate SHA-1>' ./script/build_and_run.sh --verify
```

`HEYMATE_DEVELOPMENT_TEAM`, when supplied, must agree with the installed app's
actual team and the built app's TeamIdentifier. An explicit signer cannot
override an installed app's identity. Missing, expired, locked, ambiguous, or
different identities stop the workflow before the running app is interrupted.
Restore/unlock the existing certificate and private key, or arrange a deliberate
signer migration separately. There is no ad-hoc fallback or permission bypass.

## What keeps permissions stable

The script tells Xcode to use the selected certificate. It preserves normal
Xcode signing and the existing deep signature, hardened-runtime, embedded-runner,
and nested-entitlement checks; it never recursively re-signs the app. Before
installation, the candidate must have the same bundle identifier, code-sign
identifier, certificate, and team as the installed app. Each app must also
satisfy the other's designated requirement. These checks catch identity changes
that a matching name, path, or team alone would miss.

The canonical path avoids confusion over which app is running or being added
in System Settings. **Path alone does not preserve privacy authorization.**
Apple documents mutually compatible designated requirements as the basis for
sharing privacy-protected resources between app versions:
[TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

On 2026-10-25, the installed copy changed from the custom **HeyMate Open Source
Signing** certificate to an **Apple Development** certificate. Those signatures
have different designated requirements. This workflow keeps the currently
installed development identity; it does not change back to the release signer.
Switching to release/CI builds later can require approval again. The release
signing scripts and updater configuration are unchanged.

If macOS no longer has an Input Monitoring entry, the person must add
`/Applications/HeyMate.app` in System Settings → Privacy & Security → Input
Monitoring using **+**, then enable it. Approve any other permissions the app
shows as missing, and quit/reopen if macOS requests it. The workflow cannot
restore or grant OS authorization. It never runs `tccutil`, removes TCC entries,
or treats saved preferences as proof that a permission is granted. HeyMate's
existing manual Repair action remains a last-resort, user-initiated reset.

## Backups, failures, and validation

There is only ever one HeyMate: `/Applications/HeyMate.app`. Each install keeps
just the bundle it replaced, in
`~/Library/Application Support/HeyMate Install Backups/<timestamp>-<pid>/HeyMate.app`,
deletes older backups, and unregisters the build-products copy from
LaunchServices so Spotlight and `open` never find a second app. A failed
replacement or post-install signature verification restores the old bundle.
`--verify` deletes the backup once the new app has launched and stayed up; if
launch fails, the backup stays for a deliberate restore.

Every checkout and worktree installs to the same path, so the last install
wins. The script refuses to install a branch that is missing commits from
`origin/main`, because that would silently drop work other sessions already
shipped. Merge main first (`HEYMATE_ALLOW_STALE_INSTALL=1` overrides). Local installs
share one lock in `/Applications/.heymate-local-install.lock` across worktrees.
An interrupted process can leave a lock: inspect its `pid` file and confirm no
build is running before removing the stale lock. Do not build using `sudo`.

For compile checks, use `./scripts/typecheck.sh [--tests]`, which uses scratch
DerivedData and never installs or launches its output. For workflow regression
checks, without touching the real app:

```bash
python3 script/local_install_tests.py
bash script/process_scope_tests.sh
```

The fixture tests cover signer selection, incompatible requirements in either
direction, bundle identity, missing private keys, backup preservation, and
failed replacement rollback. They do not claim to test or grant macOS TCC
authorization. A live `--check` can validate this Mac's installed identity
without rebuilding or relaunching.

## Speech and 3D regression checks

The default local speaker is now Phonon, bundled with its private Ollama/MLX
runtime. `build_and_run.sh` prepares the pinned payload automatically; an
existing prepared directory can be supplied as `HEYMATE_PHONON_RUNTIME`.
No separate Ollama installation is needed. See
[rollout evidence and cold-start limits](phonon-rollout-2026-11-01.md).

After a verified local install, run production Phonon checks:

```bash
python3 scripts/phonon-runtime-tests.py
python3 script/verify_phonon_lifetime.py
PROBE_ROUNDS=1000 PROBE_PLAYBACK=1 bash script/verify_phonon.sh
PROBE_LONG_ONLY=1 bash script/verify_phonon.sh
```

The CLI uses the canonical signed helper and disposable profile/model data.
It checks real synthesis, overlapping voices, cancellation/recovery, audio
playback speeds and rapid stops without starting another GUI. Optional
`PROBE_CORPUS=/absolute/path/replies.json` uses a local array of reply strings.
`PROBE_PURE_ONLY=1` runs PCM, streaming trim, segmentation and voice migration
checks without starting a model. `GET /speech/state` on the existing local
control interface reports selected engine/voice/speed and playback state.

Kokoro remains an isolated legacy comparison path, fixed to its Heart voice.
Its older probe remains available for explicit comparisons:

```bash
./script/verify_kokoro.sh
bash script/verify_voice_process.sh
bash script/verify_talk_context.sh
node --test scripts/stage3d_tests.mjs
```

The speech probe compiles the production engines into a standalone CLI linked
against the existing build dependencies. It never launches another HeyMate GUI
or changes the app's preferences. It requires already-downloaded models and
runs 400 sentences from four overlapping callers, then checks recovery after
a cancelled call. `PROBE_ROUNDS=40` selects a shorter check. A pass reports the
actual sentence count; an Xcode test summary with zero tests is not evidence.

Kokoro inference now runs in the signed `Contents/Helpers/HeyMateSpeechRunner`
process. A native model trap cannot be caught by Swift in the GUI process;
helper loss becomes an error and the production TTS client continues the
remaining text with the Mac voice. Failed helpers have a 60-second retry
cooldown. Audio travels through pipes and is not written to disk.

The process probe checks persistent requests, a native worker trap, restart,
fragmented replies, cancellation, timeout, and malformed output. The context
probe runs production hotkey matching, voice/typed capture policy, image-label
ordering and speech terminology without a GUI or privacy prompts.

`PROBE_CORPUS=/absolute/path/replies.json` supplies a local array of reply
strings to the speech probe. `PROBE_REPLAY=1` replays those sentences serially;
the default remains four overlapping callers. `PROBE_PLAYBACK=1` checks actual
production playback. `PROBE_RUNTIME=v3` is an explicit alternate-runtime
experiment that may download v3 assets; it does not change the app's runtime.
See [the November 1 repair evidence](voice-screen-repair-2026-11-01.md).

The 3D checks use the bundled Three.js math with a stub renderer to verify
same-beat group parenting, complete model bounds, first-frame cursor projection
and framing in narrow cards. Check rendering and speech playback in the installed
app separately.

For the native explanation renderer, `./scripts/verify_native_metal.sh` runs bridge
regressions and renders production Metal pipelines on the local GPU with API
validation, without installing or launching HeyMate. Gallery PNGs are written to
`../output/metal/`. See `native-metal-renderer.md` for source provenance and
remaining reference-calibration limits.

## Cua driver comparisons

The reviewed driver pin lives in
`Packages/HeyMateComputerUse/Sources/HeyMateComputerUse/CuaDriverRelease.swift`.
Change the version, installer URL, and installer SHA256 together, after checking
the release archive and mutually compatible designated requirements. Never run
an installer that would reset TCC to make an upgrade work.

`scripts/compare_cua_drivers.py` compares two already-reviewed binaries using
HeyMate's embedded MCP arguments. It checks tool presence and top-level input
schemas, reads permissions with `prompt:false`, and times screen-size calls.
It does not install anything, prompt for permissions, or capture the screen.
Permission results belong to the invoking host, not HeyMate or the standalone
Cua daemon. These timings do not measure agent task completion.

For synthetic native-action checks, compile `scripts/fixtures/cua-comparison.swift`
to a temporary executable and pass it with `--fixture`. The script launches a
temporary window for each driver, clicks its counter button, types synthetic
text, replaces the field through `set_value`, verifies the result through the fixture's own state, checks foreground
identity before/after, and terminates only its own fixture and MCP children.
Missing permission, missing controls, failed actions, and changed foreground
identity fail the fixture comparison. Foreground identity checks do not detect
every transient focus change.

Run the comparator with `--baseline`, `--candidate`, and `--output`, each taking
an absolute path. `--samples` controls read-only timing calls (default 20).
The checked-in `cua-driver-comparison-2026-11-05.json` records the 0.34/0.38
comparison, integrity checks, and its limits. Chrome, capture, drag, cancellation,
and post-install HeyMate permission continuity require separate live checks.

Cua 0.38 defaults to Markdown-only window trees. HeyMate negotiates
`tree_format:"both"` when advertised so structured controls and Markdown-only
visible text remain available. Older drivers receive no unsupported argument;
geometry-only reads keep their existing capture behavior. New upstream tools
do not automatically enter HeyMate's approved tool list.

`--probe-legacy-replacement` additionally diagnoses the old background
Cmd+A/`type_text` sequence, separately from the corrected-path checks. On both
reviewed versions, the tools reported success while the fixture text was not
replaced. Complete, native window-rooted text fields now use `set_value` and
require confirmed value-readback evidence. Partial trees, missing ancestry,
secure subroles, and web-area ancestors do not qualify for this native route.
The comparison does not establish replacement correctness inside web apps.

For broader native checks, compile the same fixture and run
`python3 scripts/verify_cua_workflows.py --fixture /absolute/path/to/fixture --output /absolute/path/to/report.json`.
This captures only the synthetic window, checks Return, targeted scrolling,
slider drag, stale handles, and session shutdown/recovery. Native slider drag
required foreground fallback on the tested Mac. Capture bytes stay in memory.
`python3 scripts/verify_cua_browser.py --output /absolute/path/to/report.json`
uses a driver-owned temporary Chrome profile and a loopback fixture, including
page-event verification, tab capture, and stale-ref refusal. It does not touch
the user's existing Chrome profile. Browser setup remains outside the agent
allowlist. `node scripts/browser_live_check.mjs` separately runs the production
extension engine against real Chrome/CDP with a `chrome.*` adapter.

`bash script/test_cua_client.sh` runs the production MCP client against a delayed
synthetic driver. Cancellation and timeout must terminate the owned embedded
runtime so a late side effect cannot occur. A structured `effect:refused` is a
failure even when Cua omits `isError`. These tests reproduced a late-action bug
before the client fix. See `cua-broader-checks-2026-11-05.json` for evidence and
permission-identity limits.

## Local memory retrieval

`memory.json` remains the authoritative, editable text store. Optional
`updatedAt` and `sourceConversationID` fields preserve correction dates and
source links without inventing provenance for old records. Completed mate
chats refresh only their own rolling summary when saving is enabled. These
summaries retain the most recent 800 characters; they are context, not proof
that an action succeeded.

`FileMemoryRepository.recall` filters ownership before creating a disposable
in-memory SQLite FTS5 index. Scope filtering therefore also applies to BM25's
corpus statistics. Search uses normalized, parameter-bound terms, with a local
lexical fallback if FTS5 is unavailable. Existing shared durable records stay
shared; private records are not automatically promoted. Mate `AGENTS.md` files
remain separate and unchanged.

The prompt selects up to eight records, reserves room for up to two stable
preferences, and caps the entire memory block at 6,000 characters and each
memory's text at 1,000. A substantive query does not fill empty slots with
unrelated project facts. Short continuation requests retain recent scoped
context. This character budget is not an exact provider-token budget.

Any mutation discards the derived index. Forgetting and manual corrections also
invalidate pending extraction, preventing an old asynchronous result from
restoring forgotten facts. Deduplication checks the current store and owner.
Deleting a memory does not delete saved chats or workspace `AGENTS.md`; those
can still contain the original conversation or notes. There is no persistent
search database, embedding copy, cloud memory service, or automatic semantic
contradiction resolver in this version.

Run `bash script/test_memory_core.sh` for production storage/index/retrieval
tests with disposable data. Set `HEYMATE_MEMORY_EVIDENCE` to an absolute output
path to reproduce the synthetic comparison in
`memory-recall-comparison-2026-11-05.json`: twelve older relevant facts among
1,012 records, comparing the old newest-eight selection with relevance search.
This measures lexical retrieval, not end-to-end model accuracy.

## Parallel browser workers

The default follows the user's chosen mode: `use_chrome` keeps the existing
Chrome profile and sign-ins, with separate owners for each native mate/chat.
The app supplies that identity and a random per-turn capability; model arguments
cannot choose them. Extension 0.5.1 / protocol 4 orders each owner's commands
while different owners progress concurrently. Each chat has a named tab group,
its own approval grant and approval-element cache. Other owners' tabs and active
claims are omitted from discovery. Owned pages remain private even after their
owner ends, including kept results. Unowned user tabs can be claimed by one
active task at a time. `show` must pass ownership checks too.

Cookies, local storage, sign-ins, account settings and server-side state remain
shared. Separate tab ownership does not isolate concurrent writes to the same
website account. No personal profile is copied, replaced or signed out.

Scope revocation ends only that owner's task. Cancellation/timeout immediately
stops its engine task and blocks queued actions; it cannot undo an input or
request already delivered to a website. Such outcomes remain unverified.
Normal completion tidies only that owner's unkept background tabs. A current
tab left in the mate's group stays open and keeps its owner. Moving a tab out
of the group lets it return to the user at cleanup. A late cleanup for an older scope cannot end its
replacement. Disconnect clears app-side grants and stops all extension tasks.
Legacy globally-owned tabs become user tabs on migration and stay open.

After installing the app, reload the unpacked HeyMate extension once in
`chrome://extensions` (version 0.5.1). Old protocol versions are refused instead
of silently collapsing all mates into one worker. Chrome's existing sign-ins
stay in place. The app copies updated extension files into its existing data
folder at startup; it does not restart Chrome to reload an unpacked extension.

`use_browser` is an optional clean-profile route, offered only for an explicit
user request for separate sign-ins. Each chat receives a separate owned Cua MCP
process and `isolated_new` Chromium profile, exact PID/window binding, opaque
native tab/ref mapping, a command queue and an approval grant. Four clean workers
may run at once. They each navigate one page; keyboard submission and file
transfers are not offered. Page reads use `semantic_v2` viewport outlines, not
full-document extraction. `keep` retains a page between turns; four minutes of
inactivity, cancellation, app shutdown or `end` closes it and removes its
throwaway sign-ins. Preparation is trusted native code; no raw setup capability
or profile path is given to models. There is no automatic switch between shared
and clean profiles.

For clean workers, Cua transport shutdown closes stdin so Cua runs its owned
browser/profile cleanup. Sending SIGTERM skipped that cleanup on the reviewed
0.38 driver. The native-drive transport keeps its existing immediate termination
policy. Live clean-profile tests verify actual browser exit, profile removal,
and cancellation during a delayed navigation with no later page effect.

Checks without installing or launching another HeyMate GUI:

```bash
node --test scripts/browser_core_tests.mjs scripts/browser_port_tests.mjs
CHROME_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node scripts/browser_live_check.mjs
bash script/test_browser_workers.sh
HEYMATE_BROWSER_LIVE=1 HEYMATE_BROWSER_FIXTURE="$PWD/scripts/fixtures/browser-workers.py" bash script/test_browser_workers.sh
bash script/test_cua_client.sh
```

Disposable shared-profile checks run production extension code against real
Chrome/CDP with a `chrome.*` adapter. They verify shared synthetic
cookies/storage, separate groups, actual concurrent progress, foreign tab/ref
refusal, per-owner end and cancellation. A separate signed-in check ran two mates
through the installed app and extension, confirming concurrent input and tab
ownership against loopback fixtures. Clean-profile live checks use the production
Swift worker pool/client and real Cua with loopback fixtures. See
`parallel-browser-workers-2026-11-05.json` for recorded evidence and limits.
