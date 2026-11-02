# Phonon local speech rollout — 2026-11-01

HeyMate's on-device speaking provider now uses Phonon through a private,
bundled Ollama service. Parakeet listening remains unchanged. This is installed
locally on the Apple M5 Mac running macOS 27.0.1, not a published release.

## Behavior

- Stream 24 kHz mono PCM directly into AVAudioEngine. Playback starts before
  synthesis completes; no speech audio is written to disk by the app.
- Zoey is the default. Ten Phonon voices are available in Settings and previews.
  Old Kokoro voice IDs resolve to Zoey; valid new selections persist. The stored
  on-device provider ID remains `kokoro` for compatibility with existing choices.
- Keep speech speed preferences. AVAudioUnitTimePitch applies the rate locally;
  Ollama's speech API does not accept a speed parameter.
- Split sentences, bound unpunctuated input to 1,000-character segments, and
  trim only edge silence. Streaming trimming preserves pauses inside a sentence.
- Inference runs outside the GUI. Failed synthesis finishes queued audio and
  uses the Mac voice for the failed segment and remaining text. A partially
  spoken failed segment can repeat; remaining words are not silently dropped.
- Stop cancels HTTP synthesis and queued playback. Generation checks prevent
  late chunks from reviving an interrupted reply.
- The signed speech helper owns its private loopback Ollama server. GUI exit,
  helper termination, native helper failure and synthesis errors clean up owned
  workers. Cleanup checks executable path, PID and kernel process start time
  before signalling the server process group. System Ollama is not used.

## Packaging

Pinned Ollama **0.40.13**, official macOS archive SHA-256:
`bae29252232b9e1358cf5801a7d65a07442af18fb5467cb68c7fc3711f59c511`.

Pinned `phonon:latest` model manifest SHA-256:
`d47cfe951d4d684faecb78d21f5698c56b3181f573628a0eb1ee42346d140f2e`.
The model's original manifest digest is
`58f58601e4e83c6d5c06f87ca91071e0a9acfd6d169515fd8eb3da27965b990e`.
The normal `phonon` alias includes the full voice catalog; the tested explicit
`phonon:31m-en` tag only exposed its checkpoint default.

`scripts/phonon-runtime.py` verifies the official archive and every model blob,
includes both Metal runtime variants and upstream licenses, and stages the
payload into `Contents/Resources/PhononRuntime`. AppleDouble `._*` metadata is
excluded: retaining it made copied bundles fail their resource seal because
`ditto` consumed those metadata files.

Xcode signs nested native images with the existing identity and hardened runtime,
then signs the app normally. No recursive app signing, new app entitlements,
ad-hoc signer or TCC reset. The verified install checks 27 nested code images.
Build/release workflows prepare the same pinned payload; no release was run.

The bundled speech runtime and model occupy **656 MiB**; the installed development
app occupies approximately **1.2 GiB**. On first preparation, model data is copied
to `~/Library/Application Support/heymate/Phonon/models` so Ollama never modifies
signed resources. Speaking requires no runtime download or separate Ollama app.
Listening still has its approximately 500 MB automatic Parakeet download.

