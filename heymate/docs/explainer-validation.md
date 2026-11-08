# Talk drawings and 3D explanations

Verified on 2026-11-07: signed `/Applications/HeyMate.app` install, 27 nested
signatures, 122 JavaScript tests, compiler/speech probes, native Metal GPU checks,
and live Talk acceptance. The live run rendered a real screen highlight and a
three-beat moving piston. Paint acknowledgements arrived 109–171 ms after
playback started. A follow-up crossed the original expiry deadline and changed
the existing rod without replacing geometry or stopping animation. Clearing a
streaming reply stopped speech and kept later chunks dismissed.

Live evidence: `../../output/playwright/live-talk-confirmed-evidence.json`.
Talk requests entered through the local `/ask` endpoint with `asHeyMateTalk`;
this exercises the real model, capture, speech playback and native renderer,
but does not test microphone recognition. Screen interaction during model
generation was also observed to invalidate stale annotations as intended.

## Character quality regression

The Harry Potter request exposed two concrete geometry/composition problems:
small toruses inherited a fixed 0.2 tube radius, and figure creation forced
`spin:0` to 0.5. Glasses with radius 0.11 became oversized solids; an intended
front view kept rotating and hiding the face. Torus tube defaults now scale
with major radius, and a stationary or slow camera is respected. Explicit tube
sizes remain authoritative. Both regressions have tests; all 124 JavaScript
tests pass, and native Metal checks pass.

The drawing contract now documents ring orientation and thickness, skin tint,
hair caps, visible character features, connected joints and a seated riding pose.
A fresh real Talk request generated 36 parts over three spoken beats, including
round glasses, scar, hair, scarf and bent limbs. The user supplied a fresh
screenshot confirming the recognisable result. The exact generated scene was
then replayed through the local diagnostic route after the camera fix; native
mesh count remained 36 and the chosen camera angle stayed fixed. Evidence:
`../../output/playwright/live-harry-evidence.json` and
`../../output/playwright/harry-steady-view-evidence.json`.

Talk accepts `heymate` fenced JSON lines. Each complete line contains one spoken
beat and an ordered list of drawing operations. `ExplanationProgram` validates
the data and compiles only allowlisted operations into the existing drawing
engine. Talk does not execute model-authored JavaScript. Legacy source remains
available to local renderer diagnostics.

The existing SVG overlay and native Metal renderer share retained IDs. Named 2D
marks and 3D parts can be edited without rebuilding the scene. Declarative
`sliderCrank` animation keeps the connecting rod attached to its pins. Figure
orbit and zoom use bounded nonactivating input panels; the full-display overlay
passes background clicks through.

Screen coordinates are transformed from capture pixels into a stable display
canvas. Focused-window and full-display captures can therefore alternate without
discarding existing figure handles. Screen changes invalidate pointing marks;
explanation figures remain. The model receives a compact live scene inventory
and native presentation receipt because screenshots exclude our overlay.

Scenes are held while a follow-up turn is running. This fixes the case where a
60-second expiry removed `spacecat` while the model was generating additions to
it. The regression uses the original generated base and follow-up: seven parts
become 27 while the original head geometry and figure identity survive.

Speech waits for the overlay to load and queued drawing data to reach WebKit.
Each beat releases its visuals when TTS reports playback started. Diagnostics
record playback, visual-paint, native-mesh and speech-end timestamps. These
measure software timing, not microphone-recorded acoustic output.

## Checks

```sh
node --test scripts/*tests.mjs
bash scripts/verify_explanation_program.sh
bash scripts/verify_native_metal.sh
```

For a live installed-app check, turn Silent Mode off and keep a known control
visible without scrolling or changing windows:

```sh
python3 scripts/live_talk_explainer_check.py --talk --expiry-regression \
  --target 'visible control description' --output build/live-talk-evidence.json
```

This sends real requests through Talk's model, screenshot, voice and native
renderer path. It checks three spoken beats, a screen highlight, a moving
mechanism, WindowServer input routing, a follow-up across the old expiry
deadline, retained geometry, and dismissal during model streaming. It never
injects drawing source. Local app installs must still use
`script/build_and_run.sh --verify` as documented in `local-development.md`.

