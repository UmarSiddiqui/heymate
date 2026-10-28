#!/usr/bin/env python3
"""
Generates HeyMate's UI sounds as 24-bit 48kHz stereo WAVs and installs them
into the asset catalog as data sets (Apple Lossless .m4a). Everything is synthesized clean-room —
no samples from any other app.

Palette: warm, low "felt mallet" tones plus a few other voices so the set
has range — pitch glides, soft low thumps, a vibrato hum, sparkles, slap
echoes and a rumble — mostly in D major, with a short room tail so each
sound settles instead of stopping dead. Each sound gets its own gesture;
the comments in build_sounds() say what each one is for.

Usage:
  python3 scripts/generate_ui_sounds.py            # install into Assets.xcassets
  python3 scripts/generate_ui_sounds.py --out DIR  # write plain WAVs to DIR to audition
"""

import json
import math
import os
import random
import struct
import subprocess
import sys
import wave

SAMPLE_RATE = 48_000
PEAK_AMPLITUDE = 0.4  # feedback, not notification

# Global character knobs. Lower pitch + sub + big soft room = "premium".
PITCH = 0.5          # whole palette one octave down
BRIGHTNESS = 0.55    # scales the knocky upper partials on every mallet
SUB_LEVEL = 0.6      # sine one octave under each mallet for weight
BASS_BOOST = 1.4     # low shelf under ~160 Hz on the dry signal
STEREO_SPREAD = 23   # samples between left/right reverb tunings (wide, cinematic)
WIDTH = 0.6          # side gain on the reverb; wide but still sums safely to mono
ROOM_SIZE = 1.15     # stretches the reverb delays
ROOM_FEEDBACK = 0.84 # longer decay
ROOM_WET = 0.45      # default wet mix
ROOM_TAIL = 0.9      # extra seconds of tail on every sound

# Equal-tempered note frequencies used below.
# Written at concert pitch, then shifted by PITCH.
D3, A3, B3 = (f * PITCH for f in (146.83, 220.0, 246.94))
C4, D4, E4, F_SHARP4, G4, A4, B4 = (f * PITCH for f in (261.63, 293.66, 329.63, 369.99, 392.0, 440.0, 493.88))
C5, D5, E5, F_SHARP5, G5, A5 = (f * PITCH for f in (523.25, 587.33, 659.25, 739.99, 783.99, 880.0))
C6, D6 = (f * PITCH for f in (1046.5, 1174.66))


def write_wav(path: str, samples: list[tuple[float, float]]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "w") as wav_file:
        wav_file.setnchannels(2)
        wav_file.setsampwidth(3)  # 24-bit: quiet reverb tails stay smooth
        wav_file.setframerate(SAMPLE_RATE)
        rng = random.Random(1)
        full_scale = 8_388_607
        frames = bytearray()
        for frame in samples:
            for s in frame:
                dither = (rng.random() - rng.random()) / full_scale  # TPDF, 1 LSB
                value = round(max(-1.0, min(1.0, s + dither)) * full_scale)
                frames += struct.pack("<i", value)[:3]
        wav_file.writeframes(frames)
    print(f"wrote {path} ({len(samples) / SAMPLE_RATE * 1000:.0f} ms)")


# MARK: - Voices

def mallet(frequency: float, duration: float, brightness: float = 1.0,
           bend: float = 1.0) -> list[float]:
    """Felt-mallet tone. `bend` glides the pitch to frequency*bend over the note."""
    total = int(duration * SAMPLE_RATE)
    # (ratio, level, decay seconds) — marimba-ish inharmonic partials.
    brightness *= BRIGHTNESS
    partials = [(0.5, SUB_LEVEL, duration * 0.6),
                (1.0, 1.0, duration * 0.6),
                (2.0, 0.12, duration * 0.25),
                (3.93, 0.22 * brightness, 0.05),
                (9.2, 0.07 * brightness, 0.015)]
    phases = [0.0] * len(partials)
    out: list[float] = []
    attack = int(0.008 * SAMPLE_RATE)  # rounder hit
    for i in range(total):
        t = i / SAMPLE_RATE
        progress = i / total
        f = frequency * (bend ** min(1.0, progress * 3))
        value = 0.0
        for k, (ratio, level, decay) in enumerate(partials):
            if f * ratio > 4_500:  # no fizzy top end
                continue
            phases[k] += 2 * math.pi * f * ratio / SAMPLE_RATE
            value += level * math.exp(-t / decay) * math.sin(phases[k])
        a = i / attack if i < attack else 1.0
        tail = min(1.0, (total - i) / (0.02 * SAMPLE_RATE))  # land on zero
        out.append(value * a * tail)
    return out


