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

Previous bundles are retained in
`~/Library/Application Support/HeyMate Install Backups/<timestamp>-<pid>/HeyMate.app`.
A failed replacement or post-install signature verification restores the old
bundle. If launch subsequently fails, that backup is available for a deliberate
restore; the script does not automatically execute a second app. Local installs
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
