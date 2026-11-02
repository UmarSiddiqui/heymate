#!/usr/bin/env python3
"""HeyMate: Little Company — original 60-second, 128 BPM launch-film score.

All oscillators, percussion, atmosphere and effects are synthesized here.
No samples, borrowed melody, recorded voices or external musical assets.
Requires numpy, scipy and ffmpeg. Run from any directory:
    python3 marketing/demo-video/scripts/launch-score.py

Arrangement: 32 bars, D major / B minor; warm ninth chords, syncopated glass
pluck, rounded sub bass, garage percussion, scene-synced editorial accents.
Final master: 48 kHz stereo PCM, -15 LUFS target / -1.5 dBTP ceiling.
"""

from pathlib import Path
import json
import subprocess
import tempfile
import numpy as np
from scipy.signal import butter, sosfilt
from scipy.io import wavfile

RATE = 48000
DURATION = 60
BPM = 128
BEAT = 60 / BPM
BAR = BEAT * 4
COUNT = RATE * DURATION
RNG = np.random.default_rng(74019)
ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "public" / "launch" / "score.wav"

music = np.zeros((COUNT, 2), dtype=np.float64)
drums = np.zeros_like(music)
fx = np.zeros_like(music)
send = np.zeros_like(music)
kick_times = []


def hz(note):
    return 440 * 2 ** ((note - 69) / 12)


def time(duration):
    return np.arange(round(duration * RATE)) / RATE


def filter_audio(signal, cutoff, mode="lowpass", order=2):
    return sosfilt(butter(order, cutoff, mode, fs=RATE, output="sos"), signal, axis=0)


def put(bus, signal, at, level=1, pan=0, wet=0):
    start = round(at * RATE)
    if start >= COUNT:
        return
    skip = max(0, -start)
    start = max(0, start)
    signal = signal[skip:skip + COUNT - start]
    if signal.ndim == 1:
        theta = (pan + 1) * np.pi / 4
        signal = signal[:, None] * np.array([np.cos(theta), np.sin(theta)])[None, :]
    bus[start:start + len(signal)] += signal * level
    if wet:
        send[start:start + len(signal)] += signal * level * wet


def pluck(note, duration=1.2, bright=1, variant=0):
    t = time(duration)
    f = hz(note)
    mod = (.9 + bright * .9) * np.exp(-t * (7 + variant)) * np.sin(2 * np.pi * f * 2 * t)
    s = np.sin(2 * np.pi * f * t + mod)
    s += .16 * np.sin(2 * np.pi * f * .501 * t) * np.exp(-t * 5)
    s += .11 * np.sin(2 * np.pi * f * 3.003 * t) * np.exp(-t * 12)
    env = (1 - np.exp(-t * 650)) * np.exp(-t * 3.9)
    env *= np.clip((duration - t) / .15, 0, 1)
    return s * env


def pad(notes, duration):
    t = time(duration)
    result = np.zeros((len(t), 2))
    for j, note in enumerate(notes):
        f = hz(note)
        phase = RNG.uniform(0, np.pi * 2)
        for channel, detune in enumerate((.9987, 1.0013)):
            s = np.sin(2 * np.pi * f * detune * t + phase)
            s += .17 * np.sin(2 * np.pi * f * 2 * detune * t + phase)
            s += .065 * np.sin(2 * np.pi * f * 3 * detune * t + phase)
            result[:, channel] += s * (.85 + .15 * np.sin(t * .8 + j))
    env = np.minimum(1, t / .5) * np.minimum(1, np.maximum(0, duration - t) / 1.2)
    return result * env[:, None] / len(notes)


def bass(note, duration=.4, strength=1):
    t = time(duration)
    f = hz(note)
    s = np.sin(2 * np.pi * f * t)
    s += .22 * np.sin(2 * np.pi * f * 2 * t) * np.exp(-t * 6)
    s += .07 * np.sin(2 * np.pi * f * 3 * t) * np.exp(-t * 11)
    s = np.tanh(s * 1.25) / 1.1
    env = (1 - np.exp(-t * 450)) * np.exp(-t * 1.3)
    env *= np.clip((duration - t) / .07, 0, 1)
    return s * env * strength


def kick(at, power=1):
    t = time(.62)
    f = 46 + 105 * np.exp(-t * 46) + 18 * np.exp(-t * 8)
    body = np.sin(2 * np.pi * np.cumsum(f) / RATE)
    body *= np.exp(-t * 9.0) * (1 - np.exp(-t * 1700))
    click = filter_audio(RNG.standard_normal(len(t)), 3800, "highpass")
    click *= np.exp(-t * 700) * .12
    put(drums, np.tanh((body + click) * 1.3), at, .49 * power)
    kick_times.append(at)


