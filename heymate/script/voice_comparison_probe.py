#!/usr/bin/env python3
"""Matched local TTS benchmark. No GUI, microphone or HeyMate preference edits.

First audio means at least 50 ms of real PCM, not an HTTP/WAV header.
Private replay text/audio is never included in the output artifacts.
"""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import importlib.metadata
import json
from pathlib import Path
import platform
import subprocess
import threading
import time
import urllib.request

import numpy as np
import psutil
import soundfile as sf

from voice_probe_texts import PUBLIC_SAMPLES


class MemoryMonitor:
    def __init__(self, extra_pids):
        self.roots = [psutil.Process().pid] + extra_pids
        self.peak = 0
        self.done = threading.Event()
        self.thread = threading.Thread(target=self.poll, daemon=True)
        self.thread.start()

    def poll(self):
        while not self.done.is_set():
            found = {}
            for pid in self.roots:
                try:
                    root = psutil.Process(pid)
                    for proc in [root] + root.children(recursive=True):
                        found[proc.pid] = proc
                except psutil.Error:
                    pass
            rss = 0
            for proc in found.values():
                try:
                    rss += proc.memory_info().rss
                except psutil.Error:
                    pass
            self.peak = max(self.peak, rss)
            self.done.wait(0.02)

    def stop(self):
        self.done.set()
        self.thread.join(timeout=2)