Official references: [Ollama speech API](https://github.com/ollama/ollama/blob/main/docs/capabilities/speech.mdx),
[pinned Ollama release](https://github.com/ollama/ollama/releases/tag/v0.40.13),
[Phonon model](https://ollama.com/library/phonon).

## Executed validation

Two production Swift integration runs each completed:

- 1,000 segments from the existing local real-session reply corpus;
- 40 requests from overlapping callers, exercising all ten curated voices;
- 40 cancellations, alternating immediate cancellation and a 5 ms delay
  after starting the request, each followed by a successful recovery request;
- real AVAudioEngine playback at 0.75×, 1× and 1.5×;
- 20 rapid playback stops, followed by successful recovery playback.

Total: **2,000 real replay segments + 80 overlap + 80 recovery syntheses**,
with 80 explicit cancelled requests. The replay alone produced approximately
128.5 minutes of valid, non-silent audio. The first run used the signed build
candidate's helper without launching its GUI; the second used the installed
canonical app's signed helper. Both ran in disposable data profiles.

Final installed-helper replay measured warm median first PCM **9 ms**, p95
**25 ms**; complete synthesis median **114 ms**, p95 **232 ms**. The first
request in that fresh profile took **10.75 seconds** to first PCM, **11.62
seconds** to finish. The earlier fresh-profile run took **11.83 seconds** to
first PCM. Do not assume every cold start matches the prepared app's measured
**655–822 ms** launch warm-up across verified installs. These timings include Swift transport/PCM handling;
they are not physical speaker-output latency. Other local work ran during tests.

Identical text finished actual playback in **5,508 / 4,049 / 2,817 ms** at
0.75× / 1× / 1.5×, confirming that the speed setting changes playback duration.
A separate 1,020-character request produced 61 seconds of valid audio. A
6,120-character unpunctuated production reply began playback, was interrupted,
stayed stopped after delayed callbacks, and allowed immediate synthesis recovery.

Live installed app checks:

- Phonon selected, Zoey active, existing speed preference intact.
- Multi-sentence `/speak` request completed actual playback.
- Twenty rapid `/speak` replacements finished without stale playback.
- Terminating the owned Ollama server triggered Mac speech fallback; the next
  request restarted Phonon and completed.
- Injecting SIGTRAP into the GUI's speech helper (PID 3157, 23:23:58 local;
  the resulting diagnostic report is intentional test evidence) cleaned up both its Ollama
  server and MLX worker. The GUI PID stayed unchanged, Mac speech finished the
  reply, and a subsequent request restarted Phonon and completed.
- Native chat UI sent a new text-only test turn. The real conversation backend
  returned “Five.” and the production Phonon client scheduled playback. Logs
  confirmed zero screen images for this typed turn.
- Closing a standalone signed helper's stdin (parent EOF) and sending it
  SIGTERM both stopped its actual Ollama server and MLX worker. No model
  processes from the completed probes remained.
- After a concurrent local build, final canonical playback, signing preflight,
  helper/build hash match and worker-lifetime checks passed again.
- Signing/install verification passed at `/Applications/HeyMate.app`; one GUI
  instance. Startup measured accessibility, input monitoring, screen capture,
  microphone and screen-content authorization as true.

Full app and test targets compile through `scripts/typecheck.sh --tests`.
Executed standalone checks cover PCM endianness/scaling, streaming edge silence,
interior pause preservation, sentence/long-input boundaries and voice migration.
Packaging regressions reject modified model data and unexpected AppleDouble
files. Existing IPC tests pass persistent requests, native traps, restart,
fragmented replies, timeout, cancellation and malformed output. The 25 existing
screen-policy, hotkey-matching, label and speech checks also pass.

The compile check is not an executed XCTest result. Actual microphone speech
plus physical Control–Option input was not retested: computer control cannot
hold a modifier-only shortcut, and the active input/output were AirPods, so
speaker-to-microphone loopback would not be a valid substitute. These bounded
tests do not establish indefinite stability or subjective voice quality.

## Reproduction

Install only through the identity-preserving local entry point:

```bash
./script/build_and_run.sh --verify
```

It prepares the pinned speech payload automatically. Optional build overrides:
`HEYMATE_PHONON_RUNTIME` for a prepared payload, `HEYMATE_OLLAMA_ARCHIVE` for the
verified archive, and `HEYMATE_PHONON_MODELS_SOURCE` for a content-addressed model
cache. Overrides are still hash-verified. Keep the documented official Node
override when Homebrew Node would otherwise be selected.

```bash
python3 scripts/phonon-runtime-tests.py
bash script/verify_voice_process.sh
python3 script/verify_phonon_lifetime.py
PROBE_ROUNDS=1000 PROBE_CORPUS=/absolute/path/replies.json \
  PROBE_PLAYBACK=1 PROBE_METRICS=/absolute/path/metrics.json \
  bash script/verify_phonon.sh
PROBE_LONG_ONLY=1 bash script/verify_phonon.sh
```

`PROBE_CORPUS` contains an array of reply strings and remains local. Default
probe text is public test text. The CLI uses disposable model/profile data,
never launches a second GUI and never changes the app's preferences.
`GET /speech/state` exposes selected engine/voice/speed and playback/turn state
on the existing protected local control interface; it reports configured engine,
not a claim that fallback was never used. Logs identify fallback separately.

Ignored artifacts: `output/phonon-rollout-2026-11-01/production-metrics.json`.
Private corpus text/audio is not included in this report or committed artifacts.
