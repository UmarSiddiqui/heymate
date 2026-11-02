# Local speech comparison — November 1, 2026

**Phonon through Ollama is the strongest integration candidate from this test.**
It delivered speech data sooner and generated complete replies faster than the
current Core ML helper, ONNX CPU or Kokoro MLX. No HeyMate backend, voice
preference, signing identity or privacy permission was changed.

## Matched warm results

Apple M5, 24 GiB unified memory, macOS 27.0.1 (26A434). All four backends used
the same 46 sanitized real-session sentences. Values below use that first
matched pass; the two new candidates continued through longer stress runs.

| Backend | Median speech data ready | Median complete synthesis | Median faster than playback | Peak process-tree RSS |
| --- | ---: | ---: | ---: | ---: |
| Current Kokoro / Core ML helper | 247.9 ms | 247.9 ms | 15.7× | 1613 MiB |
| Kokoro / ONNX CPU | 659.9 ms | 659.9 ms | 5.3× | 962 MiB |
| Kokoro / MLX | 236.5 ms | 242.5 ms | 17.2× | 464 MiB |
| Phonon / Ollama MLX | 4.8 ms | 66.8 ms | 54.4× | 228 MiB |

“Speech data ready” means non-silent PCM has reached the benchmark client.
Streaming requests also had to deliver at least 50 ms of real PCM to count as
playable output. These are **not measured speaker-output latencies**: device
buffering, app scheduling and trimming are outside these timings. Core ML,
ONNX and MLX returned one complete clip for every matched sentence. Phonon
streamed PCM frames. Its median first-PCM availability was
4.6 ms, and non-silent data
availability was 4.8 ms.

### Memory qualification

RSS includes the Python benchmark client and its model process tree. Phonon
also includes the separately launched, dedicated Ollama server and its runner.
It does not capture every kind of GPU/ANE allocation, and summing GPU allocations
with RSS can double-count unified pages. Do not interpret MLX's RSS as its total
memory cost:

- Kokoro MLX separately reported **2842 MiB peak MLX allocations**.
- Ollama reported **170 MiB GPU model allocation** for Phonon.
- Peaks include a direct long-paragraph stress call. HeyMate normally splits
  spoken replies into sentences, so these are stress bounds rather than
  steady-state app RAM estimates. Core ML's shared ANE/service memory is not
  comprehensively attributed by process RSS.

## Startup

With downloaded model assets already present, initialization through first
playable PCM took:

- Current Core ML helper: 1.00 s.
- ONNX CPU: 2.33 s.
- Kokoro MLX, first process: 36.48 s;
  a fresh process after that first run took 7.63 s.
- Phonon/Ollama, first model request: 3.12 s.
  First non-silent PCM during that cold request arrived about
  3.73 s after setup began.

These include different frontend/runtime initialization costs. MLX's first use
included its English frontend and first GPU execution; the experiment does not
separate those costs or guarantee a particular later-startup time.

## Stability and correctness checks

- **Kokoro MLX: 446 successful calls.** One cold call, three public samples,
  400 replays from 46 unique real-session sentences, 40 requests from four
  overlapping callers, a long input and a recovery call. Wall time:
  142.73 s.
- **Phonon/Ollama: 446 successful calls** with the same phases. Wall time:
  33.78 s.
- **Current Core ML and ONNX: 52 calls each** in this matched rerun. Earlier
  bounded tests covered another 800 Core ML and 445 ONNX calls; see the prior
  repair and ONNX reports.
- Overlapping callers shared a serialization gate. This tests the access
  pattern used by HeyMate; it does not claim concurrent native inference.
- No crashes, empty clips, non-finite audio or rejected sample rates. Every
  output was 24 kHz mono; per-clip clipping fraction remained below 1%.
- MLX emitted some English phonemizer word-count warnings during private
  replay. No numerical-audio failure resulted. The entire private corpus was
  not independently transcribed, so those warnings are not proof of either
  correct or dropped words.

### Independent Phonon speed audit

Three additional never-repeated sentences were generated through independent
`ollama run phonon --voice Zoey` CLI calls. They produced 3.36–4.48 seconds of
WAV audio in **0.0785–0.1105 seconds of complete CLI wall time**. This supports
the fast result without relying on repeated-text requests or just the streaming
HTTP timing code. Their saved speech was also independently transcribed.

