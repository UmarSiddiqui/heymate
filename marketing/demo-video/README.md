# HeyMate demo video

A 38-second motion-graphic demo of HeyMate, built with [Remotion](https://www.remotion.dev). Every UI surface is a React recreation of the real app (matte surfaces, Avenir Next, Signal-blue accent, real copy), so it all animates smoothly and stays crisp at any size. The only bitmap assets are HeyMate's own app icon and mate faces, copied from the app.

This folder is self-contained. It doesn't touch the Xcode project or the website.

| Output | Composition | Size | FPS |
|---|---|---|---|
| `out/heymate-demo-1080p60.mp4` | `HeyMateDemo` | 1920×1080 | 60 |
| `out/heymate-demo-vertical-1080x1920.mp4` | `HeyMateDemoVertical` | 1080×1920 | 60 |

## Setup

Requires Node 18 or newer and macOS. The video uses the system fonts Avenir Next and SF Mono, so render on a Mac or the fonts will fall back.

```bash
cd marketing/demo-video
npm install
```

## Preview

```bash
npx remotion studio
```

This opens the Studio in your browser. The sidebar lists the full video in both orientations, plus every scene on its own under **Scenes-Landscape** and **Scenes-Vertical**, so you can scrub a single scene while you tweak it. Edits hot-reload.

## Render

```bash
npm run render            # landscape MP4 → out/heymate-demo-1080p60.mp4
npm run render:vertical   # vertical MP4  → out/heymate-demo-vertical-1080x1920.mp4
npm run render:all        # both
npm run stills            # review PNGs of every scene → out/stills/
```

`node scripts/frames.mjs HeyMateDemo 600 1200` renders specific frames of the full cut into `out/frames/`.

### Web clips

The **Web-Clips** folder in the Studio has UI-only versions of the notch, vision, agents and Mates scenes (1280×820, no callout text, fading out at the end so they loop). The landing page and the GitHub README use them:

```bash
npx remotion render clip-vision out/web/clip-vision.mp4 --crf=24
npx remotion render clip-agents out/web/clip-agents.mp4 --crf=24
```

Copy the results into `website/assets/video/`. The README GIFs in `docs/media/` are made from the same clips with ffmpeg (720 px wide, 15 fps).

Encoding settings (H.264, CRF 16, yuv420p) live in `remotion.config.ts`.

## Editing

All text, colors, fonts, timing and springs live in **`src/config.ts`**.

- **Change copy:** edit `COPY`. Titles accept `\n` for a deliberate line break.
- **Change scene length:** edit `SCENE_SECONDS`. The total duration updates automatically. Inside a scene, the beat times (for example `APPROVE_AT` in `AgentsScene.tsx` or `PRESS_AT` in `VisionScene.tsx`) are constants at the top of each file.
- **Change the transition:** `TRANSITION_FRAMES` sets the cross-fade length (60 frames = 1 s).
- **Reorder or remove scenes:** edit the `SCENES` array in `src/HeyMateDemo.tsx`.
- **Change colors:** edit `COLORS`. These mirror `DesignSystem.swift` in dark mode. To try another buddy color, change `accent`, `accentText` and `userBubble` (for example Iris `#8B7CFF`).
- **Change motion feel:** edit `SPRINGS`. `buddy` is the app's own `buddySpring` (response 0.42, damping 0.78) converted to Remotion's spring parameters.

### Files

```
src/
  config.ts              brand tokens, timing, copy, music slot
  HeyMateDemo.tsx        scene order + cross-fades + music
  Root.tsx               compositions (landscape, vertical, per-scene)
  scenes/
    HookScene.tsx        1. "Stuck on an error?"
    LogoScene.tsx        2. icon + wordmark reveal
    NotchScene.tsx       3. notch opens to Home, then Apps
    VisionScene.tsx      4. push-to-talk, cursor flies to the bug, answers
    AgentsScene.tsx      5. plan → approve → run → done, with undo
    MatesScene.tsx       6. mates, memory and a daily routine
    CloseScene.tsx       7. "Say hey." + Download CTA
  components/
    UI.tsx               FeatureLayout, MacScreen, NotchShell, MacWindow, Keycap…
    NotchCards.tsx       expanded-notch Home and Apps pages
    Icons.tsx            line icons + cursors drawn for this video
    motion.ts            spring/ease helpers and orientation-aware layout
public/
  icon.png               HeyMate app icon (from Assets.xcassets)
  faces/                 mate faces (from the app)
  music/                 ← drop your track here
```

### Vertical layout

Feature scenes use `FeatureLayout`. In landscape, the callout sits on the left and the UI on the right. In vertical, the callout sits on top and the UI is scaled to fill the width. For vertical, each scene can pass `verticalFocus` (a rectangle in stage pixels) to crop in on the part of the UI that matters. Anything outside that rectangle may be cut off at the frame edges.

## Music

The video renders silent. To add your own licensed track:

1. Put the file in `public/music/`, for example `public/music/heymate-theme.mp3`.
2. In `src/config.ts`, set `MUSIC_SRC = 'music/heymate-theme.mp3'`.
3. Optionally adjust `MUSIC_VOLUME` and `MUSIC_FADE_SECONDS`. The track fades in and out automatically and is trimmed to the video length.

Beats you might want to cut to (landscape and vertical share the same timing):

| Time | Moment |
|---|---|
| 0:00 | Hook |
| 0:04.2 | Logo reveal |
| 0:07.4 | Notch |
| 0:13.1 | Vision |
| 0:19.8 | Agents |
| 0:27.0 | Mates |
| 0:33.2 | Close |