def swell(start_freq: float, end_freq: float, duration: float,
          air: float = 0.15, rise: float = 0.35) -> list[float]:
    """Soft pad that fades in and out with a pitch glide and a breath of noise."""
    total = int(duration * SAMPLE_RATE)
    rng = random.Random(7)
    phase = 0.0
    lowpassed = darker = 0.0
    out: list[float] = []
    for i in range(total):
        progress = i / total
        f = start_freq * (end_freq / start_freq) ** progress
        phase += 2 * math.pi * f / SAMPLE_RATE
        env = (progress / rise) if progress < rise else ((1 - progress) / (1 - rise)) ** 2
        lowpassed += 0.025 * (rng.uniform(-1, 1) - lowpassed)
        darker += 0.025 * (lowpassed - darker)  # two poles: breath, not hiss
        tone = math.sin(phase) + 0.3 * math.sin(2 * phase)
        out.append((tone + air * 35 * darker) * env)
    return out


def glide(start_freq: float, end_freq: float, duration: float,
          curve: float = 1.0, body: float = 0.35) -> list[float]:
    """Plucked tone whose pitch sweeps; curve > 1 holds the start pitch longer."""
    total = int(duration * SAMPLE_RATE)
    phase = 0.0
    out: list[float] = []
    for i in range(total):
        progress = i / total
        f = start_freq * (end_freq / start_freq) ** (progress ** curve)
        phase += 2 * math.pi * f / SAMPLE_RATE
        env = min(1.0, i / (0.006 * SAMPLE_RATE)) * math.exp(-progress * 4.5)
        env *= min(1.0, (total - i) / (0.02 * SAMPLE_RATE))
        out.append((math.sin(phase) + body * math.sin(2 * phase) * math.exp(-progress * 8)) * env)
    return out


def thump(frequency: float, duration: float, drop: float = 0.6) -> list[float]:
    """Soft low kick: sine that drops in pitch, for weight under other layers."""
    frequency = max(frequency, 48.0)  # below this laptop speakers play nothing
    total = int(duration * SAMPLE_RATE)
    phase = 0.0
    out: list[float] = []
    for i in range(total):
        t = i / SAMPLE_RATE
        f = frequency * (drop + (1 - drop) * math.exp(-t / 0.05))
        phase += 2 * math.pi * f / SAMPLE_RATE
        env = min(1.0, i / (0.003 * SAMPLE_RATE)) * math.exp(-t / (duration * 0.35))
        env *= min(1.0, (total - i) / (0.02 * SAMPLE_RATE))
        out.append(math.sin(phase) * env)
    return out


def hum(frequency: float, duration: float, vibrato: float = 0.012,
        rise: float = 0.15) -> list[float]:
    """Held, voice-like tone with gentle vibrato — a soft "mm?"."""
    total = int(duration * SAMPLE_RATE)
    phase = 0.0
    out: list[float] = []
    for i in range(total):
        t = i / SAMPLE_RATE
        progress = i / total
        f = frequency * (1 + vibrato * math.sin(2 * math.pi * 5.5 * t) * min(1.0, t / 0.15))
        phase += 2 * math.pi * f / SAMPLE_RATE
        env = (progress / rise) if progress < rise else ((1 - progress) / (1 - rise)) ** 1.5
        tone = math.sin(phase) + 0.45 * math.sin(2 * phase) + 0.2 * math.sin(3 * phase)
        out.append(tone * env)
    return out


