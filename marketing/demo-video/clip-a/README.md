# HeyMate real-capture demos (Clip A and friends)

Real screen recordings of HeyMate answering spoken questions about what's on screen and pointing at the answer. Each is edited with eased zooms that follow HeyMate's pointer, short callouts beside the pointer, the ⌃⌥ keycaps, an opening line ("Ask about anything on your screen.") and an end card.

Recorded on 2026-10-14 with HeyMate 1.0 from /Applications (the signed dev build), on a MacBook Pro's built-in display, macOS 27.0.1. HeyMate's brain was the signed-in Claude Code CLI, and its voice was its on-device Kokoro voice.

## Exports (`out/`)

| Demo | 16:9 1920×1080 | 1:1 1080×1080 | 9:16 1080×1920 |
|---|---|---|---|
| **Planets**: one question, one point (25 s) | `heymate-planets-wide.mp4` | `heymate-planets-square.mp4` | `heymate-planets-vertical.mp4` |
| **Keynote fly-in**: four steps (60 s) | `heymate-keynote-wide.mp4` | `heymate-keynote-square.mp4` | `heymate-keynote-vertical.mp4` |
| **Sizzle**: both, back to back (45 s) | `heymate-sizzle-wide.mp4` | | `heymate-sizzle-vertical.mp4` |

- README GIF: `heymate-keynote-steps-800w.gif`. It is 800 px wide, silent and 9.7 s long, and shows steps 3 and 4 of the Keynote walkthrough and the title flying in.
- Stills: `still-planets.png`, `still-keynote.png`.

All of them are 60 fps, H.264 + AAC. No music.

## The demos

### Planets: Wikipedia, "Solar System" infobox

- **Asked:** "Hmm, okay… which planet in this picture is actually the biggest?"
- **HeyMate said:** "Jupiter is the biggest planet in the picture. It's the large striped one just to the right of Saturn."
- **Pointed at:** Jupiter in the infobox image, with its own "here it is!" label. It landed first time.
- **Scene:** en.wikipedia.org/wiki/Solar_System in a Chrome Guest window at 125% zoom, so no bookmarks, profile or history were on screen.
- **Edits:**
  - The thinking wait (7.4 s) plays at 3×, labelled.
  - The 16:9 cut zooms to 1.75× on Jupiter as the pointer lands.

### Keynote: "how do I make this title fly in?"

The scene is a new Keynote deck (Basic Black) titled "Our Trip to the Moon", with made-up names. It was closed without saving.

HeyMate guided one step per turn. After each step I clicked what it pointed at, using a synthetic mouse click, and asked the next question.

| # | Asked | HeyMate said (verbatim) | Pointed at |
|---|---|---|---|
| 1 | "Okay, so… how do I make this title fly in?" | "The title hasn't been selected yet, so click Our Trip to the Moon on the slide." | The title |
| 2 | "Okay, done… where do I click next?" | "Look at you, the title's selected. Click Animate in the top right to open its animation controls." | The Animate tab |
| 3 | "Okay, done… where do I click next?" | "Look at you, Animate is open. Click Add an Effect in the right panel to choose the title's fly-in animation." | Add an Effect |
| — | "Okay, done… where do I click next?" | "Click Add an Effect in the right panel…" **This turn is cut.** HeyMate repeated step 3 while the effect list was already open. An on-screen chip says "Cut: one repeated step". | Add an Effect, again |
| 4 | "Ooh, okay, there's a whole list… which one makes it fly in?" | "Choose Fly In in the Build In list on the right. It's below Fade and Scale in the Appear and Move section." | Fly In |

Clicking Fly In made Keynote preview the animation, and the title flies in on screen.

HeyMate then continued the walkthrough on its own: "…That's the last step. Your title is ready to fly in when you play the slide." That last line is in the raw take but not in the cut.

The waits play at 4× to 8×. These are thinking time and the gaps while I clicked and asked, and each one is labelled on screen. The sizzle uses 16× for the same gaps. Answers and the first question always play at 1×.

## What is real and what was added

**Real, from HeyMate and not edited:**
- The screen recordings, captured with ScreenCaptureKit with system audio. The uncut takes are in `raw/`, which git ignores.
- HeyMate's spoken answers and its voice. The answer text above is ElevenLabs speech-to-text of the recorded audio, checked against HeyMate's own session summary where it saved one.
- HeyMate's pointer flights, the spots it landed on, and its own pointer labels ("here it is!", "this one!").
- HeyMate's notch states.
- HeyMate heard every question through the Mac's microphone, from the speakers.

**Added or staged:**
- **The questions are text-to-speech**, using the ElevenLabs premade voice "Jessica" (eleven_v3). They are not a person.
  - The requested "Jessa" voice and the "Brittney" fallback both returned HTTP 402 on the free plan, because library voices need a paid plan.
  - The questions were played through the speakers while ⌃⌥ was held, using synthetic key events.
- The mouse clicks in Keynote were synthetic. Each one landed on the control HeyMate had just pointed at.
- **Overlays:**
  - Callouts beside the pointer, such as "Step 2: the Animate tab" and "Jupiter. Not even close 🪐".
  - The "Asked" chips with the question text.
  - The ⌃⌥ keycap overlay, timed to the real key events.
  - The "Real screen recording" tag, the speed labels, the opening line and the end card.
- **Camera:** the zooms and the 1:1 and 9:16 reframes are digital crops of the same take.
- **Cuts:** speed-ups, labelled, and the one repeated Keynote turn, labelled.

Suggested post line: *Real screen recording. The questions are a text-to-speech voice; the answers, voice and pointing are HeyMate's own. Waits are sped up and labelled.*

## Takes that failed the check (not used)

| Take | Why |
|---|---|
| Space Jam roast ×4 | Take 1 didn't point at all. Take 2's pointer said "click this" on empty stars. Takes 3 and 4 ("point at the worst thing", "show me the ugliest part") said "the star field" but pointed at the logo and the Jam Central label. Dropped after the two pointing-phrased tries. |
| Pages word count ×3 | Real two-step pointing (View menu, then Show Word Count). But the second pointer landed on the line between Show Word Count and Show Ruler, and the answer said Show Word Count is "just below Show Ruler", which is wrong. One take also started with word count already on. |
| "Me vs. Googling it" | Not made. The Googling side was quick: Google's AI Overview answers Pages word count instantly. HeyMate's walkthrough takes about 40 s to reach its second point, because it speaks each step in full. An honest side-by-side timer would not favour HeyMate. Also, HeyMate excludes System Settings from screen capture by design, so it can't point at a setting there. |
| GeoGuessr | Not made. In a Chrome Guest window the Maps "pano" links only opened user-contributed photospheres (unblurred faces, other people's photos, place names in the tab title). Official Street View showed "No Street View imagery available". |
| Mate faces and floating job cards | Not attempted in this pass. |

## Editing and rendering

This folder resolves Remotion from `../node_modules`, so run `npm install` once in `marketing/demo-video` and nothing here.

- `src/demos.ts` has every take's timings, callouts, camera keyframes and cuts, all in raw-recording seconds.
- `src/lib/CutVideo.tsx` maps them through each cut. Changing a trim keeps the overlays in sync.
- `public/<demo>.mp4` is the raw take, cropped to the top 16:9 of the screen (3024×1700 → 2560×1440). Git ignores it.

```sh
cd marketing/demo-video/clip-a
npx remotion studio
./render-all.sh
```

The 9:16 crops are tight: at rest the Keynote vertical shows only part of the slide title, and at the right screen edge HeyMate's own pointer label can be clipped.