### Playback and intelligibility

The production cached Parakeet engine transcribed **15 saved samples** locally:
three identical public phrases from each backend, plus the three fresh Phonon
sentences. All preserved the intended words. “Three thirty” was formatted as
“3.30”; “harbour” appeared as the equivalent US spelling “harbor”. This checks
basic intelligibility, not human-rated naturalness, emotion or all accents.
The comparison WAV preserves each engine's original audio and loudness, with
0.7-second silence between excerpts. No retired media was used.

The voices differ: Kokoro variants use `af_heart`; Phonon uses `Zoey`.
Listen before deciding which personality fits the app. Edge-silence measurements
are saved separately; raw clip silence is not included in the speech-data
availability metric. Current HeyMate already trims Kokoro's leading silence.

## Exact runtimes and assets

- **Current:** installed, signed
  `/Applications/HeyMate.app/Contents/Helpers/HeyMateSpeechRunner`, retaining
  its production Core ML Kokoro engine. It was tested as a CLI child, not a
  second HeyMate GUI.
- **ONNX:** kokoro-onnx 0.6.1, ONNX Runtime 1.31.1,
  `CPUExecutionProvider` only, four intra-op threads and one inter-op thread.
  Same verified full Kokoro model and voice pack as the prior ONNX evaluation.
- **MLX:** mlx-audio 0.6.2, MLX/MLX-Metal 0.32.4, Misaki 0.9.4,
  spaCy 3.8.18 and en_core_web_sm 3.8.0. The model ran with offline Hub flags.
  [HF checkpoint](https://huggingface.co/mlx-community/Kokoro-82M-bf16)
  pinned at `a71e4d38b236d968966a2002c4c895dbd12b1c3c`.
  Despite the repository's “bf16” name, its 548 loaded tensors were **float32**.
  The downloaded safetensors SHA-256 matched
  `4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8`.
  No quantized or manually cast MLX variant was tested.
- **Phonon:** official Ollama 0.40.13, `phonon:latest`, voice Zoey,
  MLX runner, bfloat16; reported total checkpoint size 43.49M parameters
  including supporting components. Ollama model digest
  `58f58601e4e83c6d5c06f87ca91071e0a9acfd6d169515fd8eb3da27965b990e`.
  The published model license contains Apache terms. The explicit
  `phonon:31m-en` tag exposed only its default voice in this Ollama version;
  the normal `phonon` alias exposed the full voice catalog, including Zoey.
  See [Ollama's speech documentation](https://github.com/ollama/ollama/blob/main/docs/capabilities/speech.mdx).

The official Ollama CLI archive was downloaded and verified against its release
SHA-256, then run from the experiment cache. Its server listened only on
`127.0.0.1:11436`, with cloud disabled and a separate model cache. No autostart
service was installed. All speech inference used local processes/localhost;
no cloud TTS service was called.

## Artifacts and repeatability

At repository root, `output/voice-comparison-2026-11-01/` contains:

- `summary.json` and per-backend `results.json` / `records.jsonl`;
- fresh WAV samples and `sample-manifest.json` for each backend;
- `transcriptions.json`, `intelligibility.json`, and `edge-silence.json`;
- `voice-comparison.wav` and its timestamp timeline;
- Phonon's `fresh-*.wav` and independent CLI measurements.

Private replay text and audio are not included in these output artifacts.
The local private corpus remains in the experiment cache.
`script/voice_comparison_probe.py` runs all four engines with the same protocol.
Use `--rounds 46 --overlap 0` for the matched baseline and
`--rounds 400 --overlap 40` for the bounded stress run. Use each engine's
isolated Python environment; the MLX and ONNX environments are separate.

## Decision and limits

**Phonon deserves the next HeyMate integration trial.** It was substantially
faster in this test, with compact observed resource usage and correct sample
speech. Kokoro MLX mostly tied current warm speed while adding startup and
GPU-memory costs in this tested configuration. ONNX remained slower.

This comparison preceded the backend switch. The subsequent local integration,
signed install, 2,000-segment replay, playback and recovery evidence are recorded
in [the Phonon rollout report](phonon-rollout-2026-11-01.md). Physical
Control–Option microphone testing remains a separate gap. These bounded runs
do not establish indefinite stability, a global best model, or subjective
voice-quality superiority.