def clap(at, power=1):
    t = time(.25)
    noise = filter_audio(RNG.standard_normal(len(t)), [950, 8500], "bandpass")
    env = np.zeros_like(t)
    for delay in [0, .012, .024]:
        local = t - delay
        env += np.where(local >= 0, np.exp(-np.maximum(local, 0) * (190 if delay < .024 else 30)), 0)
    snap = noise * env
    snap += .14 * np.sin(2 * np.pi * 190 * t) * np.exp(-t * 35)
    put(drums, np.tanh(snap * 1.15), at, .23 * power, pan=.05, wet=.18)


def hat(at, power=.5, opened=False, pan=.25):
    duration = .24 if opened else .075
    t = time(duration)
    noise = filter_audio(RNG.standard_normal(len(t)), 7200, "highpass")
    metal = sum(np.sin(2 * np.pi * f * t) for f in [8010, 10570, 12917]) / 3
    env = (1 - np.exp(-t * 2400)) * np.exp(-t * (22 if opened else 85))
    s = (noise * .8 + metal * .09) * env
    put(drums, s, at, .11 * power, pan=pan, wet=.035)


def rim(at, power=.5, pan=-.32):
    t = time(.085)
    s = (np.sin(t * 2 * np.pi * 510) + .6 * np.sin(t * 2 * np.pi * 1243))
    s *= np.exp(-t * 90) * (1 - np.exp(-t * 3000))
    put(drums, s, at, .08 * power, pan=pan, wet=.08)


def transition(at, strength=.6):
    # Airy reverse sweep and low soft landing, separate from musical drum grid.
    d = .75
    t = time(d)
    noise = filter_audio(RNG.standard_normal(len(t)), [800, 7300], "bandpass")
    env = (t / d) ** 2.7 * np.minimum(1, (d - t) / .015)
    stereo = np.stack([noise, np.roll(noise, 311)], axis=1)
    put(fx, stereo * env[:, None], at - d, .13 * strength)
    t = time(.85)
    f = 45 + 80 * np.exp(-t * 14)
    thump = np.sin(2 * np.pi * np.cumsum(f) / RATE) * np.exp(-t * 8)
    put(fx, thump, at, .15 * strength)
    put(fx, pluck(86, 1.4, .2), at, .065 * strength, pan=-.15, wet=.8)


# Dmaj9, Bm9, Gmaj9, Aadd9. Soft spread voicings with coherent bass movement.
chords = [[50, 57, 61, 64, 66], [47, 54, 57, 61, 62],
          [43, 50, 54, 57, 59], [45, 52, 57, 59, 61]]
