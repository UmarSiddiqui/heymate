# HeyMate demo video

## Retired screenshot assets — 2026-11-01

Old HeyMate UI screenshots, including `public/vision-still.jpg`,
`public/hooks/mates.webp`, and `public/launch/home.webp` / `chat.webp`, were
removed at the user's request. Earlier video compositions that reference
these files need fresh captures before rendering. Do not restore old images
or extract replacements from earlier videos or preview frames. Current
product artwork and the fresh 2026-11-01 subway-banner capture are preserved.

## Launch ad (42 seconds) — 2026-11-01

`LaunchAd` / `LaunchAdVertical`, entry `src/launch-ad/index.tsx`, render with `node scripts/launch-ad-render.mjs film`. A bright, music-led ad in four beats, modelled on the structure of a reference launch reel: kinetic intro with inline glyphs, problem with an orbiting collage, a ring-to-logo reveal, four use cases, and a clouds CTA. Room photos and clouds are Google Flow (Nano Banana) images in `public/launch-ad/`. Real HeyMate captures are composited onto their screens with a homography (`quadMatrix`). Every composite is labelled "Real HeyMate capture, composited · AI-generated room/scene".

## Ten minutes (37 seconds) — 2026-11-01

`MeetingStory` / `MeetingStoryVertical`, entry `src/meeting-story/index.tsx`. Priya crams vector databases before an AI meeting. Her scenes are Flow stills labelled as a dramatization; the listening notch over her speaking shot is illustrated. The drawing is a real HeyMate answer recorded on 2026-11-01 by POSTing `/ask` to the local control server (127.0.0.1, port in `heymate.log`), so no typing appears. Record with ffmpeg AVFoundation (`-f avfoundation -i "4:none"`): `screencapture -v` makes HeyMate's overlays step aside (`SystemOverlayYield`) and the drawing only appears at the end. VO: `scripts/meeting-story-vo.mjs` (Jessica, eleven_v3).

## Biryani night (34 seconds) — 2026-11-01

`BiryaniStory` / `BiryaniStoryVertical`, 30 fps, standalone entry `src/biryani-story/index.tsx`. A first-person story: "Priya" and her dinner are AI-generated (Google Flow: Nano Banana character reference, three Omni 1.1 Flash 720p clips and one 2K still), and every one of those frames carries **Dramatization · AI-generated scene**. Don't present her as a real customer. The HeyMate parts are the real 2026-10-31 biryani capture, labelled with their speed-up. VO: ElevenLabs premade "Jessica" on `eleven_v3` (`scripts/biryani-story-vo.mjs`; library voices need a paid API plan). Captions are word-synced from the VO alignment.

```sh
ELEVENLABS_API_KEY=... node scripts/biryani-story-vo.mjs
node scripts/biryani-story-render.mjs film
```

## Ask. It draws. (30 seconds) — 2026-11-01

`AskDraws` (1920×1080) and `AskDrawsVertical` (1080×1920), 30 fps, from the standalone entry `src/askdraws/index.tsx` (not in Root.tsx). Opening: one Google Flow (Veo 3.1 Lite) 720p shot of a laptop notch, `public/askdraws/opener.mp4`. Product scenes are real HeyMate screen recordings from 2026-10-31 (biryani plan, Raspberry Pi 2D diagram, 3D Pi), sped up and labelled on screen. The Tide mate is a Blender character built from the brand blob by `scripts/mate-character.py` (300 transparent frames in `public/askdraws/mate/`). VO: ElevenLabs saved voice, `scripts/askdraws-vo.mjs` (pass `ELEVENLABS_API_KEY` via env; never write it to a file). Music: the original synthesized `public/launch/score.wav`.

```sh
ELEVENLABS_API_KEY=... node scripts/askdraws-vo.mjs        # VO + word timings
/Applications/Blender.app/Contents/MacOS/Blender -b -P scripts/mate-character.py -- <out_dir>   # mate frames (resumes after a crash)
node scripts/askdraws-render.mjs film                        # out/askdraws/AskDraws*.mp4
```

Final deliverables are loudness-normalized to -14 LUFS: `out/askdraws/HeyMate-AskItDraws-16x9.mp4` and `-9x16.mp4`.

## Meet HeyMate (41 seconds)

`MeetHeyMate` (1920×1080) and `MeetHeyMateVertical` (1080×1920), 30 fps, in the `Meet-HeyMate` Studio folder. A fun, teaching-first tour: your AI is stuck in a tab → the buddy pops out of the notch → it teaches a spreadsheet chart step by step and waits while you do it → quick "ask about anything" examples → bring your own AI (Claude via Claude Code, ChatGPT via Codex, OpenCode, plus your own API key, local models, or Apple Intelligence) → "a more fun way to use them" → Say hey. UI is recreated and the UI scenes carry a small **Illustrated UI** tag. Music: Show Me by Peyruis (CC BY 3.0, credit below).

Source: `src/MeetHeyMate.tsx` (scene list and lengths) and `src/meet/`. Every scene is also registered on its own as `meet-<id>` and `meet-<id>-vertical`.

