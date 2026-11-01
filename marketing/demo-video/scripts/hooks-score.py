#!/usr/bin/env python3
"""HeyMate hook shorts — three 30-second dark-synth scores, one per hook.

Everything synthesized here (no samples). 120 BPM so every cut lands on a beat.
Hook section runs until the voiceover ends (public/hooks/vo-meta.json, from hooks-vo.mjs);
the bass drops there and the music cuts dead 17 s later on the last word.
    python3 marketing/demo-video/scripts/hooks-score.py
Writes public/hooks/score-{anger,insider,lazy}.wav (48 kHz stereo).
"""

import json
from pathlib import Path
import numpy as np
from scipy.signal import butter, sosfilt
from scipy.io import wavfile

RATE = 48000
BPM = 120
BEAT = 60 / BPM
BODY = 17.0
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "public" / "hooks"
META = json.loads((OUT / "vo-meta.json").read_text())


def lp(x, hz, order=2):
    return sosfilt(butter(order, hz, "low", fs=RATE, output="sos"), x)


def hp(x, hz, order=2):
    return sosfilt(butter(order, hz, "high", fs=RATE, output="sos"), x)


def bp(x, lo, hi):
    return sosfilt(butter(2, [lo, hi], "band", fs=RATE, output="sos"), x)


def place(buf, sig, at, gain=1.0):
    i = int(at * RATE)
    if i >= len(buf):
        return
    j = min(len(buf), i + len(sig))
    buf[i:j] += sig[: j - i] * gain


def env(n, a=0.002, d=0.2):
    t = np.arange(n) / RATE
    return np.minimum(1, t / max(a, 1e-4)) * np.exp(-t / d)


def kick():
    n = int(0.45 * RATE)
    t = np.arange(n) / RATE
    f = 45 + 120 * np.exp(-t * 35)
    return np.sin(2 * np.pi * np.cumsum(f) / RATE) * env(n, 0.001, 0.16) * 1.1


def snare(rng):
    n = int(0.3 * RATE)
    t = np.arange(n) / RATE
    noise = bp(rng.standard_normal(n), 1200, 7000) * env(n, 0.001, 0.09)
    body = np.sin(2 * np.pi * 190 * t) * env(n, 0.001, 0.05)
    return noise * 0.7 + body * 0.5


def hat(rng, d=0.03):
    n = int(0.12 * RATE)
    return hp(rng.standard_normal(n), 8000) * env(n, 0.0005, d) * 0.25


def saw(freq, n, detune=0.0):
    t = np.arange(n) / RATE
    out = np.zeros(n)
    for dt in (-detune, 0, detune):
        ph = (t * freq * (1 + dt)) % 1
        out += 2 * ph - 1
    return out / 3


def note(m):
    return 440 * 2 ** ((m - 69) / 12)


def slam(rng):
    n = int(0.9 * RATE)
    t = np.arange(n) / RATE
    boom = np.sin(2 * np.pi * np.cumsum(38 + 90 * np.exp(-t * 18)) / RATE) * env(n, 0.001, 0.35)
    crack = lp(rng.standard_normal(n), 5000) * env(n, 0.0005, 0.04)
    return boom * 1.2 + crack * 0.9


def whoosh(rng, length=0.6, rise=True):
    n = int(length * RATE)
    t = np.linspace(0, 1, n)
    shape = np.sin(np.pi * (t if rise else 1 - t) ** 1.5 * 0.5 + 0.0) ** 2 if rise else np.sin(np.pi * t) ** 2
    return bp(rng.standard_normal(n), 400, 6000) * shape * 0.5


def static(rng, length=0.4):
    n = int(length * RATE)
    g = (rng.random(n) > 0.6).astype(float)
    g = np.repeat(g[:: 240], 240)[:n]
    return hp(rng.standard_normal(n), 1500) * g * env(n, 0.001, length) * 0.5


def keyclicks(rng, at, count=10, spacing=0.09):
    out = []
    for k in range(count):
        n = int(0.04 * RATE)
        c = bp(rng.standard_normal(n), 2000, 9000) * env(n, 0.0003, 0.008) * 0.6
        out.append((c, at + k * spacing + rng.uniform(-0.015, 0.015)))
    return out


