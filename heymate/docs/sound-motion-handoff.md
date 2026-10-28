# Handoff: micro-animations that match the UI sounds

Status 2026-10-14: sounds are done and installed. Motion is not started. This
doc is everything the next session needs to pair each sound with a matching
micro-animation, so a cue is felt as one event instead of "a beep plus some UI".

## What exists already

- **Sounds (approved v5):** 19 sounds generated clean-room by
  `heymate/scripts/generate_ui_sounds.py` and installed as Apple Lossless
  data sets in `HeyMate/Assets.xcassets/*.dataset`. Profile: an octave down, extra
  bass, wide stereo hall, soft attacks. Re-render with the script; never hand-edit the files.
- **Player:** `HeyMate/UISoundPlayer.swift`, with `UISoundPlayer.Sound` (19 cases).
  It skips a sound that's already playing (so a burst makes one cue), and plays
  only one of responseReady/messageReceived within 3 s.
- **Wired today:**

  | Sound | Where it fires |
  |---|---|
  | listenStart, responseReady | `CompanionManager.playUISoundForTransition` |
  | messageSent | typed send, `CompanionManager` (~line 3600) |
  | messageReceived | `appendAssistantMessage`, main-chat branch |
  | panelOpen / panelClose | `NotchCompanionController.performPresentSurface` / `collapseAndUnpin` (deliberate/pinned opens only, hover stays silent) |
  | jobStarted / jobNeedsYou / permissionAsk / surprised / jobDone | `UISoundPlayer.sound(for: AgentEvent)` via `handleAgentEvent` |
  | thumbsUp | `approveAgent`, `approveAgentPlan`, `approveStandingOrderProposal` |
  | jobClosed | `dismissAgentPlan` |
  | hatching | `createMate` (+Mates) |
  | levelDown | `deleteMate` success (+Mates) |

- **Not wired yet (have sounds, need a moment):** `question` (HeyMate asks a
  clarifying question back), `levelUp` (skill/connector added), `boot` (first
  launch / onboarding start), `homeReveal` (home first appears after onboarding).
- **Motion tokens:** `DS.Animation` in `DesignSystem.swift` (`buddySpring`
  0.42/0.78, `controlSpring` 0.28/0.72, `reducedMotionFade`). Notch frame
  animation: `NotchLayoutMath.expandDuration` 0.42 s, `collapseDuration` 0.30 s,
  curve `.swoosh`. Deployment target macOS 14.2, so `keyframeAnimator` and
  `phaseAnimator` are available.

## What ReferenceRenderer does (reference only)

We only looked at public bundle metadata (type names, resource list) and the bundled demo
videos; we didn't decompile anything. Copy nothing: no code, no assets, no sounds.
What their type names show about their motion system:

- **An actor with choreography:** `CompanionActorChoreography`, `CompanionActorMotionMode`, and a
  mascot drawn from shapes (`AgentCloudShape`, `AgentCloudEyeShape`,
  `AgentCloudSleepZShape`, `MateCloudLimbsShape`). The character itself
  reacts: eyes, limbs, sleep Zs.
- **Props that pop out of the character:** `MatePropSparkleShape`, `…StarShape`,
  `…PaperPlaneShape`, `…BoltShape`, `…ChartArrowShape`, `…OpenBookShape`. The
  takeaway: each event gets a small symbolic object (plane = sent, star = done,
  bolt = started) that springs out and fades.
- **Word-by-word text:** `CursorMessageBubbleWordRevealModifier`. Replies reveal
  word by word instead of all at once.
- **Entrances:** `HomeSpaceMagicalAppearModifier`, `HomeSpaceHomescreenEntranceModifier`,
  `HomeSpaceSurfaceFlightMotion`, `HomeSpaceSheetMotion(Values)`.
- **Attention:** `CornerGlowLayer` (screen-corner glow), `PermissionCoachMotionStyle`,
  `PermissionRequestTransition`.
- **Tapback:** `CodexAgentTapback`, an iMessage-style reaction badge on approve.
- **From the spatial demo video:** when pointing, the cursor draws a soft curved
  trail toward the target, with a tiny waveform tag beside the cursor.

The principle to take from all this: **every sound has a visible "thing" that moves on the same beat.**

## Rules for HeyMate's version

1. **One cue, one call.** Add `HeyMateCue` (or extend `UISoundPlayer`) so call
   sites fire `cue(.jobDone)`. That one call plays the sound *and* publishes a
   cue event (for example `@Published var lastCue: (Sound, UUID)` on
   `CompanionManager`) that views react to. Don't let sound and motion be
   triggered separately; they'll drift.
2. **Start together, accent on the peak.** Motion starts at t=0 with the sound,
   and its biggest moment (overshoot, pop, flash) lands on the sound's peak (table below).
3. **Matte design.** Follow the matte black/white direction: DS tokens only,
   no purple, no nebula, no rainbow confetti. Sparkles are white/neutral and small.
4. **Reduce Motion.** Under `accessibilityReduceMotion`, every cue becomes
   `DS.Animation.reducedMotionFade` (opacity only). Sounds still play.
5. **Silent mode.** If sounds are off, the motion still plays. Motion isn't
   gated by the sound preference.
6. **Small.** These are *micro* animations: 4–12 pt movement, 0.92–1.08 scale,
   usually under 600 ms. Hatching is the only showpiece.

## Per-sound spec

Peak = loudest moment, measured from the rendered files. Audible = when it
drops below about −30 dB.