def sparkle(center: float, duration: float, count: int = 7, seed: int = 3) -> list[float]:
    """A spray of tiny high glints for reveals."""
    rng = random.Random(seed)
    notes = []
    for k in range(count):
        start = duration * 0.6 * k / count + rng.uniform(0, 0.02)
        freq = center * 2 ** (rng.choice([0, 3, 5, 7, 10, 12]) / 12)
        notes.append((start, [v * 0.35 for v in mallet(freq, 0.18, brightness=1.6)]))
    return place(notes)


def echo(samples: list[float], delay: float = 0.11, feedback: float = 0.4,
         repeats: int = 4) -> list[float]:
    """Discrete slap echoes, each quieter."""
    return place([(delay * k, [v * feedback ** k for v in samples]) for k in range(repeats + 1)])


def rumble(duration: float, frequency: float = 55.0) -> list[float]:
    """Low building rumble (filtered noise + sub) that grows then settles."""
    total = int(duration * SAMPLE_RATE)
    rng = random.Random(11)
    a = b = 0.0
    phase = 0.0
    out: list[float] = []
    for i in range(total):
        progress = i / total
        a += 0.01 * (rng.uniform(-1, 1) - a)
        b += 0.01 * (a - b)
        phase += 2 * math.pi * frequency * (1 + 0.04 * math.sin(2 * math.pi * 3 * i / SAMPLE_RATE)) / SAMPLE_RATE
        env = min(1.0, progress / 0.6) ** 2 * min(1.0, (1 - progress) / 0.25)
        out.append((0.6 * math.sin(phase) + 25 * b) * env)
    return out


# MARK: - Mixing

def place(notes: list[tuple[float, list[float]]]) -> list[float]:
    """Mix rendered notes at start times (seconds)."""
    length = max(int(start * SAMPLE_RATE) + len(n) for start, n in notes)
    mixed = [0.0] * length
    for start, note in notes:
        offset = int(start * SAMPLE_RATE)
        for i, v in enumerate(note):
            mixed[offset + i] += v
    return mixed


def room(samples: list[float], tail: float = 0.35,
         wet: float = ROOM_WET) -> list[tuple[float, float]]:
    """Wide stereo hall. Dry sound sits dead center with a low-shelf boost;
    the tail comes from two Freeverb-style networks (8 damped combs into 4
    allpasses) whose tunings differ by STEREO_SPREAD samples, so left and
    right decorrelate and the room wraps around you. Short pre-delay,
    soft high-cut on the tail, long fade."""
    wet = max(wet, ROOM_WET)
    padded = samples + [0.0] * int((tail + ROOM_TAIL) * SAMPLE_RATE)
    n = len(padded)
    scale = SAMPLE_RATE / 44_100 * ROOM_SIZE

    def comb(length: int, feedback: float) -> list[float]:
        d = int(length * scale)
        out = [0.0] * n
        store = 0.0
        for i in range(n):
            delayed = out[i - d] if i >= d else 0.0
            store = 0.6 * delayed + 0.4 * store  # damping: highs die first
            out[i] = padded[i] + feedback * store
        return out

    def network(spread: int) -> list[float]:
        tunings = (1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617)
        combs = [comb(length + spread, ROOM_FEEDBACK - 0.004 * k)
                 for k, length in enumerate(tunings)]
        sig = [sum(c[i] for c in combs) / len(combs) for i in range(n)]
        for length in (556, 441, 341, 225):
            d = int((length + spread) * scale)
            buf = [0.0] * n
            y = [0.0] * n
            for i in range(n):
                delayed = buf[i - d] if i >= d else 0.0
                y[i] = delayed - sig[i]
                buf[i] = sig[i] + 0.5 * delayed
            sig = y
        smoothed = 0.0
        for i in range(n):  # one-pole high-cut ~5 kHz on the tail
            smoothed += 0.5 * (sig[i] - smoothed)
            sig[i] = smoothed
        return sig

    left, right = network(0), network(STEREO_SPREAD)

    # Low shelf on the dry signal: add back a lowpassed copy (~160 Hz).
    low = 0.0
    lp_coeff = 1 - math.exp(-2 * math.pi * 160 / SAMPLE_RATE)
    dry = []
    for v in padded:
        low += lp_coeff * (v - low)
        dry.append(v + BASS_BOOST * low)

    pre_delay = int(0.022 * SAMPLE_RATE)
    out: list[tuple[float, float]] = []
    for i in range(n):
        l = left[i - pre_delay] if i >= pre_delay else 0.0
        r = right[i - pre_delay] if i >= pre_delay else 0.0
        mid, side = (l + r) / 2, (l - r) / 2 * WIDTH
        out.append((dry[i] + wet * (mid + side), dry[i] + wet * (mid - side)))
    fade = int(0.35 * SAMPLE_RATE)
    for i in range(fade):
        g = (i / fade) ** 2
        l, r = out[n - 1 - i]
        out[n - 1 - i] = (l * g, r * g)
    return out


