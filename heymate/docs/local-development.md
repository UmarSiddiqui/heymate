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

After a verified local install, run the cached Kokoro integration probe:

```bash
./script/verify_kokoro.sh
node --test scripts/stage3d_tests.mjs
```

The speech probe compiles the production engines into a standalone CLI linked
against the existing build dependencies. It never launches another HeyMate GUI
or changes the app's preferences. It requires already-downloaded models and
runs 400 sentences from four overlapping callers, then checks recovery after
a cancelled call. `PROBE_ROUNDS=40` selects a shorter check. A pass reports the
actual sentence count; an Xcode test summary with zero tests is not evidence.

The 3D checks use the bundled Three.js math with a stub renderer to verify
same-beat group parenting, complete model bounds, first-frame cursor projection
and framing in narrow cards. Check rendering and speech playback in the installed
app separately.

For the native explanation renderer, `./scripts/verify_native_metal.sh` runs bridge
regressions and renders production Metal pipelines on the local GPU with API
validation, without installing or launching HeyMate. Gallery PNGs are written to
`../output/metal/`. See `native-metal-renderer.md` for source provenance and
remaining reference-calibration limits.