| Sound | Peak / audible | Sound gesture | Motion to pair (suggested) |
|---|---|---|---|
| listenStart | 71 / 599 ms | two-note rising pluck | Notch pill: mic dot scales 0.6→1.08→1 (controlSpring), waveform bars rise in, left to right, 30 ms apart |
| responseReady | 112 / 765 ms | warm fifth | BuddyMark: a soft "breath" (scale 1→1.05→1, 400 ms) and the caption fades in with the first word on the peak |
| panelOpen | 15 / 509 ms | low thump + rising pluck | Already a frame morph (0.42 s). Add: content fades up 6 pt with buddySpring, starting 60 ms in, so the thump reads as the "landing" |
| panelClose | 11 / 604 ms | tap with echoes | Existing 0.30 s collapse; content dims 1→0 in the first 120 ms (the tap), then the pill glows faintly in time with the echo (2 tiny opacity pulses 130 ms apart) |
| messageSent | 135 / 478 ms | upward whoosh-pluck | Sent bubble: slides up 8 pt + scale 0.96→1 and settles on the peak; a small paper-plane glyph flies up-right 12 pt and fades (prop idea) |
| messageReceived | 120 / 548 ms | two bright notes + echo | Reply bubble: pops in with scale 0.94→1.02→1, landing on the second note (~75 ms), then words reveal at ~35 ms per word |
| question | 202 / 787 ms | leap up a fifth | Buddy tilts 6° and a "?" pops above it on the second note (~90 ms) |
| permissionAsk | 194 / 814 ms | held hum, vibrato | Permission card: gentle 2-cycle glow pulse in time with the vibrato (≈5.5 Hz is too fast — use 2 slow pulses over 800 ms); approve button lifts 2 pt |
| surprised | 81 / 525 ms | dip then pop | Buddy squash (scaleY 0.92) for 60 ms, then stretch-pop (scaleY 1.08) on the peak, plus a small horizontal shake of the failing row (±3 pt, 2 cycles) |
| thumbsUp | 182 / 529 ms | note + octave | Tapback badge (👍-style glyph, neutral) springs out from the approve button's corner: scale 0→1.15 on the first note, 1.0 on the octave |
| jobStarted | 47 / 407 ms | rising sweep over thump | Job row/activity: slides in from below 10 pt, a progress shimmer starts its first sweep in time with the rising sweep |
| jobNeedsYou | 704 / 1081 ms | two-tone call, twice | Notch activity dot: two pulses that match the two calls (0 ms and ~500 ms), and the second one stays lit until handled |
| jobDone | 209 / 1190 ms | rising fourth, rings | Checkmark draws on (trim 0→1 over 200 ms, finishing on the peak), then a single soft ring expands and fades over the tail |
| jobClosed | 62 / 1167 ms | one deep long tone | Job card scales to 0.96 and fades over 350 ms; a slow fade fits the long tone |
| levelUp | 266 / 682 ms | chirp → low thump | Badge/icon hops up 6 pt on the chirp and lands with a squash on the thump (~180 ms) |
| levelDown | 70 / 559 ms | long falling slide | Removed item slides down 10 pt + fades over 500 ms, following the slide |
| boot | 762 / 1384 ms | low pulses stepping up, then lift | Logo/BuddyMark: 4 tiny brightness steps matching the pulses (0, 160, 360, 520 ms), then a full reveal on the lift (~740 ms) |
| homeReveal | 392 / 1130 ms | airy rising arpeggio + sparkles | Home tiles stagger in 80 ms apart (3 notes), with 3–5 tiny white sparkles twinkling over the top tile on the tail |
| hatching | 1624 / 3544 ms (5.5 s file) | rumble builds, cracks at 1.6 s and 2.1 s, burst at 2.55–2.8 s | Showpiece. New mate's face sits as an "egg" that wobbles with the rumble (rotation ±2°→±5° growing), cracks appear at 1.6 s and 2.1 s, it splits at 2.55 s and the face pops (scale 0.6→1.1→1) at 2.8 s with sparkles. Skip it if the mate was created in the background (`opensChat == false`)? Decide with the user. |

## Suggested implementation order

1. `HeyMateCue` plumbing + Reduce Motion handling + unit test that every
   `Sound` has a motion spec (or an explicit "none").
2. The high-frequency ones first: messageSent, messageReceived (with word reveal), panelOpen/Close, thumbsUp.
3. Jobs: jobStarted, jobNeedsYou, jobDone, jobClosed, permissionAsk, surprised.
4. The four unwired moments (question, levelUp, boot, homeReveal); each needs a product
   decision on *when* it fires.
5. Hatching last, since it's the biggest.

## Checks before calling it done

- For anything you run, use `heymate/script/build_and_run.sh --verify`: it keeps
  the installed certificate and compatible designated requirements, then installs
  one `/Applications/HeyMate.app`. Check-only: `--check`. A signer migration
  still needs macOS approval; see [local development](local-development.md).
  Ad-hoc/unsigned scratch builds are for compile/test only, not daily installs.
- Tests run in the real app host. Use `HeyMateDataDirectory` paths and confirm
  user prefs are untouched afterwards.
- Visual verification: computer-use can't drive HeyMate; use screencapture and
  the CGEvent pid helpers (see project memory).
- Record a short screen capture of each cue with sound on and compare the sound peak with the motion peak.
- The checkout is shared with other sessions: stage by explicit path, never `git add -A`.