def finish(samples: list[tuple[float, float]], level: float = 1.0) -> list[tuple[float, float]]:
    peak = max(max(abs(l), abs(r)) for l, r in samples) or 1.0
    scale = PEAK_AMPLITUDE * level / peak
    return [(l * scale, r * scale) for l, r in samples]


# MARK: - Sounds

def build_sounds() -> dict[str, tuple[str, list[float]]]:
    """Asset name -> (file name, samples). Each sound has its own gesture so the
    set has range: plucks, glides, thumps, hums, sparkles, echoes, a rumble."""
    return {
        # Talk mode -----------------------------------------------------------
        "ListenStart": ("listen-start.wav", finish(room(place([
            (0.0, mallet(G4, 0.18, brightness=0.6)),
            (0.06, mallet(D5, 0.28, brightness=0.8)),
        ]), tail=0.25), level=0.8)),

        "ResponseReady": ("response-ready.wav", finish(room(place([
            (0.0, mallet(A4, 0.45)),
            (0.09, mallet(E5, 0.55)),
        ])))),

        # Chat ----------------------------------------------------------------
        # Low pluck that lifts: something opening up.
        "PanelOpen": ("panel-open.wav", finish(room(place([
            (0.0, thump(D3 * 2, 0.25, drop=0.8)),
            (0.0, glide(D3, A3, 0.3, curve=0.6, body=0.6)),
        ]), tail=0.25), level=0.8)),

        # Single soft tap that echoes away.
        "PanelClose": ("panel-close.wav", finish(room(echo(
            mallet(B4, 0.2, brightness=0.7), delay=0.13, feedback=0.35, repeats=3,
        ), tail=0.2), level=0.7)),

        # Upward whoosh-pluck: the message leaving.
        "MessageSent": ("message-sent.wav", finish(room(place([
            (0.0, glide(E4, B4 * 1.3, 0.24, curve=0.7)),
            (0.0, swell(600 * PITCH, 1400 * PITCH, 0.16, air=0.35, rise=0.6)),
        ]), tail=0.2), level=0.8)),

        # Two quick bright notes with a little bounce of echo.
        "MessageReceived": ("message-received.wav", finish(room(echo(place([
            (0.0, [v * 0.5 for v in thump(D3, 0.35, drop=0.85)]),  # bass bed
            (0.0, mallet(D5, 0.22, brightness=1.3)),
            (0.07, mallet(F_SHARP5, 0.3, brightness=1.3)),
        ]), delay=0.16, feedback=0.25, repeats=2)), level=0.85)),

        # Questions -----------------------------------------------------------
        # Two notes leaping up a fifth with a pause: "hm?"
        "Question": ("question.wav", finish(room(place([
            (0.0, [v * 0.5 for v in thump(D3, 0.35, drop=0.85)]),  # bass bed
            (0.0, mallet(D5, 0.12, brightness=1.2)),
            (0.09, mallet(A5, 0.5, bend=1.03)),
        ]), tail=0.4))),

        # Held hum with vibrato: a softer ask, e.g. a permission prompt.
        "PermissionAsk": ("permission-ask.wav", finish(room(place([
            (0.0, mallet(G4, 0.3, brightness=0.5)),
            (0.02, hum(G4, 0.75)),
        ]), tail=0.4), level=0.8)),

        # Reactions -----------------------------------------------------------
        # Quick dip then pop up: "oh!"
        "Surprised": ("surprised.wav", finish(room(place([
            (0.0, [v * 0.5 for v in thump(D3, 0.35, drop=0.85)]),  # bass bed
            (0.0, glide(B4, E4, 0.07, body=0.2)),
            (0.06, glide(E4, A5, 0.3, curve=0.5, body=0.4)),
        ]), tail=0.2), level=0.85)),

        # Note then its octave: a tiny high-five.
        "ThumbsUp": ("thumbs-up.wav", finish(room(place([
            (0.0, [v * 0.5 for v in thump(D3, 0.35, drop=0.85)]),  # bass bed
            (0.0, mallet(A5, 0.15, brightness=1.4)),
            (0.09, mallet(A5 * 2, 0.3, brightness=1.0)),
        ]), tail=0.2), level=0.7)),

        # Jobs ----------------------------------------------------------------
        # Sweeping launch with weight underneath.
        "JobStarted": ("job-started.wav", finish(room(place([
            (0.0, thump(A3 * 0.5, 0.3)),
            (0.0, glide(D4, D5, 0.45, curve=0.5, body=0.5)),
        ]), tail=0.35))),

        # Low two-tone wobble with a high glint on top: look over here.
        "JobNeedsYou": ("job-needs-you.wav", finish(room(place([
            (0.0, hum(D4, 0.22, vibrato=0.0, rise=0.1)),
            (0.12, hum(F_SHARP4, 0.3, vibrato=0.0, rise=0.1)),
            (0.16, [v * 0.3 for v in mallet(D6, 0.25, brightness=1.5)]),
            (0.5, hum(D4, 0.22, vibrato=0.0, rise=0.1)),
            (0.62, hum(F_SHARP4, 0.4, vibrato=0.0, rise=0.1)),
        ]), tail=0.35))),

        # Rising fourth that rings out: done, and satisfied.
        "JobDone": ("job-done.wav", finish(room(place([
            (0.0, mallet(D5, 0.5)),
            (0.16, mallet(G5, 0.9, brightness=1.2)),
            (0.16, [v * 0.25 for v in mallet(D6, 0.7)]),
        ]), tail=0.5))),

        # One deep, long, soft tone: put away.
        "JobClosed": ("job-closed.wav", finish(room(place([
            (0.0, mallet(D3, 1.1, brightness=0.4)),
            (0.0, [v * 0.4 for v in thump(D3, 0.4, drop=0.9)]),
        ]), tail=0.3), level=0.85)),

        # Mates / skills ------------------------------------------------------
        # Rising chirp landing on a warm low thump.
        "LevelUp": ("level-up.wav", finish(room(place([
            (0.0, glide(A4, E5, 0.2, body=0.2)),
            (0.18, thump(A3 * 0.5, 0.5, drop=0.85)),
            (0.18, mallet(A3, 0.5, brightness=0.6)),
        ]), tail=0.3))),

        # Long falling slide.
        "LevelDown": ("level-down.wav", finish(room(place([
            (0.0, glide(E4, A3 * 0.5, 0.6, curve=0.8, body=0.4)),
        ]), tail=0.25), level=0.85)),

        # Boot / reveal -------------------------------------------------------
        # Low pulses stepping up, then a lift: powering on.
        "Boot": ("boot.wav", finish(room(place([
            (0.0, mallet(D4, 0.25, brightness=0.8)),
            (0.16, mallet(D4, 0.25, brightness=0.8)),
            (0.36, mallet(F_SHARP4, 0.25, brightness=0.9)),
            (0.52, mallet(F_SHARP4, 0.25, brightness=0.9)),
            (0.74, mallet(A4, 0.6, brightness=1.1)),
            (0.74, [v * 0.3 for v in mallet(A5, 0.5)]),
        ]), tail=0.45))),

        # Airy rising arpeggio with sparkles: here's home.
        "HomeReveal": ("home-reveal.wav", finish(room(place([
            (0.0, swell(D4, D5, 0.6, air=0.3, rise=0.5)),
            (0.08, mallet(D5, 0.4, brightness=0.9)),
            (0.2, mallet(A5, 0.5, brightness=1.0)),
            (0.32, mallet(D6, 0.8, brightness=1.0)),
            (0.25, sparkle(D6, 0.8)),
        ]), tail=0.7, wet=0.3))),

        # Onboarding: rumble that builds, a crack, then a chime. A mate is born.
        "Hatching": ("hatching.wav", finish(room(place([
            (0.0, rumble(2.8)),
            (1.6, [v * 0.4 for v in mallet(D5, 0.12, brightness=2.0)]),
            (2.1, [v * 0.5 for v in mallet(F_SHARP5, 0.12, brightness=2.0)]),
            (2.55, thump(D3, 0.4)),
            (2.6, mallet(D5, 0.6)),
            (2.7, mallet(F_SHARP5, 0.6)),
            (2.8, mallet(A5, 1.0, brightness=1.2)),
            (2.8, sparkle(A5, 0.9, count=9, seed=5)),
        ]), tail=0.8, wet=0.3))),

        # Disclosures -----------------------------------------------------------
        # Each kind of open/close has its own small gesture, so a popover, a
        # sheet, a side pane and a disclosure row never sound the same.

        # Popover: a tiny rising pop.
        "PopoverOpen": ("popover-open.wav", finish(room(place([
            (0.0, mallet(A5, 0.09, brightness=1.2)),
            (0.035, mallet(D6, 0.12)),
        ]), tail=0.12, wet=0.3), level=0.55)),
        "PopoverClose": ("popover-close.wav", finish(room(place([
            (0.0, mallet(D6, 0.08)),
            (0.03, mallet(A5, 0.1, brightness=0.9)),
        ]), tail=0.1, wet=0.3), level=0.5)),

        # Sheet: a soft swell that settles on a note, and its reverse.
        "SheetOpen": ("sheet-open.wav", finish(room(place([
            (0.0, swell(D4, A4, 0.32, air=0.25, rise=0.45)),
            (0.12, mallet(D5, 0.3, brightness=0.6)),
        ]), tail=0.25), level=0.6)),
        "SheetClose": ("sheet-close.wav", finish(room(place([
            (0.0, mallet(A4, 0.25, brightness=0.5)),
            (0.0, swell(A4, D4, 0.28, air=0.25, rise=0.2)),
        ]), tail=0.2), level=0.55)),

        # Side pane or drawer: an airy swish across, out and back.
        "PaneOpen": ("pane-open.wav", finish(room(place([
            (0.0, swell(900 * PITCH, 1800 * PITCH, 0.2, air=0.9, rise=0.7)),
            (0.02, glide(E4, B4, 0.18, curve=0.8, body=0.2)),
        ]), tail=0.15, wet=0.35), level=0.5)),
        "PaneClose": ("pane-close.wav", finish(room(place([
            (0.0, swell(1800 * PITCH, 800 * PITCH, 0.18, air=0.9, rise=0.25)),
            (0.0, glide(B4, E4, 0.16, curve=0.8, body=0.2)),
        ]), tail=0.12, wet=0.35), level=0.45)),

        # Disclosure row: a tiny two-note tick, up to open, down to close.
        "RowOpen": ("row-open.wav", finish(room(place([
            (0.0, mallet(E5, 0.07, brightness=0.9)),
            (0.025, mallet(A5, 0.08, brightness=0.9)),
        ]), tail=0.08, wet=0.25), level=0.45)),
        "RowClose": ("row-close.wav", finish(room(place([
            (0.0, mallet(A5, 0.06, brightness=0.9)),
            (0.025, mallet(E5, 0.08, brightness=0.9)),
        ]), tail=0.08, wet=0.25), level=0.4)),

        # Hover-peek of the notch: barely there, a breath.
        "Peek": ("peek.wav", finish(room(
            swell(500 * PITCH, 700 * PITCH, 0.22, air=1.2, rise=0.5),
            tail=0.12, wet=0.3), level=0.3)),
    }


