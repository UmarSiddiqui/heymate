# HeyMate — 60-second launch film

A new 1920×1080, 60 fps brand and product film. Fast editorial cuts, original instrumental score, kinetic typography, actual product recordings, and clearly labeled illustrative interactions. The film is readable without audio. No app install, website deploy, or publishing is involved.

## Deliverables

- `../../out/launch/HeyMate-60s-1080p60.mp4`: exactly 60 seconds, H.264 / AAC.
- `../../out/launch/HeyMate-poster.jpg`: closing brand frame.
- `../../out/launch/preview.html`: local player.
- `../../out/launch/verification.json`: output metadata and validation.

## Rebuild

From `marketing/demo-video`:

```sh
npm run typecheck
node scripts/launch-render.mjs stills
node scripts/launch-render.mjs render
```

Remotion composition: `HeyMateLaunch60`, entry point `src/launch/index.tsx`. Uses existing project dependencies. Rendering requires local loopback/server and Chromium access. No dependency installation needed on this Mac.

## Cut

| Time | Story |
| --- | --- |
| 00–03 | Your Mac. With a mate. |
| 03–08 | HeyMate product reveal |
| 08–12 | Hold Control + Option and ask |
| 12–15 | Keynote: Animate |
| 15–18 | Keynote: Add an Effect |
| 18–21 | Keynote: Fly In |
| 21–24 | Keynote title animation |
| 24–28 | Approved computer control |
| 28–32 | 3D board explanation |
| 32–36 | Camera connection diagram |
| 36–40 | Illustrated recipe explanation |
| 40–44 | Specialist mates |
| 44–48 | Example delegated inbox task |
| 48–54 | Bring your own AI |
| 54–60 | Brand close and website CTA |

## Media provenance

Original artwork, icon, local Figtree font, and product images copied from this repository into `public/launch/`. `home.webp` is a product screenshot. `drive.png` is a product screenshot, with a deliberately illustrated approval card composited over it. `chat.webp` is existing website product artwork: its result is an example task, not fresh live verification. Character portraits and provider cards are motion graphics.

Keynote clips are real recordings from the documented signed application capture of 2026-10-14, using Claude Code and Kokoro. The original requested questions were synthetic speech and clicks were synthetic input. This edit replaces source audio with music. Raw time ranges and checksums are in `public/launch/provenance.json`; source session notes are in `clip-a/README.md`. Only excerpts are shown. The original walkthrough had a repeated step outside these excerpts; this film does not establish an uninterrupted successful run.

Visual-answer clips are existing product recordings already condensed/sped up. This edit plays the board at 1.5× from 0.8s, camera at 1.3× from 2.0s, and biryani at 1.3× from 2.0s. Video is digitally reframed for clarity. The first two seconds of the camera clip, which show unrelated notch snippets, are excluded. Recorded and illustrated scenes carry visible labels.

## Music

`public/launch/score.wav` is an original 128 BPM electronic instrumental synthesized for this film, with no external samples or speech. Recreate with `python3 scripts/launch-score.py`. 60.000s, 48 kHz stereo, 24-bit PCM; measured -14.9 LUFS, -2.2 dBTP. No third-party music attribution required. Final MP4 audio is AAC, 320 kbps.
