#!/usr/bin/env python3
"""
Renders the welcome tour's audio into the asset catalog:

  * OnboardingVoice-<hash>.dataset: every scripted line in OnboardingTour.swift
    (`say("…")` / `speak("…")` literals without interpolation), spoken by the
    bundled Phonon model in the default on-device voice. The app finds a clip
    by the SHA-256 of the line's exact text (OnboardingVoiceClips.assetName),
    so a reworded line falls back to live speech until this runs again.
  * OnboardingMusic.dataset: a soft ambient pad that loops seamlessly under
    the tour. Synthesized clean-room with numpy; no samples.

Phonon must be serving on --port. With the installed app's runtime:

  OLLAMA_HOST=127.0.0.1:18777 OLLAMA_MODELS=<copy of Phonon/models> \\
    /Applications/HeyMate.app/Contents/Resources/PhononRuntime/ollama serve

Usage:
  python3 scripts/render-onboarding-audio.py --port 18777
  python3 scripts/render-onboarding-audio.py --music-only
"""

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOUR = os.path.join(ROOT, "HeyMate", "OnboardingTour.swift")
ASSETS = os.path.join(ROOT, "HeyMate", "Assets.xcassets")
VOICE_FOLDER = os.path.join(ASSETS, "OnboardingVoice")
VOICE = "Zoey"  # OnboardingVoiceClips.voice

LINE_PATTERN = re.compile(r'\b(?:say|speak)\("((?:[^"\\]|\\.)*)"\)')


def scripted_lines() -> list[str]:
    source = open(TOUR, encoding="utf-8").read()
    lines = []
    for match in LINE_PATTERN.finditer(source):
        text = match.group(1)
        if "\\(" in text:
            continue  # interpolated: only live speech can say it
        text = text.replace('\\"', '"').replace("\\\\", "\\")
        if text not in lines:
            lines.append(text)
    return lines


def asset_name(line: str) -> str:
    return "OnboardingVoice-" + hashlib.sha256(line.encode("utf-8")).hexdigest()[:10]


def write_dataset(folder: str, name: str, data_file: str) -> None:
    dataset = os.path.join(folder, name + ".dataset")
    shutil.rmtree(dataset, ignore_errors=True)
    os.makedirs(dataset)
    file_name = os.path.basename(data_file)
    shutil.copy(data_file, os.path.join(dataset, file_name))
    with open(os.path.join(dataset, "Contents.json"), "w") as handle:
        json.dump({"data": [{"filename": file_name, "idiom": "universal"}],
                   "info": {"author": "xcode", "version": 1}}, handle, indent=2)
        handle.write("\n")


def encode_aac(wav: str, m4a: str, bitrate: str) -> None:
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", bitrate, wav, m4a],
                   check=True, capture_output=True)


# MARK: - Voice