Retina and negative display offsets have coordinate tests. Physical Sidecar
acceptance is recorded below. HeyClicky's private renderer and speech
implementation remain unknown.

## Physical microphone check — 2026-11-07

Passed using the user's held Ctrl + Option Talk shortcut and physical MacBook
microphone, without injecting text through `/ask`. On-device recognition heard
“draw a blue sphere beside a yellow box in three D.” Microphone capture began
at 14:53:02 Perth time; key release was 14:53:06.731 and the final transcript
reached Talk at 14:53:06.855, 124 ms later.

The resulting native scene contained a blue sphere (`2878e8`) and yellow box
(`f5ce39`), both visually checked in the installed app. Its visual beat appeared
116 ms after speech playback started. The response itself was slow: playback
began at 14:55:00.417, about 114 seconds after transcription completed.

Evidence: `../../output/playwright/microphone-hardware-evidence.json`.

At the microphone check, only the built-in Retina screen was connected
(1512 × 982 points, 3024 × 1964 pixels). The user subsequently connected an
iPad; that later physical test is recorded below.

## Physical Sidecar check — 2026-11-07

Passed with both displays connected: built-in Retina at global frame
`[0,0,1512,982]` and iPad Sidecar at `[-1087,180,1087,802]`, both scale 2.
ScreenCaptureKit captured both displays. Production coordinate conversion
mapped real capture corners and centres correctly, including the iPad's
negative x origin and the downscaled screenshot sizes.

A real Talk request captured the Blender window on iPad display 8, highlighted
a visible control and rendered labelled blue/yellow 3D parts. Native meshes
were presented on that display. WindowServer hit tests reached the bounded
input panel at `[-573,394,319,287]`; background input bypassed the full-display
overlay. Visual acknowledgements arrived 159 and 97 ms after playback started.
The user physically confirmed highlight alignment, drag orbit, scroll zoom and
a harmless click in Blender outside the figure all worked.

Visual inspection also exposed crossed automatic label leaders. Automatic
labels now choose the projected part's side, update during orbit and use a
centre dead band to avoid flicker; explicit side requests remain authoritative.
The regression failed before the fix and passed after it. All 125 JavaScript
tests pass. The signed install passed all 27 nested signature checks. A final
native render on the Mac screen visually confirmed blue/yellow labels beside
their matching shapes with uncrossed leaders; both displays remained connected.

Evidence: `../../output/playwright/sidecar-initial-evidence.json` and
`../../output/playwright/dual-display-coordinate-evidence.json`, plus
`../../output/playwright/label-layout-fixed-evidence.json`.

## Stage Manager — 2026-11-07

Tested with Stage Manager enabled by the user and both displays connected.
Controlled programs entered through `/explain` exercised the installed app's
actual overlay, speech, native Metal rendering and input panels; this was a
window-management test rather than a new model-generation test.

2D ink and native 3D rendered over the active group. Calculator remained
frontmost while the figure was opened, orbited and zoomed; yaw changed from 0
to -0.2 and zoom from 1 to 0.5. Full-display background input remained
click-through. A separate system dialog intercepted one early centre hit test;
the unobstructed probe subsequently passed its WindowServer input hit tests.

Switching from Calculator to Finder and back preserved the same two mesh IDs
and geometry UUIDs. Screen-anchored ink was invalidated on the group change,
while the explanation figure and bounded input panel remained available.
Clear removed the overlay and input windows. The temporary Calculator,
TextEdit and Applications test windows were closed, and Stage Manager remained
enabled. No production code changes were required for this tested flow.

Computer Use initially could not capture off-stage app thumbnails
(`SCStreamError -3811`). Bringing the apps onto stage through Finder restored
control; HeyMate's own two-display capture continued working. This tool
limitation was distinct from the overlay compatibility result.

Evidence: `../../output/playwright/stage-manager-switch-evidence.json`.
This covers ordinary app/group transitions and interactive overlays. It does
not certify every custom multi-window grouping, full-screen transition or
macOS display arrangement.
