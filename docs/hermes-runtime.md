> Historical: Hermes was replaced by [HeyMate’s custom Pi harness](pi-harness.md) on 2026-10-27. Commands and capabilities below describe the retired implementation.

# Bundled native Hermes runtime

HeyMate can stage a sealed, headless Hermes runtime into `Contents/Resources/Hermes`. It contains Python, native wheels, the official engine source snapshot and baseline tools. It does not include Electron, the Hermes SPA, a user profile, credentials, or sessions.

Pinned source: `NousResearch/hermes-agent` commit `d923a5eb487a17c0a68801bba9ef0f56c81040a8`. The builder rejects a different HEAD or any tracked source modification before importing official build code. Tool artifacts follow that source's `pm/lock.json`; Python dependencies follow its frozen `uv.lock`.

## Build

The build host needs Python 3.11 or later and Git. The explicit bootstrap prepares official pinned Python, uv, ripgrep, Node and npm in build-owned scratch storage, then invokes the builder with the pinned Python. It does not install globally or select a live Hermes environment.

```sh
python3 heymate/scripts/hermes-runtime-build.py \
  --source /absolute/path/to/pinned/hermes-agent \
  --commit d923a5eb487a17c0a68801bba9ef0f56c81040a8 \
  --out /absolute/build/hermes-runtime-arm64/Hermes \
  --bootstrap --allow-downloads
```

Prepare the official checkout at the pinned commit first. CI should install/select its build-host Python explicitly. macOS's `/usr/bin/python3` 3.9 can run the stage/smoke/test helpers, but cannot import this Hermes revision's build APIs.

An offline build can instead use already-prepared **binary tools and wheel cache**, without copying an installed profile or selected application environment:

```sh
/absolute/pinned/python3 -I -B heymate/scripts/hermes-runtime-build.py \
  --source /absolute/path/to/pinned/hermes-agent \
  --commit d923a5eb487a17c0a68801bba9ef0f56c81040a8 \
  --tools /absolute/official/tool-store \
  --cache /absolute/uv-wheel-cache \
  --out /absolute/build/hermes-runtime-arm64/Hermes
```

The output and its sibling `.build`/`.bootstrap` paths must be new. The cache is copied before use; builds do not modify the supplied cache or tool store. Provider and token environment variables are removed before PM imports and child bootstrap. Fresh sealed application and PM environments are built through official PM APIs, with `all`, `web` and `acp` extras. The source snapshot comes from `git archive`, excluding tests, website, frontends, desktop source and build scripts.

## Manifest contract

A native payload retains the official `schema`, `target`, `runtime`, `store` and `venv` fields. HeyMate adds:

```json
{
  "schema": 1,
  "target": "darwin-arm64",
  "executablePath": "bin/hermes",
  "runtimePath": "tools",
  "sourceCommit": "d923a5eb487a17c0a68801bba9ef0f56c81040a8"
}
```

Paths are relative to the native payload root. They cannot escape through `..`, absolute paths or symlinks. The engine's canonical `install-stamp.json` records the same commit and `updateMechanism: external`; HeyMate owns replacement of the artifact. Its `payload: runtime` form deliberately avoids Electron bundle assumptions. This commit has no admitted release version, so `/api/health` reports `version: unknown`, `displayVersion: git.d923a5e`, and the exact full commit. Verify the full commit rather than inventing a release version.

Universal app packaging can aggregate independently built native payloads:

```json
{
  "schema": 1,
  "sourceCommit": "d923a5eb487a17c0a68801bba9ef0f56c81040a8",
  "payloads": {"arm64": "arm64", "x86_64": "x86_64"}
}
```

The aggregate root contains only that manifest and the named child directories. Each child is a complete native sealed payload with matching commit and architecture. Run native builders on matching hosts; this helper does not cross-compile Python wheels. Local evidence currently covers arm64 only. An Intel matrix job is required before claiming Intel/universal runtime support.

## Stage and sign

```sh
/usr/bin/python3 heymate/scripts/hermes-runtime-stage.py \
  --source /absolute/built/Hermes \
  --destination /absolute/HeyMate.app/Contents/Resources/Hermes
```

