# Product polish verification — 11 October 2026

## Current result

The combined app, embedded runner, and test targets built successfully with ad-hoc signing. The complete HeyMateTests target passed **1,116 tests in 167 suites**, in **30.532 seconds**. `git diff --check` passed. Independent reviews of creation, consent, response ownership, and private-result delivery found no remaining blocker after the fixes described below.

This local result includes the original EOF fix from PR #14 and all current PR #20 polish. The branch includes the original #14 commit (`5686c14`) through a merge, rather than reauthoring its patch. Final-head CI is a separate check.

**Core native acceptance passed after unlock.** Two distinct mates, saved notes, navigation cancellation, complete job delivery, and restart persistence were verified with the real Codex GPT-6-Luna provider. Screen-guided teaching remains pending because macOS denied screen capture for the ad-hoc candidate before a model call. PR #20 remains draft until that live check and final-head CI pass. The requested video is now an animated product demo, explicitly replacing continuous screen recording.

## Behavior covered

- Each mate receives its own name, job, personality, saved note, and owned summaries. Bounded on-device prompts retain identity and capability rules. Shared preferences/project facts remain shared; legacy ownerless summaries remain stored but are excluded from replies.
- Explicit named creation happens locally, preserves instructions, handles duplicate names, and conservatively rejects cancelled, qualified, and compound creation commands. Creating a mate shows a distinct local greeting and one editable starter without sending a model request, activating connectors, creating a workspace, or starting a job. Starter use/dismissal persists across reopening; legacy chats still decode.
- Teaching stays in chat. Foreground responses and intent classification retain their originating conversation/provider and reject stale callbacks after navigation, cancellation, or replacement. Background routines and handoffs retain their own chat; late completion does not recreate deleted history or ignore disabled history.
- Pending approvals remain request-scoped. Navigation preserves unrelated running jobs, approvals, and voice input. Changing provider/model during a voice classification releases only that request's finished-input state and preserves newer recordings.
- OpenCode consent follows the receiving mate, model, explicit executor choice, and conversation. Confirmation revalidates its target and resumes the original route. Explicit background agent commands use the receiving mate's provider; classifier rewrites preserve explicit executor choices. Both job launch boundaries refuse an unapproved OpenCode switch before a CLI call.
- Successful jobs retain their full private answer, up to 32 KiB with an explicit truncation notice, and deliver it to the initiating chat. Missing results are reported as unverified rather than generic success. Failed, blocked, cancelled, and handed-off runs have distinct outcomes.
- Private final answers use attempt-scoped, atomically durable files with restrictive permissions and guarded reads. Credentials/local absolute paths are redacted; normal source URLs remain useful. Portable receipts and runner journals exclude private answer prose. Journal-before-state recovery, ordinary replay deduplication, follow-ups, and localhost preview resolution are covered. Chat/store writes are not a single cross-file transaction; these tests do not claim crash-atomic exactly-once delivery.

## Failures found and fixed

1. The first combined run exposed the existing CLI EOF spin. The exact original PR #14 patch passed its EOF/runner diagnosis: **12 tests in 3 suites**, 8.829 seconds.
2. Complete runs still timed out in short runner fixtures. The failure reproduced after manager-heavy suites. A process/stack sample showed approximately 60 real OpenCode/npm/node children and ten cooperative threads blocked in automatic CLI readiness probes. This was not resolved merely by removing speech-model warmup.
3. The test host now skips automatic readiness probes and selects system voice providers only when actual XCTest hosting is detected. Explicit readiness-probe APIs/tests remain available. A scratch QA app using only `HEYMATE_TEST_DATA_ROOT` keeps normal services. The original preference snapshot and exit restoration remain. No runtime or test timeout was increased.
4. Review found and fixed explicit-agent provider misrouting, missing executor-override consent, and a stuck foreground voice state after model changes. Targeted regressions are included in the final complete run.
5. Live capture failed with ScreenCaptureKit domain `com.apple.ScreenCaptureKit.SCStreamErrorDomain`, code `-3801`. The failure occurred before a model call, but generic advice incorrectly blamed model settings. The exact permission denial now explains screen-recording access and app relaunch. Localized-message and unrelated-domain/code controls passed; capture and consent policy are unchanged.