def hum(length=4.0):
    n = int(length * RATE)
    t = np.arange(n) / RATE
    s = sum(np.sin(2 * np.pi * f * t + 0.3 * np.sin(2 * np.pi * 0.7 * t)) for f in (110, 165, 220.5, 331))
    trem = 0.6 + 0.4 * np.sin(2 * np.pi * 6 * t)
    fade = np.minimum(1, t / 0.4) * np.minimum(1, (length - t) / 0.6)
    return s / 4 * trem * fade * 0.35


def ding():
    n = int(1.4 * RATE)
    t = np.arange(n) / RATE
    return (np.sin(2 * np.pi * 1318 * t) + 0.5 * np.sin(2 * np.pi * 2637 * t)) * env(n, 0.001, 0.45) * 0.35


def error_pop():
    n = int(0.25 * RATE)
    t = np.arange(n) / RATE
    return np.sign(np.sin(2 * np.pi * (300 - 140 * t / 0.25) * t)) * env(n, 0.001, 0.1) * 0.25


def riser(rng, length=3.5):
    n = int(length * RATE)
    t = np.arange(n) / RATE
    f = 200 * (8 ** (t / length))
    tone = saw(1, n) * 0
    tone = np.sin(2 * np.pi * np.cumsum(f) / RATE)
    noise = hp(rng.standard_normal(n), 2000)
    shape = (t / length) ** 2
    return (tone * 0.25 + noise * 0.3) * shape


def scratch(rng):
    n = int(0.5 * RATE)
    t = np.arange(n) / RATE
    rate = 1 + 0.9 * np.sin(2 * np.pi * 6 * t)
    src = bp(rng.standard_normal(n), 300, 3000)
    idx = np.clip(np.cumsum(rate).astype(int), 0, n - 1)
    return src[idx] * env(n, 0.005, 0.3) * 0.8


def breath(rng, length=1.2):
    n = int(length * RATE)
    t = np.linspace(0, 1, n)
    return bp(rng.standard_normal(n), 500, 3500) * np.sin(np.pi * t) ** 2 * 0.12