# MARK: - Drawing sounds
# What the drawing canvas asks for as it paints (its markSound descriptions): a texture under every stroke and a
# small sound for a few moments. Clean-room, in the same deep, smooth profile; textures stay low and dry so they
# loop under the voice without fizz.

def grain(duration: float, center: float, width: float = 0.5, flutter: float = 0.0,
          seed: int = 5, loop: bool = False) -> list[float]:
    """Pen on a surface: band-limited noise (two one-pole filters), its level wandering a little; flutter pulses it
    like a hand writing letters. loop crossfades the end into the start so it can repeat seamlessly."""
    rng = random.Random(seed)
    total = int(duration * SAMPLE_RATE)
    hi = 1 - math.exp(-2 * math.pi * center * (1 + width) / SAMPLE_RATE)
    lo = 1 - math.exp(-2 * math.pi * center * (1 - width) / SAMPLE_RATE)
    a = b = drift = 0.0
    out: list[float] = []
    for i in range(total):
        t = i / SAMPLE_RATE
        x = rng.uniform(-1, 1)
        a += hi * (x - a)
        b += lo * (x - b)
        drift += 0.0004 * (rng.uniform(-1, 1) - drift)
        level = 0.8 + 6 * drift
        if flutter:
            level *= 0.55 + 0.45 * abs(math.sin(math.pi * flutter * t))
        out.append((a - b) * level)
    if loop:
        fade = int(0.12 * SAMPLE_RATE)
        for i in range(fade):
            g = i / fade
            out[i] = out[i] * g + out[total - fade + i] * (1 - g)
        out = out[: total - fade]
    else:
        attack, release = int(0.01 * SAMPLE_RATE), int(0.06 * SAMPLE_RATE)
        for i in range(len(out)):
            out[i] *= min(1.0, i / attack) * min(1.0, (len(out) - i) / release)
    return out