The successful runner fixture completed in 0.114 seconds in the final run; all five terminal-result scenarios completed in 0.371 seconds. Existing framework/deprecation warnings remain; no build error remained.

## Reproduce

Run from the repository root:

```sh
xcodebuild \
  -project heymate/HeyMate.xcodeproj -scheme HeyMate -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/heymate-product-polish-derived \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  build-for-testing

xcodebuild \
  -project heymate/HeyMate.xcodeproj -scheme HeyMate \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/heymate-product-polish-derived \
  -only-testing:HeyMateTests \
  test-without-building
```

Local evidence:

- Latest build: `/tmp/heymate-screen-permission-build.log`
- Latest complete tests: `/tmp/heymate-screen-permission-full-tests.log`
- Latest result: `/tmp/heymate-product-polish-derived/Logs/Test/Test-HeyMate-2026.10.11_16-21-51-+0800.xcresult`
- Earlier integrated build: `/tmp/heymate-polish-final-isolation-build.log`
- Complete tests: `/tmp/heymate-polish-final-isolation-full-tests.log`
- Result bundle: `/tmp/heymate-product-polish-derived/Logs/Test/Test-HeyMate-2026.10.11_13-27-37-+0800.xcresult`
- EOF diagnosis: `/tmp/heymate-polish-pr14-diagnostic-tests.log`
- Order-dependent failure diagnosis: `/tmp/heymate-engine-manager-sample.txt` and `/tmp/heymate-engine-manager-processes.txt` (private local diagnostics, not release assets)

Earlier overlapping checks passed 141 tests/16 suites for identity/memory/navigation, 62/8 plus 3 routine tests for named creation, 16/2 after parser review, and 39/5 after navigation-state review. [CI at `5ab9a49`](https://github.com/UmarSiddiqui/heymate/actions/runs/38111416968) passed 1,064 tests/162 suites before the additional polish. These are historical, overlapping checks, not counts to add to the final 1,116.

## Live findings and remaining gate

Installed version 1.0.38 routed a direct request to create Pixel QA through an approved coding job taking roughly two minutes. Its resulting mate retained the name, but not a separate personality. A later identity reply used Pixel QA correctly; a saved note about a purple-triangle practice logo was missed and unrelated Photopea history appeared. Those observations motivated the creation/memory fixes; they are not tests of the patched build.

Earlier native attempts were blocked by a locked console. After unlock, the final integrated candidate was staged with an original-app/data/preferences backup. Through actual UI and provider calls:

- Pixel Coach and Patch Scout were created locally with distinct greetings and editable starters, without jobs or workspaces.
- Their separate role/personality and saved notes appeared correctly in actual replies.
- Opening a new chat while a reply was in progress cancelled it without late output in either conversation. Classification/navigation regressions are covered by automated tests; this live observation was a response cancellation.
- An approved read-only workspace-count job returned the full answer only to its initiating Pixel Coach chat. Counts matched the actual workspace: one direct non-hidden file and zero folders.
- After relaunch, both notes persisted and the job answer remained exactly once in its original conversation. This verifies ordinary replay, not crash-atomic delivery.

A screen-guidance request reached capture and failed with macOS permission denial before contacting the model. The actionable error correction is included and tested; regrant/relaunch and a successful live screen lesson remain required.

The Photopea editing sequence itself was separately verified manually through its real UI: Magic Wand (tolerance 16, contiguous), select white, Edit > Clear, File > Export as > PNG. The exported 1000×800 PNG has transparent pixels in all four corners and preserved opaque purple triangle/dot artwork. This is not evidence that HeyMate guided that edit.

Before merging:

1. Regrant screen capture to the patched app, relaunch, and verify a real Photopea screen-guidance response and step progression.
2. Confirm final-head CI, then merge using a merge commit so the original #14 commit remains in history.

The user replaced the requested screen recording with an animated Remotion product demo. Recreated interaction must be labeled clearly and must not imply that a failed or unverified live lesson passed.