roots = [38, 35, 31, 33]
for bar in range(0, 30, 2):
    ci = (bar // 2) % 4
    start = bar * BAR
    volume = .115 if start < 3 else .155
    put(music, pad(chords[ci], BAR * 2 + 1), start, volume, wet=.45)

# Pluck motif — syncopated call/answer rather than a constant arpeggiator.
patterns = [
    [(0, 78), (.75, 81), (1.5, 76), (2.5, 78), (3.25, 73)],
    [(.5, 74), (1.25, 78), (2, 81), (3, 78), (3.5, 76)],
    [(0, 74), (.75, 78), (1.75, 81), (2.5, 83), (3.25, 78)],
    [(.5, 73), (1.25, 76), (2.25, 81), (3, 78), (3.5, 76)],
]
for bar in range(30):
    start = bar * BAR
    ci = (bar // 2) % 4
    intensity = .7 if bar < 2 else (1.0 if bar < 14 else .9)
    if 15 <= bar <= 16:
        intensity = .56
    if 23 <= bar <= 25:
        intensity = .85
    for j, (beat, note) in enumerate(patterns[ci]):
        at = start + beat * BEAT
        if at > 54:
            continue
        # Intro is sparse; second half gains octave sparkle and echo.
        if bar < 2 and j % 2:
            continue
        pan = [-.38, .26, -.1, .4, -.25][j]
        put(music, pluck(note, 1.4, .6), at, .115 * intensity, pan, wet=.5)
        put(music, pluck(note, .9, .25), at + BEAT * .75, .025 * intensity, -pan, wet=.35)
        if bar >= 18 and j == 2:
            put(music, pluck(note + 12, 1.3, .2), at, .027, -.3, wet=.65)

for bar in range(2, 29):
    start = bar * BAR
    ci = (bar // 2) % 4
    quiet = bar in [15, 16]
    # Deliberate clean break under the first visual reveal; ramp back quickly.
    for beat in range(4):
        at = start + beat * BEAT
        if at > 54.05:
            continue
        if not quiet or beat in [0, 2]:
            kick(at, .78 if quiet else 1)
        if beat in [1, 3] and not quiet:
            clap(at, .94 + .06 * (bar % 2))
    for i in range(8):
        at = start + (i / 2 + (.025 if i % 2 else 0)) * BEAT
        if at > 54:
            continue
        if quiet and i % 2 == 0:
            continue
        hat(at, (.62 if i % 2 else .38) * (.65 if quiet else 1), opened=(i % 2 == 1), pan=.22 if i % 2 else -.15)
    if bar >= 4 and not quiet:
        for beat, power in [(.75, .55), (2.75, .72), (3.75, .42)]:
            rim(start + beat * BEAT, power, -.35)
    if bar in [7, 13, 19, 25, 27]:
        for j in range(4):
            at = start + (3 + j * .25) * BEAT
            hat(at, .35 + j * .12, pan=(-1) ** j * .35)
    for beat, length, octave, level in [(0, .65, 0, 1), (1.5, .32, 0, .86),
                                       (2.25, .38, 12, .56), (3, .5, 0, .92), (3.75, .16, 0, .55)]:
        at = start + beat * BEAT
        if at > 53.9 or quiet and beat not in [0, 3]:
            continue
        put(music, bass(roots[ci] + octave, length * BEAT), at + .012, .30 * level)

# A gentle introductory heartbeat and jewel notes give the opening a signature.
for i in range(6):
    rim(i * .47, .45, (-1) ** i * .25)
put(music, pluck(86, 1.8, .2), .2, .075, -.2, wet=.8)
put(music, pluck(81, 1.8, .2), 1.4, .06, .25, wet=.8)

for at, strength in [(3, .85), (8, .45), (18, .65), (28, .7), (40, .65), (48, .55), (54, 1)]:
    transition(at, strength)

# Last six seconds open into a spacious logo hold with a D-major resolution.
put(music, pad([38, 50, 57, 61, 66], 6.0), 54, .22, wet=.5)
put(music, bass(38, 2.0), 54, .28)
for at, note, volume in [(54, 74, .12), (54.18, 78, .10), (54.38, 81, .09),
                         (55.2, 86, .10), (56.1, 81, .075), (56.8, 78, .065)]:
    put(music, pluck(note, 2.2, .2), at, volume, -.2 if note % 2 else .2, wet=.8)

# Sidechain gives kicks room and audible motion without flattening transients.
duck = np.ones(COUNT)
for at in kick_times:
    start = round(at * RATE)
    t = time(.31)
    end = min(COUNT, start + len(t))
    duck[start:end] = np.minimum(duck[start:end], 1 - .47 * np.exp(-t[:end-start] * 15))
music *= duck[:, None]

# Diffused stereo reflections; darker tails keep the melody crisp and upscale.
send = filter_audio(send, 4800)
reverb = np.zeros_like(send)
for delay, gain, swap in [(.071, .15, True), (.119, .12, False), (.181, .105, True),
                          (.263, .085, False), (.397, .07, True), (.571, .05, False),
                          (.811, .037, True), (1.127, .025, False)]:
    offset = round(delay * RATE)
    source = send[:-offset, ::-1] if swap else send[:-offset]
    reverb[offset:] += source * gain

mix = music + drums + fx + reverb
mix = filter_audio(mix, 28, "highpass")
mix = filter_audio(mix, 16800)
# Mild analog saturation is below the final dynamics stage.
mix = np.tanh(mix * 1.12) / 1.12
timeline = np.arange(COUNT) / RATE
fade_in = np.clip(timeline / .12, 0, 1)
fade_out = np.clip((DURATION - timeline) / 2.0, 0, 1) ** 1.5
mix *= (fade_in * fade_out)[:, None]
mix *= .86 / np.max(np.abs(mix))
DEST.parent.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="heymate-launch-score-") as tmp:
    raw = Path(tmp) / "original-score.wav"
    wavfile.write(raw, RATE, mix.astype(np.float32))
    base = ["ffmpeg", "-hide_banner", "-y", "-i", str(raw)]
    analysis = subprocess.run(base + ["-af", "loudnorm=I=-15:TP=-1.5:LRA=9:print_format=json", "-f", "null", "-"], capture_output=True, text=True, check=True)
    payload = analysis.stderr[analysis.stderr.rfind("{"):]
    stats, _ = json.JSONDecoder().raw_decode(payload)
    normalizer = ("loudnorm=I=-15:TP=-1.5:LRA=9:linear=true:"
                  f"measured_I={stats['input_i']}:measured_TP={stats['input_tp']}:"
                  f"measured_LRA={stats['input_lra']}:measured_thresh={stats['input_thresh']}:"
                  f"offset={stats['target_offset']}:print_format=json")
    result = subprocess.run(base + ["-af", normalizer, "-ar", str(RATE), "-ac", "2", "-c:a", "pcm_s24le", str(DEST)], capture_output=True, text=True, check=True)
    print(result.stderr[result.stderr.rfind("{"):])

print(f"Created {DEST}")
print("60.000 seconds | 48000 Hz | stereo | 24-bit PCM | 128 BPM | original synthesis")
