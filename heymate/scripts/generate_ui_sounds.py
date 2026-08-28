#!/usr/bin/env python3
"""
Generates HeyMate's subtle UI sounds as 16-bit 48kHz mono WAVs and installs
them into the asset catalog as data sets (HeyClicky ships a similar set of
interaction sounds; these are synthesized clean-room — soft sine blips with
exponential decay, no samples).

Sounds:
  listen-start   rising soft blip when push-to-talk opens the mic (talk mode)
  response-ready gentle two-note chime when TTS audio starts playing

Usage: python3 scripts/generate_ui_sounds.py
"""

import math
import os
import struct
import wave

SAMPLE_RATE = 48_000
PEAK_AMPLITUDE = 0.35  # deliberately quiet — feedback, not notification


def write_wav(path: str, samples: list[float]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "w") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(SAMPLE_RATE)
        frames = b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples
        )
        wav_file.writeframes(frames)
    print(f"wrote {path} ({len(samples) / SAMPLE_RATE * 1000:.0f} ms)")


def fade_envelope(sample_index: int, total_samples: int, attack_seconds: float) -> float:
    """Attack ramp + exponential-ish linear-out decay, ends at true zero to avoid clicks."""
    attack_samples = int(attack_seconds * SAMPLE_RATE)
    if sample_index < attack_samples:
        return sample_index / attack_samples
    remaining = (total_samples - sample_index) / total_samples
    return remaining * remaining


def sine_glide(duration: float, start_freq: float, end_freq: float) -> list[float]:
    """Rising/falling sine with continuous phase so the glide never clicks."""
    total_samples = int(duration * SAMPLE_RATE)
    samples: list[float] = []
    phase = 0.0
    for i in range(total_samples):
        progress = i / total_samples
        # Exponential glide sounds more natural than linear.
        frequency = start_freq * (end_freq / start_freq) ** progress
        phase += 2 * math.pi * frequency / SAMPLE_RATE
        envelope = fade_envelope(i, total_samples, attack_seconds=0.01)
        samples.append(math.sin(phase) * envelope * PEAK_AMPLITUDE)
    return samples


def two_note_chime(first_freq: float, second_freq: float,
                   note_duration: float, overlap: float) -> list[float]:
    """Two bell-ish notes (fundamental + quiet octave) overlapping slightly."""
    note_one = synth_note(first_freq, note_duration)
    note_two = synth_note(second_freq, note_duration)

    overlap_samples = int(overlap * SAMPLE_RATE)
    total_samples = len(note_one) + len(note_two) - overlap_samples
    mixed = [0.0] * total_samples
    for i, s in enumerate(note_one):
        mixed[i] += s
    offset = len(note_one) - overlap_samples
    for i, s in enumerate(note_two):
        mixed[offset + i] += s
    # Renormalize after overlap summing.
    peak = max(abs(s) for s in mixed) or 1.0
    scale = PEAK_AMPLITUDE / peak
    return [s * scale for s in mixed]


def synth_note(frequency: float, duration: float) -> list[float]:
    """Bell-flavored note: fundamental + 0.25 octave partial + 0.125 twelfth."""
    total_samples = int(duration * SAMPLE_RATE)
    samples: list[float] = []
    for i in range(total_samples):
        t = i / SAMPLE_RATE
        envelope = fade_envelope(i, total_samples, attack_seconds=0.008)
        value = (
            math.sin(2 * math.pi * frequency * t)
            + 0.25 * math.sin(2 * math.pi * frequency * 2 * t)
            + 0.125 * math.sin(2 * math.pi * frequency * 3 * t)
        )
        samples.append(value * envelope / 1.375)
    return samples


def main() -> None:
    assets_root = os.path.join(
        os.path.dirname(__file__), "..", "leanring-buddy", "Assets.xcassets"
    )

    # Push-to-talk opens: quick upward "ready" blip.
    write_wav(
        os.path.join(assets_root, "ListenStart.dataset", "listen-start.wav"),
        sine_glide(duration=0.14, start_freq=523.25, end_freq=783.99),
    )

    # Response begins speaking: warm A5 → E6 chime.
    write_wav(
        os.path.join(assets_root, "ResponseReady.dataset", "response-ready.wav"),
        two_note_chime(first_freq=880.0, second_freq=1318.51,
                       note_duration=0.22, overlap=0.06),
    )


if __name__ == "__main__":
    main()
