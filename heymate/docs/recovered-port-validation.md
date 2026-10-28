# Recovered JavaScript port integration — 2026-10-28/29

Current upgrades and verification are recorded under **Second pass — 2026-10-29** below. The first pass is retained for context.

This audit starts from the existing local ports and wrappers. It does not claim that copied code alone improves behavior. No new REA, native painter/Metal reconstruction, Swift UI cloning, H1 harness replacement, or production deployment was performed.

## Changes made in this audit

- Browser wrapper now reports single-action and partially completed batch failures instead of treating their closing snapshot as success. Settled results retain the tab ID and observed URL, including redirects. Commands and turn boundaries serialize. Disconnect stops the old task, renews its identity after cleanup, and prevents old replies from reaching a new native connection.
- Notes now expose `note_read` for the current chat, including after restart or compaction. Concurrent incremental edits serialize. Reads propagate filesystem errors rather than silently treating unreadable files as empty. Note identities are validated, saves use private temporary files and atomic rename, and temporary files are cleaned up. Runtime test fixtures isolate their Notes directory.
- Drawing host clears its SVG, buttons, photo state and WebGL stages when the native canvas clears. This fixes a demonstrated orphan-canvas failure.
- 3D wrapper follows the actual SVG rectangle through movement and zoom, updates camera aspect and labels, disposes removed stages and their GPU resources, and releases its cached environment on reset.
- JavaScript resource IDs in the project file were repaired after a resource entry collided with the existing agent-runner target ID. Other project edits were retained.
- `scripts/verify_recovered_ports.py` checks pinned SHA-256 hashes for all six recovered modules and the copied 8,972-character note-editing block. `--installed` also checks installed engines, wrappers and note runtime against this checkout.

## Demonstrated behavior

- Runtime suite: 30 tests pass, including one-note-per-chat, incremental add/replace/remove/tick/answer, simultaneous edits, private file mode, restart/read-back and chat isolation.
- Browser adapter suite: 8 tests pass for result shape, redirect URL, error propagation, partial submit, reconnect, command ordering and ownership cleanup. Three existing 3D math tests pass for grouped bounds, first-frame cursor projection and portrait framing.
- Real Chromium CDP fixture: open, accessibility references, fill, click and resulting DOM change, password-field and covered-control refusal, extraction, key input, scroll, navigation, stale-reference rejection, back, owner refusal, refusal to close user tabs and tidy were exercised against local pages. Chrome tab/window/group APIs are simulated by the test facade; CDP, input and DOM operations are real. This does **not** establish the complete installed native-messaging path or real Chrome group UI behavior.
- Rendered fixture: future drawing beats stay hidden until their speech cue; line duration and continued drawings work. Recovered lathe, box and cylinder kernels produce real meshes (260, 24 and 292 vertices in this fixture). Labels, tick animation, pointer drag rotation, part picking, SVG movement/zoom tracking and complete clear cleanup pass.
- Installed native app: a disposable Markdown note appeared in the Notes list. Without reopening the note, incremental edits changed its answer card, advanced the checklist and added a table row. The disposable note and its isolated harness metadata were then removed.
- Installed WKWebView: the two-beat explanation rendered both labels on its card. Native 3D playback produced build/cursor callbacks for piston, connecting rod and crankshaft. Browser rendering/interactions have stronger automated assertions than this native smoke check.
- Cached Kokoro probe: 40 sentences across four overlapping callers passed, including the probe's cancellation/recovery checks. This checks synthesis, not measured speaker-output latency or frame-to-audio alignment.

## Reproduce

From the repository root:

```bash
python3 heymate/scripts/verify_recovered_ports.py
node --test heymate/scripts/browser_port_tests.mjs heymate/scripts/stage3d_tests.mjs
(cd heymate/agent-runtime && npm test)
python3 -m http.server 18742 --bind 127.0.0.1 --directory heymate
```

With that local server running, use the Playwright CLI:

```bash
mkdir -p output/playwright
playwright-cli --session heymate-ports open about:blank
playwright-cli --session heymate-ports run-code --filename heymate/scripts/browser_live_check.js
playwright-cli --session heymate-ports run-code --filename heymate/scripts/render_port_check.js
```

Only the approved signing/install workflow was used:

```bash
./heymate/script/build_and_run.sh --check
./heymate/script/build_and_run.sh --verify
python3 heymate/scripts/verify_recovered_ports.py --installed
PROBE_ROUNDS=40 ./heymate/script/verify_kokoro.sh
```