def build(kind):
    rng = np.random.default_rng({"anger": 11, "insider": 22, "lazy": 33}[kind])
    DROP = META[kind]["drop"]
    starts = META[kind]["starts"]
    CUT = DROP + BODY
    N = int(RATE * CUT)
    L = np.zeros(N)
    R = np.zeros(N)

    def both(sig, at, gain=1.0, pan=0.0):
        place(L, sig, at, gain * (1 - max(0, pan)))
        place(R, sig, at, gain * (1 + min(0, pan)))

    K, S = kick(), snare(rng)
    # Am – F – C – G, dark synthwave
    prog = [(57, 60, 64), (53, 57, 60), (48, 52, 55), (55, 59, 62)]
    bass_roots = [33, 29, 36, 31]
    bar = BEAT * 4

    # ---- hook section (0 → DROP) ----
    if kind == "anger":
        both(slam(rng), 0.25, 1.0)
        both(whoosh(rng, 0.5), 0.0, 0.6)
        for b in range(int(DROP / BEAT)):
            at = b * BEAT
            both(K, at, 0.55)
            if b % 2:
                both(S, at, 0.35)
            both(hat(rng), at + BEAT / 2, 0.8, 0.3)
        for b, s in enumerate(np.arange(0.5, DROP, BEAT / 2)):
            ch = bass_roots[int(s // bar) % 4]
            n = int(BEAT / 2 * RATE * 0.9)
            both(lp(saw(note(ch), n, 0.004), 500) * env(n, 0.003, 0.12), s, 0.45)
        for at in starts[1:]:
            both(static(rng, 0.3), at, 0.6)
        both(whoosh(rng, 0.8), DROP - 0.8, 0.8)
    elif kind == "insider":
        n = int(DROP * RATE)
        t = np.arange(n) / RATE
        drone = sum(np.sin(2 * np.pi * f * t + np.sin(2 * np.pi * 0.11 * t * k)) for k, f in enumerate((55, 82.4, 110.5), 1))
        both(lp(drone / 3, 400) * np.minimum(1, t / 1.5) * 0.35, 0.0)
        for at in (0.4, 2.6, 4.9):
            both(breath(rng), at, 1.0, -0.2)
        for b in range(int(DROP / BEAT)):
            if b >= 8:
                both(K, b * BEAT, 0.25 + 0.03 * (b - 8))
        for at in starts[1:]:
            both(static(rng, 0.25), at, 0.8)
        both(riser(rng, 3.0), DROP - 3.0, 0.7)
    else:  # lazy
        for i, s in enumerate(np.arange(0, starts[1], bar / 2)):
            ch = [(60, 64, 67, 71), (57, 60, 64, 67)][i % 2]
            n = int(bar / 2 * RATE)
            t = np.arange(n) / RATE
            pad = sum(np.sin(2 * np.pi * note(m) * t) for m in ch) / 4
            wob = 1 + 0.003 * np.sin(2 * np.pi * 0.5 * t)
            both(lp(pad * wob, 1500) * np.minimum(1, t / 0.05) * np.exp(-t / 1.6) * 0.5, s)
        for b in range(int(starts[1] / BEAT)):
            both(K, b * BEAT, 0.35)
            if b % 2:
                both(lp(S, 2500), b * BEAT, 0.3)
        both(scratch(rng), starts[1] - 0.05, 1.0)
        both(whoosh(rng, 0.5), starts[1], 0.8)
        for b in range(int(starts[1] / BEAT) + 1, int(DROP / BEAT)):
            both(K, b * BEAT, 0.6)
            both(hat(rng), b * BEAT + BEAT / 2, 0.9, 0.3)
        for k, (c, at) in enumerate(keyclicks(rng, starts[2] + 0.2, 6, 0.25)):
            both(c, at, 1.0, 0.2 if k % 2 else -0.2)
        both(whoosh(rng, 0.8), DROP - 0.8, 0.8)

    # ---- drop (DROP → CUT) ----
    both(slam(rng), DROP, 1.2)
    t_beats = np.arange(DROP, CUT, BEAT)
    for b, at in enumerate(t_beats):
        both(K, at, 1.0)
        if b % 2:
            both(S, at, 0.9)
        both(hat(rng), at + BEAT / 2, 1.0, 0.25)
        both(hat(rng, 0.012), at + BEAT / 4, 0.6, -0.25)
        both(hat(rng, 0.012), at + 3 * BEAT / 4, 0.6, -0.25)
    for s in np.arange(DROP, CUT, BEAT / 4):
        bi = int((s - DROP) // bar) % 4
        n = int(BEAT / 4 * RATE * 0.85)
        oct_ = 12 if int((s - DROP) / (BEAT / 4)) % 4 == 2 else 0
        both(lp(saw(note(bass_roots[bi] + oct_), n, 0.006), 900) * env(n, 0.002, 0.09), s, 0.55)
    for i, s in enumerate(np.arange(DROP, CUT, bar)):
        ch = prog[i % 4]
        n = int(bar * RATE)
        t = np.arange(n) / RATE
        pad = sum(saw(note(m), n, 0.008) for m in ch) / 3
        both(lp(pad, 1800) * np.minimum(1, t / 0.08) * np.exp(-t / 3) * 0.22, s, 1.0, 0.15 if i % 2 else -0.15)
        # stab lead
        for k, off in enumerate((0, 0.75, 1.5)):
            m = ch[k % 3] + 12
            nn = int(0.18 * RATE)
            both(hp(saw(note(m), nn, 0.01), 300) * env(nn, 0.002, 0.07) * 0.18, s + off, 1.0, 0.4 if k % 2 else -0.4)

    # body sfx per master script
    both(static(rng, 0.5), DROP, 0.8)
    for c, at in keyclicks(rng, DROP + 0.4, 18, 0.1):
        both(c, at, 1.1)
    both(hum(4.0), DROP + 4, 1.0)
    both(whoosh(rng, 0.5), DROP + 3.6, 0.6)
    both(ding(), DROP + 8, 1.0)
    both(error_pop(), DROP + 9, 1.0)
    both(riser(rng, 3.5), DROP + 11.5, 1.0)
    both(whoosh(rng, 0.5), DROP + 14.6, 0.7)

    mix = np.stack([L, R], 1)
    peak = np.max(np.abs(mix))
    mix = np.tanh(mix / peak * 1.6) / np.tanh(1.6) * 0.89
    OUT.mkdir(parents=True, exist_ok=True)
    wavfile.write(OUT / f"score-{kind}.wav", RATE, (mix * 32767).astype(np.int16))
    print("wrote", OUT / f"score-{kind}.wav")


for k in ("anger", "insider", "lazy"):
    build(k)