def dry(samples: list[float]) -> list[tuple[float, float]]:
    return [(v, v) for v in samples]


def build_drawing_sounds() -> dict[str, tuple[str, list[float]]]:
    taps = place([(k * 0.07, [v * 0.6 for v in mallet(G5 if k % 2 else E5, 0.04, brightness=0.4)]) for k in range(6)])
    return {
        # Textures, looped for as long as a stroke draws.
        "DrawFelt": ("draw-felt.wav", finish(dry(grain(1.6, 700, 0.45, seed=21, loop=True)), level=0.35)),
        "DrawPencil": ("draw-pencil.wav", finish(dry(grain(1.6, 1400, 0.35, seed=22, loop=True)), level=0.25)),
        "DrawWriting": ("draw-writing.wav", finish(dry(grain(1.6, 1300, 0.35, flutter=5.5, seed=23, loop=True)), level=0.25)),
        "DrawEraser": ("draw-eraser.wav", finish(dry(grain(1.6, 420, 0.5, flutter=3.0, seed=24, loop=True)), level=0.35)),
        # Moments.
        "DrawPaperPlace": ("draw-paper-place.wav", finish(room(place([
            (0.0, thump(D3 * 2, 0.22, drop=0.7)), (0.0, grain(0.18, 900, 0.6, seed=31))]), tail=0.15, wet=0.25), level=0.5)),
        "DrawTape": ("draw-tape.wav", finish(room(grain(0.14, 1600, 0.4, flutter=18, seed=32), tail=0.05, wet=0.2), level=0.35)),
        "DrawPhotoDrop": ("draw-photo-drop.wav", finish(room(place([
            (0.0, thump(A3, 0.28, drop=0.6)), (0.01, mallet(D4, 0.2, brightness=0.5)), (0.0, grain(0.12, 800, 0.6, seed=33))]),
            tail=0.2), level=0.55)),
        "DrawPop": ("draw-pop.wav", finish(room(mallet(E5, 0.09, brightness=0.6), tail=0.08, wet=0.2), level=0.35)),
        "DrawTargetPing": ("draw-target-ping.wav", finish(room(echo(mallet(A5, 0.25, brightness=0.7), delay=0.12,
            feedback=0.35, repeats=2), tail=0.2), level=0.45)),
        "DrawPenFlick": ("draw-pen-flick.wav", finish(room(mallet(D6, 0.04, brightness=0.4), tail=0.05, wet=0.15), level=0.2)),
        "DrawBuild3D": ("draw-build-3d.wav", finish(room(place([
            (0.0, glide(C4, G4, 0.22, curve=0.7, body=0.5)), (0.05, mallet(G5, 0.2, brightness=0.6))]), tail=0.2), level=0.4)),
        "DrawSlide": ("draw-slide.wav", finish(room(swell(400 * PITCH, 600 * PITCH, 0.25, air=1.0, rise=0.4), tail=0.1, wet=0.25), level=0.3)),
        "DrawPageClear": ("draw-page-clear.wav", finish(room(place([
            (0.0, swell(900 * PITCH, 400 * PITCH, 0.4, air=1.4, rise=0.3)), (0.0, grain(0.35, 700, 0.6, seed=34))]),
            tail=0.2), level=0.4)),
        "DrawHighlighter": ("draw-highlighter.wav", finish(dry(grain(0.35, 600, 0.6, seed=35)), level=0.3)),
        "DrawTypeKeys": ("draw-type-keys.wav", finish(room(taps, tail=0.05, wet=0.15), level=0.3)),
        "DrawCopyTick": ("draw-copy-tick.wav", finish(room(place([
            (0.0, mallet(G5, 0.06, brightness=0.6)), (0.05, mallet(C6, 0.1, brightness=0.6))]), tail=0.1), level=0.35)),
        # The model's sfx() accents.
        "DrawTada": ("draw-tada.wav", finish(room(place([
            (0.0, mallet(C5, 0.3)), (0.08, mallet(E5, 0.3)), (0.16, mallet(G5, 0.35)), (0.24, mallet(C6, 0.6))])), level=0.6)),
        "DrawDing": ("draw-ding.wav", finish(room(mallet(A5, 0.7, brightness=0.8)), level=0.5)),
        "DrawNope": ("draw-nope.wav", finish(room(place([
            (0.0, glide(E4, B3, 0.3, curve=1.2)), (0.0, thump(D3 * 2, 0.2))]), tail=0.15), level=0.5)),
        "DrawStamp": ("draw-stamp.wav", finish(room(place([
            (0.0, thump(D3 * 2, 0.3, drop=0.5)), (0.0, grain(0.06, 500, 0.6, seed=36))]), tail=0.15, wet=0.3), level=0.6)),
        "DrawSparkle": ("draw-sparkle.wav", finish(room(sparkle(E5, 0.5)), level=0.45)),
        "DrawWhoosh": ("draw-whoosh.wav", finish(room(swell(300 * PITCH, 900 * PITCH, 0.4, air=1.6, rise=0.5), tail=0.15), level=0.4)),
        "DrawBoing": ("draw-boing.wav", finish(room(place([
            (0.0, glide(D4, A4, 0.12, curve=0.6)), (0.12, glide(A4, E4, 0.3, curve=0.8))]), tail=0.15), level=0.45)),
        "DrawPageTurn": ("draw-page-turn.wav", finish(room(grain(0.3, 900, 0.6, flutter=2.0, seed=37), tail=0.1, wet=0.25), level=0.35)),
    }