def synthesize(port: int, line: str) -> bytes:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/audio/speech",
        data=json.dumps({"model": "phonon", "voice": VOICE, "input": line,
                         "response_format": "pcm"}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def render_voice(port: int, work: str) -> None:
    lines = scripted_lines()
    os.makedirs(VOICE_FOLDER, exist_ok=True)
    with open(os.path.join(VOICE_FOLDER, "Contents.json"), "w") as handle:
        json.dump({"info": {"author": "xcode", "version": 1}}, handle, indent=2)
        handle.write("\n")
    wanted = {asset_name(line) for line in lines}
    for entry in os.listdir(VOICE_FOLDER):
        if entry.endswith(".dataset") and entry[:-len(".dataset")] not in wanted:
            shutil.rmtree(os.path.join(VOICE_FOLDER, entry))
    for line in lines:
        name = asset_name(line)
        pcm = os.path.join(work, name + ".pcm")
        wav = os.path.join(work, name + ".wav")
        m4a = os.path.join(work, name + ".m4a")
        with open(pcm, "wb") as handle:
            handle.write(synthesize(port, line))
        # Trim the model's lead-in and tail silence, then a short fade so
        # nothing clicks.
        subprocess.run([
            "ffmpeg", "-y", "-loglevel", "error", "-f", "s16le", "-ar", "24000", "-ac", "1", "-i", pcm,
            "-af", "silenceremove=start_periods=1:start_threshold=-50dB,"
                   "areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse,"
                   "afade=t=in:d=0.01",
            wav,
        ], check=True)
        encode_aac(wav, m4a, "64000")
        write_dataset(VOICE_FOLDER, name, m4a)
        print(f"{name}  {line}")


# MARK: - Music

RATE = 44_100
BAR = 12.0          # seconds per chord
CHORDS = [          # MIDI notes, low to high: a slow, warm D major walk
    [50, 57, 62, 66, 69, 76],   # Dmaj9-ish (D A D F# A E)
    [47, 54, 62, 66, 69, 73],   # Bm11
    [43, 50, 59, 62, 66, 69],   # Gmaj9
    [45, 52, 61, 64, 69, 71],   # A6sus
]
BELLS = [74, 76, 78, 81, 83, 86]  # D major pentatonic, high and sparse


def hz(note: float) -> float:
    return 440.0 * 2 ** ((note - 69) / 12)


def pad_voice(t: np.ndarray, frequency: float, seed: int) -> tuple[np.ndarray, np.ndarray]:
    """Three slightly detuned sines per note, spread left and right."""
    rng = np.random.default_rng(seed)
    left = np.zeros_like(t)
    right = np.zeros_like(t)
    for detune, pan in ((-0.6, 0.2), (0.0, 0.5), (0.7, 0.8)):
        # Detune in Hz is a whole number of cycles per loop so it wraps.
        loop = t[-1] + 1 / RATE
        f = round((frequency + detune) * loop) / loop
        phase = rng.uniform(0, 2 * math.pi)
        wave = np.sin(2 * math.pi * f * t + phase) + 0.12 * np.sin(4 * math.pi * f * t + phase)
        left += wave * math.cos(pan * math.pi / 2)
        right += wave * math.sin(pan * math.pi / 2)
    return left, right


def render_music(work: str) -> None:
    loop_seconds = BAR * len(CHORDS)
    count = int(loop_seconds * RATE)
    t = np.arange(count) / RATE
    left = np.zeros(count)
    right = np.zeros(count)

    # Each chord swells in and out on a raised-cosine envelope that overlaps
    # its neighbours by half a bar, and the last wraps into the first.
    for index, chord in enumerate(CHORDS):
        center = (index + 0.5) * BAR
        distance = (t - center + loop_seconds / 2) % loop_seconds - loop_seconds / 2
        envelope = np.clip(np.cos(np.pi * distance / (BAR * 2.0)), 0, 1) ** 2
        for voice, note in enumerate(chord):
            l, r = pad_voice(t, hz(note), seed=index * 10 + voice)
            weight = 1.0 if voice < 2 else 0.55  # roots warm, upper notes soft
            left += l * envelope * weight
            right += r * envelope * weight

    # Slow breathing so the bed never sits perfectly still.
    breath = 0.85 + 0.15 * np.sin(2 * math.pi * t / (loop_seconds / 3))
    left *= breath
    right *= breath

    # A few soft glassy bells, wrapped around the loop with a gentle echo.
    rng = np.random.default_rng(7)
    bell_left = np.zeros(count)
    bell_right = np.zeros(count)
    bell_length = int(4.0 * RATE)
    bt = np.arange(bell_length) / RATE
    for start in np.arange(1.5, loop_seconds, 3.2) + rng.uniform(-0.6, 0.6, int(loop_seconds / 3.2)):
        note = rng.choice(BELLS)
        tone = (np.sin(2 * math.pi * hz(note) * bt) + 0.25 * np.sin(2 * math.pi * hz(note) * 2.01 * bt))
        tone *= np.exp(-bt * 1.4) * (1 - np.exp(-bt * 80)) * rng.uniform(0.5, 1.0)
        pan = rng.uniform(0.25, 0.75)
        for delay, gain in ((0.0, 1.0), (0.42, 0.35), (0.84, 0.12)):
            index = (int((start + delay) * RATE) + np.arange(bell_length)) % count
            np.add.at(bell_left, index, tone * gain * math.cos(pan * math.pi / 2))
            np.add.at(bell_right, index, tone * gain * math.sin(pan * math.pi / 2))

    # A one-pole low-pass keeps the bells soft. Run it twice over the loop so
    # its state at the seam matches and the wrap stays click-free.
    def soften(signal: np.ndarray, cutoff: float) -> np.ndarray:
        alpha = 1 - math.exp(-2 * math.pi * cutoff / RATE)
        out = np.empty_like(signal)
        state = 0.0
        for _ in range(2):
            for i in range(len(signal)):
                state += alpha * (signal[i] - state)
                out[i] = state
        return out

    left += soften(bell_left, 3_200) * 0.18
    right += soften(bell_right, 3_200) * 0.18

    stereo = np.stack([left, right], axis=1)
    stereo *= 0.35 / np.max(np.abs(stereo))  # peaks well below full scale

    wav = os.path.join(work, "onboarding-music.wav")
    m4a = os.path.join(work, "onboarding-music.m4a")
    import wave
    with wave.open(wav, "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes((stereo * 32767).astype("<i2").tobytes())
    encode_aac(wav, m4a, "128000")
    write_dataset(ASSETS, "OnboardingMusic", m4a)
    print(f"OnboardingMusic  {loop_seconds:.0f}s loop")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18777)
    parser.add_argument("--music-only", action="store_true")
    parser.add_argument("--voice-only", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as work:
        if not args.voice_only:
            render_music(work)
        if not args.music_only:
            render_voice(args.port, work)


if __name__ == "__main__":
    sys.exit(main())