Xcode supplies `EXPANDED_CODE_SIGN_IDENTITY`, `CODE_SIGNING_ALLOWED` and `ARCHS`. A supplied identity signs and strictly verifies every nested Mach-O before the enclosing app is signed. An explicit `--identity -` performs an ad-hoc signing smoke. Native binary architectures are inspected with `lipo`; requested app architectures must all exist in the payload. Source payloads are not modified.

Hardened Python receives `com.apple.security.cs.disable-library-validation`, matching the relevant official Hermes inherited signing policy. Without it, ad-hoc/self-signed Python rejects native wheels with a Team ID mismatch. This entitlement belongs to the bundled Python executable, not a fabricated permission grant in the app.

Signing changes tool bytes. After signing, the stage helper refreshes `tools/facts.json` using the shipped official `pm.lock.Facts.refresh_digests` API, as the official Hermes packaging lane does. Aggregates use the host-compatible bundled Python to refresh both children; they do not execute a foreign architecture interpreter. Finally, the outer HeyMate signature seals the resulting bytes and metadata.

## Verification recorded on 2026-10-17

- Offline sealed arm64 build passed from pinned tool/cache inputs.
- Explicit online tool bootstrap passed in a new build-owned store, followed by pinned-Python reexecution and sealed builds. An existing copied wheel cache was supplied for that probe; a completely cold no-cache CI build remains unverified locally.
- Relocation into a directory containing spaces passed CLI version, ACP import check and `serve --help` with a fresh empty profile.
- Ad-hoc nested signing/strict verification passed for 69 Mach-O files in the current payload.
- The signed payload started actual `serve` with another fresh empty profile. Token-owned PID, headless mode, effective home and full source commit all matched. No model prompt, tool task, provider login or credential copy occurred.
- Six packaging admission tests passed: path escape, secret-file rejection, symlink escape, aggregate source mismatch, aggregate profile-state rejection, and incomplete universal architecture rejection.

Repeat the process smoke with a fresh output directory:

```sh
/usr/bin/python3 heymate/scripts/hermes-runtime-smoke.py \
  --payload /absolute/HeyMate.app/Contents/Resources/Hermes \
  --out /absolute/build/fresh-runtime-smoke-profile

/usr/bin/python3 -B heymate/scripts/hermes-runtime-tests.py
```

The smoke never sends a model request. Provider setup and an end-to-end real task remain separate acceptance checks.

## Size, optional tools and notices

The current arm64 payload occupies approximately 738 MiB on disk before app compression. It includes Node/npm for ordinary coding tools. It omits FFmpeg, Chromium, agent-browser and cua-driver. Native HeyMate voice does not require Hermes FFmpeg. Browser/media/computer-tool capabilities needing those binaries are therefore not guaranteed by this payload, and lazy installation is disabled in the app launch contract.

The pinned FFmpeg binary identifies itself GPLv3-or-later and its archive lacks corresponding-source material. It is excluded until redistribution obligations are addressed. Hermes' default completeness checker still logs an FFmpeg-missing warning; actual headless serve startup passed despite that warning. Do not claim the payload implements every default Hermes tool.

Hermes' MIT license is retained in `hermes-agent/LICENSE`. All shipped dependency license/notice files remain in place. `THIRD_PARTY_LICENSES.txt` consolidates the collected text, and `license-inventory.json` lists Python distribution metadata and hashed notice paths. The observed payload records 112 distributions and 488 license/notice files. UV's archive lacked license files, so exact-version MIT/Apache texts are included from the official `astral-sh/uv` 0.12.3 source tag. Collection is not a legal compliance certification. Five distribution records omit License/License-Expression/License-File metadata fields; license classifiers and retained source notices cover some of those cases. Review the inventory and shipped texts before public distribution.

Current signing evidence is ad-hoc. Existing HeyMate open-source certificate distribution and Apple Developer ID/notarized distribution are different release paths. This document does not claim notarization, public publication or Intel verification.