## Limits and remaining verification

No recovered engine or copied note-editing function was modified. Existing unrelated working-tree edits were preserved. Tests use synthetic local content. No user permission settings, TCC records, sign-ins, or signing identity were reset or migrated.

The installed Settings screen reported Chrome connected (extension 0.3.0) and all permissions on. Those observations do not prove every permission-sensitive operation or every browser action succeeds. A full installed-extension/native-host journey, real Chrome group movement/restoration, audible output and precise speech-to-frame timing remain unverified. The full Swift test suite was not run. Existing project duplicate-resource and Swift concurrency warnings remain.

Final status: **installed and verified**. `script/build_and_run.sh --verify` passed app and 10 nested-code signature checks, installed `/Applications/HeyMate.app`, and confirmed it remained running (PID 69889). `verify_recovered_ports.py --installed` passed for all six engines, copied note-editing functions, drawing/3D wrappers, browser wrapper/manifest, and note runtime. A later check found the app stopped, with no new HeyMate crash report found. It was reopened only from `/Applications/HeyMate.app`; final process check showed canonical PID 70334, and installed-byte verification passed again.

Concurrent edits initially introduced a project resource-ID collision and a transient invalid `.drawJS` route. The resource collision was repaired narrowly; the route was corrected externally. An externally launched Xcode copy (PID 67500) then blocked installation. After the user authorized quitting it, it was selected at its known running path and quit normally through the app's Quit command. It was not force-killed or relaunched. The resumed canonical install completed.

**Remaining activation step:** reload the existing unpacked HeyMate Chrome extension. A connected worker can still be running an older in-memory script even after its files have been copied. Automated access to `chrome://extensions` was rejected by browser security policy, which expressly prohibited alternate UI/CDP workarounds. The blocked navigation was not bypassed; its empty test tab was closed. The user must perform the reload manually. Full installed-extension/native-host validation remains open until then.

The final built candidate can be inspected without installation or launch:

```bash
python3 heymate/scripts/verify_recovered_ports.py --bundle heymate/build/DerivedData/Build/Products/Debug/HeyMate.app
```

## Second pass — 2026-10-29

All five requested upgrades are implemented locally. The final signed install passed through `script/build_and_run.sh --verify`, including app and 10 nested-code signatures. Installed engines, wrappers, browser manifest and runtime sources (including the new `batch-reads.mjs` and `note-workflow.mjs`) passed byte comparison against this checkout. No recovered engine or copied note-editing function changed. No production deployment, ad-hoc signing or TCC reset was performed.

### Browser file workflows

`use_chrome` now exposes `upload`, `download`, `dialog` and `keep`. Native upload validation accepts 1–10 absolute paths and checks readable regular files. Every upload asks for approval naming the files and a freshly read destination URL. That URL is passed to the extension, which refuses the upload if the destination changed. Accepting a page dialog always asks; dismissing it does not. `keep` preserves result/waiting tabs across cleanup and must be renewed in later turns.

Downloads use the recovered engine's complete/held/interrupted state reporting, a 65-second native timeout, and recovered download attribution/filename callbacks. Only the destination-folder prefix is adapted to `HeyMate/`; Chrome's dangerous-download holds are never bypassed. Extension version is now **0.4.0**, with the Chrome `downloads` permission added. The user must reload the existing extension and approve Chrome's permission request before testing the installed download path. The previous security-policy rejection of automated extension-settings access was not bypassed.

Browser tests now cover the new wrapper routes, upload destination changes, kept-tab cleanup, download event wiring and complete/held/interrupted results. The real Chromium CDP fixture also uploaded a synthetic local file into an actual file input and dismissed an actual page dialog. Its tab/window/group APIs remain simulated; the installed native-host journey remains unverified.

### Drawing cleanup

The host now calls recovered `keepNotesOnly()` for finished drawings and `dropPointing()` while drawing. Native app switches, external clicks/scrolls and native browser actions trigger debounced cleanup. The native pointing target is cleared too. Screen-change observers and monitors are removed when the overlay closes.

The rendered browser regression drew an outside-screen mark and an independent card, then verified that cleanup removed `OLD PAGE` while preserving `KEEP CARD`. Existing speech-beat gating, continuation, 3D geometry, labels, animation, picking, dragging, SVG zoom and clear cleanup still passed.

