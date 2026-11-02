#!/usr/bin/env python3
"""CPU-only Kokoro experiment. Does not install or alter HeyMate.

Run with Python from an isolated environment containing kokoro-onnx==0.6.1,
onnxruntime==1.31.1, numpy==2.5.4 and soundfile==0.14.0.
--corpus accepts already-sanitized sentences; private text/audio is not exported.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import resource
import subprocess
import threading
import time

import numpy as np
import onnxruntime as ort
import soundfile as sf
from kokoro_onnx import Kokoro
from voice_probe_texts import PUBLIC_SAMPLES


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    cache = Path.home() / ".cache/heymate-onnx-test"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=cache / "kokoro-v1.0.onnx")
    parser.add_argument("--voices", type=Path, default=cache / "voices-v1.0.bin")
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=400)
    parser.add_argument("--overlap", type=int, default=40)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    assert args.rounds > 0 and args.overlap >= 0 and args.threads > 0
    args.out.mkdir(parents=True, exist_ok=True)
    corpus = json.loads(args.corpus.read_text()) if args.corpus else PUBLIC_SAMPLES
    assert isinstance(corpus, list) and corpus and all(isinstance(t, str) and t.strip() for t in corpus)
    options = ort.SessionOptions()
    options.intra_op_num_threads = args.threads
    options.inter_op_num_threads = 1
    started = time.perf_counter()
    session = ort.InferenceSession(str(args.model), sess_options=options, providers=["CPUExecutionProvider"])
    assert session.get_providers() == ["CPUExecutionProvider"], session.get_providers()
    voice = Kokoro.from_session(session, str(args.voices))
    loaded_seconds = time.perf_counter() - started
    gate = threading.Lock()
    records = []

    def synthesize(text, phase, index, save=False):
        queued = time.perf_counter()
        # Match HeyMate's production gate: overlapping callers share one model,
        # without concurrent phonemizer or inference mutation.
        with gate:
            begin = time.perf_counter()
            samples, rate = voice.create(text, voice="af_heart", speed=1.0, lang="en-us")
            elapsed = time.perf_counter() - begin
        samples = np.asarray(samples)
        assert rate == 24000 and samples.ndim == 1 and samples.size > 0
        assert np.isfinite(samples).all(), "Non-finite audio"
        peak = float(np.max(np.abs(samples)))
        rms = float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))
        clipping = float(np.mean(np.abs(samples) >= 0.999))
        assert rms > 1e-5 and peak < 1.5 and clipping < 0.01, (peak, rms, clipping)
        seconds = samples.size / rate
        row = dict(phase=phase, index=index, characters=len(text), seconds=round(seconds, 4),
                   synth_seconds=round(elapsed, 4), queue_seconds=round(begin - queued, 4),
                   realtime_factor=round(elapsed / seconds, 4), peak=round(peak, 5),
                   rms=round(rms, 5), clipping_fraction=round(clipping, 7))
        if save:
            name = f"sample-{index + 1}.wav"
            sf.write(args.out / name, samples, rate, subtype="FLOAT")
            row.update(file=name, expected_text=text)
        return row

    print(f"Loaded in {loaded_seconds:.2f}s; provider={session.get_providers()}; CPU threads={args.threads}", flush=True)
    for index, text in enumerate(PUBLIC_SAMPLES):
        row = synthesize(text, "sample", index, save=True)
        records.append(row)
        print(f"Sample {index + 1}: {row['synth_seconds']}s synthesis / {row['seconds']}s audio", flush=True)
    # Persist public samples immediately, even if a later native failure occurs.
    (args.out / "sample-manifest.json").write_text(json.dumps(records, indent=2) + "\n")
    for index in range(args.rounds):
        records.append(synthesize(corpus[index % len(corpus)], "replay", index))
        if (index + 1) % 25 == 0:
            print(f"PASS replay {index + 1}/{args.rounds}", flush=True)
    with ThreadPoolExecutor(max_workers=4) as callers:
        futures = [callers.submit(synthesize, corpus[i % len(corpus)], "overlap", i) for i in range(args.overlap)]
        records.extend(future.result() for future in futures)
    print(f"PASS {args.overlap} requests from four overlapping callers (serialized model access)", flush=True)
    long_text = " ".join(PUBLIC_SAMPLES * 5)
    records.append(synthesize(long_text, "long_input", 0))
    print("PASS long input, model chunking and recovery", flush=True)
    records.append(synthesize("Voice check complete.", "recovery", 0))
    replay = [r for r in records if r["phase"] == "replay"]
    synth = np.array([r["synth_seconds"] for r in replay])
    ratios = np.array([r["realtime_factor"] for r in replay])
    report = dict(
        os=subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
        os_build=subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
        cpu=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        python=platform.python_version(), architecture=platform.machine(),
        versions={name: importlib.metadata.version(name) for name in ["kokoro-onnx", "onnxruntime", "numpy", "soundfile"]},
        providers=session.get_providers(), intra_op_threads=args.threads, voice="af_heart", speed=1.0,
        model_sha256=digest(args.model), voices_sha256=digest(args.voices),
        load_seconds=round(loaded_seconds, 3), elapsed_seconds=round(time.perf_counter() - started, 3),
        peak_rss_mib=round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**2, 1),
        replay_sentences=args.rounds, unique_corpus_sentences=len(corpus), overlapping_requests=args.overlap,
        total_requests=len(records), median_synth_seconds=round(float(np.median(synth)), 4),
        p95_synth_seconds=round(float(np.percentile(synth, 95)), 4),
        median_realtime_factor=round(float(np.median(ratios)), 4),
        generated_audio_seconds=round(sum(r["seconds"] for r in records), 3),
        invalid_audio_count=0, records=records,
    )
    (args.out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "records"}, indent=2), flush=True)


if __name__ == "__main__":
    main()