class CoreML:
    def __init__(self, args):
        self.process = subprocess.Popen(
            ["/Applications/HeyMate.app/Contents/Helpers/HeyMateSpeechRunner"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.request(dict(operation="prepare", text="", voice="af_heart", speed=1.0))
        self.metadata = {"runtime": "installed signed HeyMateSpeechRunner", "voice": "af_heart"}

    def request(self, data):
        self.process.stdin.write(json.dumps(data).encode() + b"\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f"Speech helper exited: {self.process.poll()}")
        reply = json.loads(line)
        if reply.get("error"):
            raise RuntimeError(reply["error"])
        return reply

    def generate(self, text):
        reply = self.request(dict(operation="synthesize", text=text, voice="af_heart", speed=1.0))
        yield np.frombuffer(base64.b64decode(reply["samples"]), dtype="<f4"), reply["sampleRate"]

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)


class Onnx:
    def __init__(self, args):
        import onnxruntime as ort
        from kokoro_onnx import Kokoro

        root = Path.home() / ".cache/heymate-onnx-test"
        options = ort.SessionOptions()
        options.intra_op_num_threads = 4
        options.inter_op_num_threads = 1
        session = ort.InferenceSession(str(root / "kokoro-v1.0.onnx"), sess_options=options,
                                       providers=["CPUExecutionProvider"])
        assert session.get_providers() == ["CPUExecutionProvider"]
        self.model = Kokoro.from_session(session, str(root / "voices-v1.0.bin"))
        self.metadata = {"providers": session.get_providers(), "voice": "af_heart",
                         "onnxruntime": importlib.metadata.version("onnxruntime"),
                         "kokoro-onnx": importlib.metadata.version("kokoro-onnx")}

    def generate(self, text):
        yield self.model.create(text, voice="af_heart", speed=1.0, lang="en-us")

    def close(self):
        pass


class Mlx:
    def __init__(self, args):
        import mlx.core as mx
        from mlx.utils import tree_flatten
        from mlx_audio.tts.utils import load_model

        self.mx = mx
        self.model = load_model(str(args.mlx_model))
        weights = tree_flatten(self.model.parameters())
        dtypes = sorted(set(str(value.dtype) for _, value in weights))
        self.metadata = {"model": str(args.mlx_model), "voice": "af_heart", "weight_dtypes": dtypes,
                         "mlx": importlib.metadata.version("mlx"),
                         "mlx-audio": importlib.metadata.version("mlx-audio")}

    def generate(self, text):
        for result in self.model.generate(text=text, voice="af_heart", speed=1.0, lang_code="a"):
            self.mx.eval(result.audio)
            yield np.asarray(result.audio, dtype=np.float32).reshape(-1), result.sample_rate

    def close(self):
        self.metadata["mlx_peak_allocated_mib"] = self.mx.get_peak_memory() / 1024**2


class Ollama:
    def __init__(self, args):
        self.base = args.ollama_url
        self.model = args.ollama_model
        self.voice = args.ollama_voice
        with urllib.request.urlopen(self.base + "/api/version", timeout=5) as r:
            version = json.load(r)
        body = json.dumps({"model": self.model}).encode()
        with urllib.request.urlopen(urllib.request.Request(self.base + "/api/show", data=body,
                headers={"Content-Type": "application/json"}), timeout=30) as r:
            details = json.load(r)
        self.metadata = {"model": self.model, "voice": self.voice, "version": version,
                         "details": details.get("details"), "capabilities": details.get("capabilities"),
                         "available_voices": details.get("voices")}

    def generate(self, text):
        body = json.dumps({"model": self.model, "voice": self.voice, "input": text,
                           "response_format": "pcm"}).encode()
        request = urllib.request.Request(self.base + "/v1/audio/speech", data=body,
                                         headers={"Content-Type": "application/json"})
        pending = b""
        with urllib.request.urlopen(request, timeout=120) as response:
            assert response.headers.get_content_type() != "application/json", "Speech endpoint returned JSON instead of audio"
            while True:
                chunk = response.read1(4096)
                if not chunk:
                    break
                pending += chunk
                even = len(pending) // 2 * 2
                if even:
                    yield np.frombuffer(pending[:even], dtype="<i2").astype(np.float32) / 32768, 24000
                    pending = pending[even:]
        assert not pending, "Truncated PCM sample"

    def close(self):
        with urllib.request.urlopen(self.base + "/api/ps", timeout=5) as r:
            self.metadata["loaded_models"] = json.load(r)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", required=True, choices=["coreml", "onnx", "mlx", "ollama"])
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=400)
    parser.add_argument("--overlap", type=int, default=40)
    parser.add_argument("--extra-pid", type=int, action="append", default=[])
    parser.add_argument("--mlx-model", type=Path, default=Path.home() / ".cache/heymate-mlx-test/Kokoro-82M-bf16")
    parser.add_argument("--ollama-url", default="http://127.0.0.1:11436")
    parser.add_argument("--ollama-model", default="phonon")
    parser.add_argument("--ollama-voice", default="Zoey")
    args = parser.parse_args()
    corpus = json.loads(args.corpus.read_text())
    assert corpus and args.rounds > 0
    args.out.mkdir(parents=True, exist_ok=True)
    records = []
    gate = threading.Lock()
    monitor = MemoryMonitor(args.extra_pid)
    started = time.perf_counter()
    backend = None
    try:
        before = time.perf_counter()
        backend = {"coreml": CoreML, "onnx": Onnx, "mlx": Mlx, "ollama": Ollama}[args.backend](args)
        init_seconds = time.perf_counter() - before
        print(f"Initialized {args.backend} in {init_seconds:.3f}s", flush=True)

        def synthesize(text, phase, index, save=False):
            queued = time.perf_counter()
            with gate:
                begin = time.perf_counter()
                first_audio = None
                first_non_silent = None
                chunks = []
                count = 0
                rate = None
                for chunk, sample_rate in backend.generate(text):
                    chunk = np.asarray(chunk, dtype=np.float32).reshape(-1)
                    assert sample_rate == 24000 and np.isfinite(chunk).all(), "Invalid chunk"
                    rate = sample_rate
                    count += chunk.size
                    chunks.append(chunk.copy())
                    if first_non_silent is None and chunk.size and np.any(np.abs(chunk) > 0.01):
                        first_non_silent = time.perf_counter() - begin
                    if first_audio is None and count >= sample_rate // 20:
                        first_audio = time.perf_counter() - begin
                elapsed = time.perf_counter() - begin
            assert chunks and count > 0 and first_audio is not None, "No playable audio"
            audio = np.concatenate(chunks)
            peak = float(np.max(np.abs(audio)))
            rms = float(np.sqrt(np.mean(np.square(audio, dtype=np.float64))))
            clipped = float(np.mean(np.abs(audio) >= 0.999))
            assert rms > 1e-5 and peak < 1.5 and clipped < 0.01, (peak, rms, clipped)
            row = dict(phase=phase, index=index, characters=len(text), first_audio_seconds=first_audio,
                       first_non_silent_seconds=first_non_silent,
                       synth_seconds=elapsed, audio_seconds=count / rate, chunks=len(chunks),
                       realtime_factor=elapsed / (count / rate), queue_seconds=begin - queued,
                       peak=peak, rms=rms, clipping_fraction=clipped)
            if save:
                filename = f"sample-{index + 1}.wav"
                sf.write(args.out / filename, audio, rate, subtype="FLOAT")
                row.update(file=filename, expected_text=text)
            return row

        def remember(row):
            records.append(row)
            with (args.out / "records.jsonl").open("a") as stream:
                stream.write(json.dumps(row) + "\n")

        remember(synthesize(PUBLIC_SAMPLES[0], "cold", 0))
        for index, text in enumerate(PUBLIC_SAMPLES):
            remember(synthesize(text, "sample", index, save=True))
        (args.out / "sample-manifest.json").write_text(json.dumps([r for r in records if r["phase"] == "sample"], indent=2))
        print(f"Samples ready for {args.backend}", flush=True)
        for index in range(args.rounds):
            remember(synthesize(corpus[index % len(corpus)], "replay", index))
            if (index + 1) % 25 == 0:
                print(f"PASS {args.backend} replay {index + 1}/{args.rounds}", flush=True)
        with ThreadPoolExecutor(max_workers=4) as callers:
            futures = [callers.submit(synthesize, corpus[i % len(corpus)], "overlap", i) for i in range(args.overlap)]
            for future in futures:
                remember(future.result())
        remember(synthesize(" ".join(PUBLIC_SAMPLES * 3), "long_input", 0))
        remember(synthesize("Voice check complete.", "recovery", 0))
        backend.close()
        replay = [r for r in records if r["phase"] == "replay"]
        matched = replay[:len(corpus)]
        summary = dict(backend=args.backend, os=platform.mac_ver()[0], machine=platform.machine(),
                       python=platform.python_version(), metadata=backend.metadata,
                       initialization_seconds=init_seconds, elapsed_seconds=time.perf_counter() - started,
                       replay_sentences=args.rounds, unique_sentences=len(corpus), total_requests=len(records),
                       overlapping_requests=args.overlap, peak_process_tree_rss_mib=monitor.peak / 1024**2,
                       matched_sentences=len(matched),
                       matched_median_first_audio_seconds=float(np.median([r["first_audio_seconds"] for r in matched])),
                       matched_median_first_non_silent_seconds=float(np.median([r["first_non_silent_seconds"] for r in matched])),
                       matched_p95_first_audio_seconds=float(np.percentile([r["first_audio_seconds"] for r in matched], 95)),
                       matched_median_synth_seconds=float(np.median([r["synth_seconds"] for r in matched])),
                       matched_median_realtime_factor=float(np.median([r["realtime_factor"] for r in matched])),
                       generated_audio_seconds=sum(r["audio_seconds"] for r in records),
                       cold_first_audio_seconds=init_seconds + records[0]["first_audio_seconds"],
                       invalid_audio_count=0, records=records)
        (args.out / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps({k:v for k,v in summary.items() if k not in ["records", "metadata"]}, indent=2), flush=True)
        backend = None
    finally:
        if backend is not None:
            try:
                backend.close()
            except Exception:
                pass
        monitor.stop()


if __name__ == "__main__":
    main()