### Notes previews and recovery

Partial Pi note-tool arguments now feed separate, private, atomic preview JSON files, throttled to 200 ms. The native Notes list shows “Writing…” and renders the preview without committing the saved Markdown. Previews expire after eight seconds if streaming stops. Executing the tool closes that call's preview; late stream updates cannot bring it back. Turn termination removes previews.

Note edits now persist call-ID receipts with before/after content hashes before writing. Replayed calls do not append twice. A crash after the note rename can resume without repeating the edit; conflicts with newer contents are refused. The recovered editing functions remain unchanged.

A bounded, at-most-once note-finishing pass checks for an answer line, stale current-work markers and open code fences. Only note tools are active during that pass; shell, browser and connector tools are disabled. It preserves the original verified answer and never ticks unfinished tasks merely to make the note look complete. Cleanup is capped at 12 seconds; remaining issues emit an unfinished-note event.

Native smoke check visibly rendered a synthetic “Port preview — disposable” with “Writing…” and partial contents. The final save succeeded on disk; the UI changed away before a final committed-page screenshot could be confirmed. The synthetic note and its isolated runtime metadata were removed. Restart, deduplication, preview/save separation and closing-pass behavior are covered by runtime tests.

### Read batching

`batch_read` accepts 1–8 structured read calls, not arbitrary JavaScript. It preflights the entire batch, rejects writes/shell/questions/nested batches, preserves original scoped tool execution and cancellation, returns results in input order with separate errors, and caps aggregate text at 24,000 characters. Available entries are the builtin file reader, connectors explicitly marked read-only, and only the read operations of the native Chrome tool. Write approvals and idempotency paths remain in place.

Three independent fixture waits totaling 180 ms sequentially completed in approximately 91 ms as a batch, with three simultaneous readers. This is a synthetic concurrency result, not a measured twofold improvement in whole-app or model latency.

### Notch file eating

Accepted file hover now opens the shelf's mouth surface instead of merely setting an invisible hungry state. A local blob silhouette surrounds the eyes/mouth; the dropped file icon shrinks into the mouth before the stored shelf appears. Reduced Motion uses a static confirmation. A per-meal identity prevents an earlier animation timer from finishing a newer drop.

The AppKit destination rechecks handler presence, same-window source rejection, bounds and file URLs on entry, update, prepare and perform. Rejected or ended drags clear hover state. A drop still succeeds only when the shelf actually accepts files or already holds them; original files are not moved or deleted.

Native Finder-to-notch drag automation could not establish a usable desktop drag target (`noWindowsAvailable`). The complete gesture and animation are therefore **not claimed as demonstrated**. New policy/approval Swift tests were added, but the full Swift test suite was not run. App compilation and signed installation passed. Synthetic desktop files and the accidental test-path clipping were cleaned up without touching user files.

### Final checks and remaining limits

- **37 runtime tests passed.**
- **12 browser/adapter tests and 3 existing 3D math tests passed** (52 automated tests total).
- Rendered drawing/3D/screen-cleanup checks passed.
- Real CDP file-upload and dialog checks passed, with the facade limits stated above.
- Final installed-byte and signing checks passed; only `/Applications/HeyMate.app` was launched by this work.
- Pending manual verification: Chrome extension 0.4.0 activation/Downloads permission, full native-host transfer workflow, Finder-to-notch gesture/animation, and precise audible speech/frame timing.

## Third pass — source ports, 2026-10-29

This pass follows the request to port the recovered implementation rather than design replacement behavior. The six original engines and the 8,972-byte note-editing block retain their original pins.

### Source and integration

