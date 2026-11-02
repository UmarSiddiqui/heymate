# Kokoro ONNX CPU evaluation — November 1, 2026

Result: passed this bounded local test. ONNX is a viable replacement candidate.
HeyMate's installed speech backend was not changed.

## Machine and runtime

- Apple M5, arm64, macOS 27.0.1 (26A434).
- Python 3.12.11; kokoro-onnx 0.6.1; ONNX Runtime 1.31.1; NumPy 2.5.4; soundfile 0.14.0.
- The actual session provider list was exactly `CPUExecutionProvider`.
  Four intra-op threads, one inter-op thread; Core ML provider was not selected.
- Full Kokoro v1.0 ONNX weights, voice `af_heart`, speed 1.0, English-US.
  Weights and voice pack were downloaded from the [official model release](https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.1).
  Both SHA-256 values matched the release API's published digests:
  - Model: `beb0d1848dee9a49da392cc3df26958d46cfa35d321edf434f52949153f0df3a`
  - Voices: `bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d`

## Measured results

- **445 successful synthesis calls:** three public audio samples,
  400 replays drawn from 46 sanitized real-session sentences,
  40 requests from four overlapping callers, one long input,
  and one post-long-input recovery request.
- Overlapping callers shared a serialized model/phonemizer gate, matching
  HeyMate's current access pattern. Concurrent native inference was not tested.
- No process crash, empty output, non-finite samples, or rejected audio.
  Every output was 24 kHz mono. Per-clip clipping fraction stayed below 1%.
- 26.46 minutes of generated audio in
  288.99 seconds of wall time, including initialization.
- Warm replay median: **0.6446 seconds** per sentence;
  95th percentile: **1.0914 seconds**.
- Median real-time factor: 0.1834, approximately
  **5.45× faster than playback**.
- Model/voice initialization: 0.942 seconds.
  First public sample: 1.3605 seconds to synthesize 4.9293 seconds of audio.
- Peak process resident memory: **1077.2 MiB**, including long-input testing.

For the same first 40 sentences, the production Core ML helper's median was
0.2941 seconds, versus ONNX's
0.6284 seconds, about
2.14× slower synthesis.
This is an approximate end-to-end comparison: the engines use different
phonemizers and the Core ML route includes the production helper transport.

## Playback and intelligibility

`afplay` played the first saved ONNX sample and exited successfully.
The cached production Parakeet engine independently transcribed all three
samples from their saved WAV files, without microphone access. Sample one
and two matched word-for-word after case/punctuation normalization. Sample
three rendered “three thirty” as “3.30”; the other words matched. This is
an objective recognition check, not an independent human listening score.

Fresh public samples, machine-readable per-call measurements, hashes,
transcriptions and comparison data are in
`output/onnx-voice-check-2026-11-01/` at repository root. Private replay text
and generated private replay audio were not included in that output.

## Reproduce

From `heymate/`, reuse an isolated Python 3.12 environment, or create one:

```bash
uv venv --python 3.12 ~/.cache/heymate-onnx-test/venv
uv pip install --python ~/.cache/heymate-onnx-test/venv/bin/python \
  kokoro-onnx==0.6.1 onnxruntime==1.31.1 numpy==2.5.4 soundfile==0.14.0
```

Download `kokoro-v1.0.onnx` and `voices-v1.0.bin` from the release linked above
into `~/.cache/heymate-onnx-test/`, and verify their hashes. Then:

```bash
~/.cache/heymate-onnx-test/venv/bin/python script/kokoro_onnx_probe.py \
  --corpus ~/.cache/heymate-onnx-test/corpus.json \
  --out ../output/onnx-voice-check-2026-11-01 --rounds 400 --overlap 40
```

The local corpus contains an array of sentences exported through production
`SpeechText.sanitize` and Foundation sentence splitting. Omitting `--corpus`
uses public samples instead, which does not reproduce the private replay set.
For independent offline recognition of saved WAVs:

```bash
PROBE_TRANSCRIBE_DIRECTORY="$PWD/../output/onnx-voice-check-2026-11-01" \
  ./script/verify_kokoro.sh
```

## Limits and integration status

This is a standalone model/runtime test, not a shipped HeyMate backend.
It establishes bounded stability and usable local audio on this Mac; it does
not establish indefinite stability, broad language coverage, native packaging,
app-level cancellation, or performance across other Macs. The existing signed
app, preferences and TCC grants were left untouched. The existing app's speech
helper and Mac fallback remain in place. A production switch needs a bundled
runtime/phonemizer and verification through the normal signed install workflow.
