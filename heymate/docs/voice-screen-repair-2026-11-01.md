# Voice crashes and intermittent screen context

Validated locally on November 1, 2026, Australia/Perth. Actual system:
macOS 27.0.1 (26A434), Apple Silicon. Changes were made in
`/Users/umarsiddiqui/Projects/Umar/heyMate`; pre-existing unrelated edits were preserved.

## Established evidence

- Multiple real `/Applications/HeyMate.app` reports, including the November 1
  18:28 crash, trap in `libBNNS` under `BNNSGraphContextExecute_v2` and
  Espresso's `BnnsCpuInferenceOperation`. The app log places that crash during
  Kokoro sentence synthesis. This is not a catchable Swift error.
- The original in-process engine passed 400 simple sentences but trapped when
  replaying real conversation replies. Its crash report reproduced the BNNS
  stack. A newly downloaded Kokoro ANE v3 candidate also trapped in BNNS on the
  same Mac. Upgrading or selecting v3 alone did not repair this case.
- Push-to-talk used transcript wording to decide whether to attach the screen.
  Short follow-ups could therefore become text-only turns. Image bytes were
  attached by the backend, but their display labels, dimensions and OCR boxes
  were discarded by the Swift transport.
- A 3440-wide screen was reduced to 1280 pixels. In a live test, the assistant
  could not read ordinary 12-point text at that resolution. With the repaired
  2048-pixel capture and label transport, a new conversation read a fresh token
  and two-word phrase correctly at the same normal font size, without tools.
- An older October 28 report reaches `MainActor.assumeIsolated` inside the
  cursor frame timer. That callback is now scheduled explicitly on MainActor.
  The original invalid-executor-pointer cause is not established; this is a
  repair at the recorded crash site, not proof of its underlying cause.

## Resulting behavior

Kokoro runs in a separate, signed speech helper. Helper exit, timeout or invalid
output becomes an ordinary error. Mac speech takes over the current sentence
and the rest of the reply; later-sentence failures no longer silently skip
words. Cancellation, playback generation checks and a retry cooldown prevent
stale speech and repeated helper launches after a fault. The existing voice
preference is preserved.

Push-to-talk requests a fresh screen view independently of the transcript.
Existing app exclusions, handoff isolation, typed-chat rules and permission
preflight remain enforced. Both initial prompts and steering messages retain
ordered image labels. Transient ScreenCaptureKit errors receive one bounded
retry. Reply instructions and the shared speech sanitizer use natural screen
language, including “I couldn't see your screen.”

Upstream background: FluidAudio documents the
[legacy and v3 routing/fallback boundaries](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/Documentation/TTS/KokoroAne.md)
and the [input-padding repair](https://github.com/FluidInference/FluidAudio/pull/1038).
Those sources informed candidate selection; the local crash evidence and
physical-machine probes determined the repair.

## Verification

- Installed only through `script/build_and_run.sh --verify`; the GUI launched from `/Applications/HeyMate.app`. Deep signing, hardened
  runtime, nested executables and mutually compatible app requirements passed.
- Startup measured accessibility, Input Monitoring, microphone, screen and
  screen-content permission as granted. Actual live two-display capture also
  succeeded. Preferences were not used as permission evidence; TCC was not reset.
- 400 production speech sentences from four overlapping callers passed,
  including cancellation recovery. Another 400 real-session sentence replays
  passed through the isolated production engine.
- Production IPC probe passed persistent requests, native worker trap,
  restart, fragmented replies, timeout, cancellation and malformed output.
- Fault injection terminated the inference helper during production TTS.
  The CLI remained alive, started Mac speech, completed playback and stopped.
  The installed GUI also survived helper termination and returned HTTP 200
  from its health endpoint while logging Mac voice fallback.
- 25 production hotkey, capture-policy, image-label and speech checks passed.
  Full app/test compilation passed. The final timer change compiled in the
  verified signed build and exercised live cursor/drawing animation without
  changing its GUI PID or health status.

## Coverage limits

The BNNS kernel fault is contained, not repaired inside Apple's runtime.
The exact OS/kernel defect remains unproven. Short probes do not establish
indefinite stability. Physical audibility was not independently judged.
The automation surface cannot hold a modifier-only chord, so the physical
Control–Option microphone gesture was not replayed end to end. Its production
key transitions, capture policy and live downstream screen delivery were
verified separately. No human decision or permission reset is required.