- **Screen statistics:** native algorithm translated from byte-verified 1.1.1 arm64 instructions: twenty-bin dominant luminance, original RGB weights, clipping, scanline busyness and the 0.58 ink threshold. The same screenshot supplied to the model feeds the host through a validated RGBA transport. Missing/replaced captures and screen changes clear old pixels. This is an instruction-derived port, not recovered original Swift text. Addresses and limits are in `native-drawing-port.md`.
- **Native illustrated shading:** the 12,203-byte original Metal source literal is preserved under `scripts/native-shaders/`. Six original fragment/helper bodies run through mechanical MSL-to-GLSL type, intrinsic, array and resource-signature substitutions in the illustrated stage. `scene3d()` uses this path; `figure()` retains its separate studio path. The host supplies camera, inverse-transpose normals and changing material uniforms.
- **Durability:** 2,624 original emitted H1 journal bytes retain their retry/replay implementation. A private fsync storage adapter journals tool outcomes and complete model responses. Before-start write markers refuse uncertain crash outcomes. An explicit host-verified answer checkpoint closes the final native-ledger crash window; restart can restore that completed answer without executing a model or tool. It never infers completion from an arbitrary model stop or note-cleanup answer. Stable keys include the persisted turn identity. This ports step/result durability, not the entire private H1 Workflow loop.
- **Tool orchestration:** 7,304 original formatted H1 script/early-read bytes are pinned. The original script runner executes unchanged inside a bounded QuickJS WASM heap, exposing only registered tool callbacks. Nested calls retain schema validation, scope, approval and journal wrappers; writes serialize. Cancellation aborts nested calls, bounds cleanup and reports unknown outcomes when a host call ignores cancellation. Unawaited calls cannot be reported as success. Original early-read execution starts only explicitly read-only active tools after complete streamed arguments, then reuses the same result during ordinary Pi execution. Native browser operations retain their ordering.
- **Telemetry:** 2,586 original H1 usage/reducer/logger bytes are unchanged. Pi provider hooks record request send, response-header arrival (the original first-byte measurement point), first reasoning/output, end, HTTP status and cache usage. Tool records retain execution timing, early-read timing and result length. Each physical early read counts once. Logs omit prompts, tool arguments, response bodies, headers and error bodies. Unavailable observations remain null.

The adapters are HeyMate code; their boundaries are explicit. Original source ranges and module hashes are pinned in `recovered-h1-orchestration-hashes.json`, `recovered-journal-provenance.json`, and `recovered-telemetry-hashes.json`. `verify_recovered_ports.py` checks the new pins and installed runtime/dependency locks as well as the existing engines.

### Evidence and remaining scope

Swift app and test targets compiled with `scripts/typecheck.sh --tests`; this is not execution of the full Swift suite. Runtime tests include a real Pi stream that starts an early read before model completion, executes the recovered program with parallel reads and an approved file write, and verifies model/final-answer checkpoints. A real loopback HTTP provider verifies the telemetry hooks and private-content exclusions. Crash tests include an actual process exit during a write.

The real Chromium rendering regression passes speech-beat gating, continued drawings, cleanup, recovered geometry, labels, motion, pointer picking and SVG tracking. The illustrated shader compiled on the real GPU and rendered a 1,617-vertex sphere: 52,874 opaque pixels, 51,342 red pixels, 375 colors and no GL error. The retained original Metal source also compiled with `MTLDevice.makeLibrary`, exposing all seven original entry points. These establish functioning shader ports, not pixel parity with the reference app.

**Native rendering remains a partial port.** Core Animation card painting, Core Text shaping, native material preset tables, native illustrated-light defaults, outline/seam ID passes and the studio multipass host are not fully recovered/ported. No substitute implementation was added for those missing native components. Precise audible speech/frame timing remains unverified. Browser activation/permission and full native-host transfer checks from the previous pass remain separate outstanding work.

### Final installed verification

The complete runtime suite passed **63 tests**; browser, screen-sampling and 3D adapter suites passed **25 tests** (88 automated checks total). The rendered Chromium regression and original Metal compilation passed separately. `scripts/typecheck.sh --tests` compiled the Swift app and tests; the full Swift test suite was not executed.

`script/build_and_run.sh --check` passed the existing certificate preflight. The first install attempt refused a Homebrew-linked Node before changing the app. Re-running the same approved workflow with `HEYMATE_NODE_BINARY=/Users/umarsiddiqui/.nvm/versions/node/v24.21.0/bin/node` completed `--verify`: app and ten nested code signatures passed; `/Applications/HeyMate.app` launched and remained alive (PID 26882). No alternate GUI copy was launched, signing identity changed, or permission database reset.

`verify_recovered_ports.py --installed` passed all six engines, note block, new H1 source pins, wrapper/runtime comparisons and dependency locks. The packaged backend smoke test also loaded the installed QuickJS WASM and executed the original recovered script runner through an isolated fixture callback, then confirmed owned backend identity, health and configuration. This used a disposable backend profile, not another GUI or the user's sign-ins. New source-range modules retain **12,514 original H1 bytes** in total; native algorithm/shader translations are classified separately.