def write_dataset_contents(dataset: str, file_name: str) -> None:
    contents = {
        "data": [{"filename": file_name, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(dataset, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)


def main() -> None:
    out_dir = None
    if "--out" in sys.argv:
        out_dir = sys.argv[sys.argv.index("--out") + 1]
    assets_root = os.path.join(os.path.dirname(__file__), "..", "HeyMate", "Assets.xcassets")

    # --drawing writes only the drawing sounds, leaving the approved UI set as it is.
    sounds = build_drawing_sounds() if "--drawing" in sys.argv else build_sounds()
    for asset_name, (file_name, samples) in sounds.items():
        if out_dir:
            write_wav(os.path.join(out_dir, file_name), samples)
        else:
            dataset = os.path.join(assets_root, f"{asset_name}.dataset")
            for stale in os.listdir(dataset) if os.path.isdir(dataset) else []:
                if stale.endswith((".wav", ".m4a")):
                    os.remove(os.path.join(dataset, stale))
            wav_path = os.path.join(dataset, file_name)
            write_wav(wav_path, samples)
            # Apple Lossless: bit-identical audio at about half the size.
            m4a_path = wav_path[:-4] + ".m4a"
            subprocess.run(["afconvert", "-f", "m4af", "-d", "alac", wav_path, m4a_path], check=True)
            os.remove(wav_path)
            write_dataset_contents(dataset, os.path.basename(m4a_path))


if __name__ == "__main__":
    main()