```sh
npx remotion render MeetHeyMate out/heymate-meet-1920x1080.mp4 --codec=h264 --crf=18 --pixel-format=yuv420p --audio-codec=aac
npx remotion render MeetHeyMateVertical out/heymate-meet-1080x1920.mp4 --codec=h264 --crf=18 --pixel-format=yuv420p --audio-codec=aac
```

## Pixel Coach product demo (42 seconds)

`PixelCoachDemo` (1920×1080) and `PixelCoachDemoVertical` (1080×1920) are new 30 fps animated product demos. Seven separately editable scenes introduce a locally created Photopea tutor, its distinct name/job and saved practice note, then an example background-removal lesson where the user performs each action. Every frame says **Recreated product demo**. Earlier concept and tour compositions remain unchanged.

The interface and chat are simplified recreations, not recorded app interactions. Local mate creation, identity, and saved-note behavior were checked separately. The source practice logo is original owned artwork; `public/pixel-coach/transparent-export.png` is its actual manual Photopea export, checked for 1000×800 dimensions and transparent corners. The edit follows Photopea's [documented background-removal workflow](https://www.photopea.com/tuts/remove-background-from-photo/): Magic Wand, select the white area, Edit → Clear, File → Export as → PNG. This animation does **not** establish that HeyMate's live screen-guidance path completed the lesson. Release validation remains separate.

Source: `src/PixelCoachDemo.tsx` and `src/pixel-coach/`. Preview at `http://localhost:3001/PixelCoachDemo` when the existing Studio server is running, or start `npx remotion studio --no-open`. The film works without sound; all instructions are visible. Its quiet instrumental score is generated from original synthesised tones by `scripts/pixel-coach-score.mjs`; it uses no external samples, inherited soundtrack, recorded app audio, or synthetic speech.

```sh
npm run typecheck
npx remotion render PixelCoachDemo out/heymate-pixel-coach-demo-1920x1080.mp4 --codec=h264 --crf=18 --pixel-format=yuv420p --audio-codec=aac
npx remotion render PixelCoachDemoVertical out/heymate-pixel-coach-demo-1080x1920.mp4 --codec=h264 --crf=18 --pixel-format=yuv420p --audio-codec=aac
```

## Teaching concept (24 seconds)

The `Teaching-Concept` folder in Studio contains `TeachingFirst` (1920×1080) and `TeachingFirstVertical` (1080×1920), both 30 fps. This is a new, separate, silent concept film about learning desktop apps and websites step by step and creating helpers for specific jobs. Every frame is labeled **Illustrated concept** and **not a screen recording**. It does not establish that a real task completed or that mate identity passed live testing.

Preview with `npx remotion studio --no-open`, then select either composition. Four individual scenes are registered beside the full edits. Source lives in `src/TeachingFirst.tsx` and `src/teaching/`. It uses the existing app icon and mate faces; no new media dependency or third-party soundtrack is needed.

Render the current software-teaching concepts from this directory:

```sh
npx remotion render TeachingFirst out/heymate-software-teaching-concept-1920x1080.mp4 --codec=h264 --crf=18 --pixel-format=yuv420p
npx remotion render TeachingFirstVertical out/heymate-software-teaching-concept-1080x1920.mp4 --codec=h264 --crf=18 --pixel-format=yuv420p
```

Keep the original demo below until a verified replacement is ready. For a real capture, follow `marketing/LAUNCH.md` (from the repository root): preserve the uncut recording, provider/version, errors, and any speed-change labels. Do not remove the concept label and present this animation as captured product behavior.

## Teaching share card

`og-teaching` is a 1200×630 static brand card in the `Share-Cards` folder. It uses the existing icon and mate faces with the teaching headline, without recreating app UI or implying a completed task. Source: `src/TeachingShareCard.tsx`.

Reproduce the website asset from this directory:

```sh
npx remotion still og-teaching ../../website/assets/img/og-teaching-v2.png --image-format=png
```

## Original illustrated tour

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
    HookScene.tsx        1. "Why is my Mac so slow?"
    LogoScene.tsx        2. icon + wordmark reveal
    NotchScene.tsx       3. notch opens to Home, then Apps
    VisionScene.tsx      4. push-to-talk, cursor flies to the CPU hog, answers
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

The video uses **Show Me by Peyruis** (`public/music/show-me-by-peyruis.mp3`), licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). That license requires credit wherever the video is published; paste this into descriptions and posts:

```
Music: Show Me by Peyruis https://soundcloud.com/peyruis
License: Creative Commons — Attribution 3.0 Unported — CC BY 3.0
Free Download / Stream: https://links.al/zfR
Music promoted by Audio Library: https://links.al/youtube
```

To use a different track:

1. Put a file you have the rights to in `public/music/`, for example `public/music/heymate-theme.mp3`.
2. In `src/config.ts`, set `MUSIC_SRC = 'music/heymate-theme.mp3'` (or `null` for a silent render).
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
