# Companion behavior spec, from studying ReferenceRenderer

Historical 2026-10-14 behavior-only investigation. Later 2026-10-29 source ports are documented in [recovered-port-validation.md](recovered-port-validation.md) and [native-drawing-port.md](native-drawing-port.md). The original-code-only implementation policy below describes this earlier investigation; it does not describe the later recovered modules currently present in HeyMate.

Date: 2026-10-14. This document is a clean-room behavior spec. It records what a reference companion app (ReferenceRenderer 1.0.53) does and how fast it does it, written in our own words, so HeyMate can be designed against it. It contains no code, decompiled output, identifiers, string dumps or assets from that app. Everything HeyMate ships must be original: our own art, our own sounds, our own code.

Numbers below come from a static study of the shipped binary. They describe intended behavior, not measured runtime behavior. Where something wasn't recovered, it says so.

Status words in the tables:

- **Done**: HeyMate has equivalent behavior (the numbers may differ on purpose).
- **Partial**: some of it exists, or it exists with real gaps.
- **Not started**: nothing equivalent in HeyMate yet.
- **Won't port**: deliberately out of scope, with the reason given.

---

## 1. Character model

The reference app has two separate character systems.

1. **A sprite character** for the notch and for the spatial on-screen companion. It is driven by a state machine and plays frames from pixel-art sheets.
2. **Layered vector portraits** for larger surfaces (home window, cards). These are rigs of separate parts (body, head, hair, eyes, lids, cheeks, arms, wrists) that move independently with pointer gaze, blinks, breathing and click reactions.

HeyMate's current equivalent is closer to system 2: a vector face for the six colour mates (`MateLiveFace.swift`), whole-artwork pose motion for drawn packs (`MateArtworkMotionView.swift`), and static custom photos.

### 1.1 Sprite state machine

**Surfaces.** Each sprite state belongs to a surface: the compact notch strip, the free-floating spatial overlay, or the permission-guide overlay (a variant of the spatial one). A state can also be surface-agnostic. When a state is requested for a surface, the app walks an ordered list of fallback names for that state and takes the first one whose surface matches, or is unspecified. If nothing matches, it draws a static fallback image. Surfaces never fall back silently to each other.

**Sheets.** Two sprite sheets, both 16 columns wide:

| Sheet | Rows | Cell size (px) | Sheet size (px) |
|---|---:|---|---|
| Notch | 24 | 80 × 36 | 1280 × 864 |
| Spatial overlay | 31 | 96 × 96 | 1536 × 2976 |

Every row is one state and has 16 frames. The reduced-motion frame is frame 0 for every state. The cell for (row, frame) is cropped as x = frame × cell width, y = row × cell height. Frames are drawn with interpolation off, scaled to fit, and hidden from accessibility.

**State families** (55 rows in all; 56 logical states, one of which only exists as an alias):

| Family | What the states depict | Base FPS | Playback |
|---|---|---:|---|
| Rest | asleep, drowsy | 6 | loop |
| Waking | waking up, stretching | 14 | once |
| Idle | idle with blinks | 8 | loop |
| Voice | listening, thinking, speaking | 8 | loop |
| Agent pace | walking | 14 | loop |
| Agent pace | running | 16 | loop |
| Agent pace | sprinting | 18 | loop |
| Text | composing text | 14 | loop |
| Text | streaming text | 16 | loop |
| Tools | generic tool, web, image | 14 | loop |
| Files | reading a file, writing a file | 14 | loop |
| Agent work | reasoning, using a tool | 14 | loop |
| Hand-off | queued | 14 | loop |
| Hand-off | sent | 14 | once |
| Outcome | complete, failed | 14 | once |
| Spatial | fade in | 14 | once |
| Spatial | idle by cursor, following cursor left/right, detached idle/hover/listening | 14 | loop |
| Spatial | turning left/right | 14 | once |
| Spatial travel | short hop left/right | 14 | loop |
| Spatial travel | medium left/right | 16 | loop |
| Spatial travel | long left/right | 18 | loop |
| Spatial | landing | 14 | once |
| Spatial | pointing left/right/up/down | 14 | loop |
| Spatial | tap | 14 | once |
| Spatial | inspecting, speech bubble | 14 | loop |
| Spatial exits | returning home, fading away, navigation cancelled | 14 | once |
| Permission guide | pointing, dragging | 14 | loop |
| Permission guide | waiting | 8 | loop |
| Permission guide | success, recovery | 14 | once |

Totals: 2 states at 6 FPS, 5 at 8, 41 at 14, 4 at 16, 3 at 18; 15 play once and hold the last frame, 40 loop. The engine also supports ping-pong and hold-last modes, but the built-in character doesn't use them.

**Frame clock.** The frame is a function of time, not a counter.

- elapsed = max(0, now − time the current state started)
- effective FPS = max(1, base FPS × max(0.15, speed multiplier))
- tick = floor(elapsed × effective FPS)
- once/hold-last: frame = min(tick, frames − 1); loop: frame = tick mod frames; ping-pong over a period of 2 × frames − 2
- Reduce Motion: always the fixed reduced-motion frame.

The state-start time resets whenever the state or the surface changes, so every state starts from frame 0.

**Redraw cadence.** The view redraws at most every 1/24 s, or every 1 s when Reduce Motion is on. The timeline is never paused by visibility in the sprite path. (The portrait path does pause; see 1.3.) A user setting can turn the sprite off completely, which shows the static fallback.

### 1.2 Events and the reactions they cause

The host app sends the character high-level events. Each one maps to a state:

| Event | Character state |
|---|---|
| Docked, nothing happening | idle (falls back to idle-blink) |
| Voice listening / speaking | listening / speaking |
| Voice processing a phrase | classified from the phrase text (see below) |
| Composing / streaming a reply | text compose / text stream |
| Agent reasoning, complete, failed | reasoning, complete, failed |
| Agent active | walk / run / sprint by token throughput, or walk when overridden |
| Agent tool call | classified from the tool text |
| Hand-off queued / sent | hand-off queued / sent |
| Spatial travel (distance, direction) | short / medium / long, left or right; landing when overridden |
| Spatial point (direction) | point left / right / up / down |
| Permission guide point / drag / wait / success / recover | the matching guide state |

**Text classification** is a case-insensitive substring match where the first matching rule wins:

- For tool or progress text: words about reasoning or thinking → reasoning; reading or opening → file read; writing, editing, patching or file changes → file write; tools, commands, shells, terminals or "running" → tool use; otherwise no change.
- For task or content text: web or search → web tool; image, photo or screenshot → image tool; read/open → file read; write/edit/patch → file write; otherwise thinking. If a tool-dispatch path gets "thinking" back, it uses generic tool use instead.

**Agent run phases.**

- Starting: waking for the first 0.55 s, stretching until 1.05 s, then reasoning.
- Running: waking for the first 0.65 s, then a category-based state (reasoning, tool, file write, or text classification of the primary then secondary text). If nothing matches, the pace state from token speed is used.
- Finished: complete. Failed or anything else: failed.

**Pace from token throughput.**

- Δt = max(0.25 s, time since last sample).
- Use the change in output tokens if it's positive, otherwise the change in total tokens. Negative changes clamp to 0.
- sample = Δ / Δt. Smoothed = 0.65 × previous + 0.35 × sample. The first sample seeds the value directly.
- Under 8 tokens/s walks, 8 up to 28 runs, 28 and over sprints.

**Travel buckets.** A distance of 320 or less is short, more than 320 up to 900 is medium, and over 900 is long. Direction picks left or right.

**Pointing choreography.** Landing for the first 0.35 s. Then, if the narration mentions clicking or tapping, a single tap between 1.20 s and 1.70 s. After that, while there is narration, a repeating 3.4 s cycle: inspect when the phase is over 2.55 s, speech bubble when it's over 2.15 s, otherwise keep pointing.

### 1.3 Portrait rig (vector character)

**Motion gate.** A portrait animates only when all of these hold: motion is enabled, the view isn't mid-scroll, its window is visible and not occluded, it has no hidden ancestor, and its visible rect isn't empty. When the gate flips, the rig stops idle work, removes every running animation on every layer recursively, and reapplies the resting expression and gaze. Pointer-inside is cleared when inactive. Config updates are deduplicated, so re-sending the same configuration does nothing.

**Breathing.** Only runs while the gate is open and idle animation is on. Head and hair rise 1.4 pt; body rises 0.5 pt. Each cycle takes 2.5 s, ease-in-out, reverses, and repeats forever.

**Blink.** Takes 0.19 s. The lids squash to 2.5 % height between 26 % and 38 % of the blink, while the eyes and closed-lid layers cross-fade (eyes hidden from 16 % to 65 %). Every keyframe segment uses ease-in-ease-out. The rig blinks when the pointer enters it, unless an override is set.

**Gaze.** The pointer position is mapped into the portrait's own frame (aspect-fit, centred on a reference point). Its offset from centre is scaled by an ellipse (140 wide, 145 tall in rig units) and clamped to the unit disk. Updates smaller than 0.008 (L1 distance) are ignored. The eyes then translate up to 6 × 4.5 units (19.2 × 11.52 when the character is in a wide-eyed expression), and the cheeks and secondary parts follow at 0.9× horizontally. Moving toward the target takes 0.2 s ease-out; the secondary parts take 0.28 s ease-out. Gaze is ignored in one specific expression.

**Click reactions.** A double-click always gives the same playful reaction. A single click gives one of two reactions depending on the framing or on where the click lands vertically (the threshold is 250 rig units). The six reactions:

| Reaction | Motion | Track lengths |
|---|---|---|
| Wave | one arm raises and holds while the wrist wiggles; other variants nod the head | 1.45 s (1.15 s for the variant) |
| Wink | one eye cross-fades closed and opens again | 0.6 s |
| Boop | blinks, head squashes to 96 %, cheeks flush to 80 % | 0.38 s squash, 0.65 s flush |
| Giggle | blinks, small head shakes, arms bounce 2.5 then 1.5, wrists rock | 0.65 / 0.72 / 0.8 s |
| Celebrate | both arms go up about 1.6 rad, wrists flick, whole body hops 6 | 1.12 / 1.2 / 0.92 s |
| Dance | body and head sway ±0.06 rad, arms swing ±0.7, wrists ±0.2 | 1.35 / 1.42 s |

Before any reaction, arm and wrist rotation reset over 0.28 s. Every track starts from the pose currently on screen, not from a fixed first value, so interrupting a reaction never jumps. Tracks are keyed per property, so a new reaction replaces the same property's old track but leaves other properties running. Without explicit timings, keyframes are spaced evenly.

**Reaction delivery.** A reaction is identified by an event ID. A new ID is accepted for 2 s. If the portrait is inactive (hidden or occluded), the reaction waits. If the portrait becomes active within 2 s, the reaction plays once; after 2 s it is dropped. Re-sending the same ID does nothing and doesn't extend the deadline. Turning motion off drops any pending reaction.

**Accessibility.** Interactive portraits act as a button with help text inviting the user to look around and click to say hello. Non-interactive portraits act as images. Motion state is reflected in accessibility enablement.

**Packs.** Six portrait packs. Each has its own presets for hair, outfit, skin and colour; those presets weren't recovered.

### 1.4 Docking, flight, gaze and blink on the spatial companion

- The spatial companion follows the cursor, travels to targets, points, returns home and docks into the notch, with separate flight and settle phases. Trajectory and easing for the spatial companion weren't recovered.
- Window "surface flights" (for example, the home panel turning into a full window) are driven by the display refresh. progress = clamp((t − start) / duration, 0, 1); the caller applies easing, and completion fires at 1. Invalidating a flight stops the display link without calling completion.
- When the attached panel is promoted to a free window, the same live view moves into the new window, so state isn't rebuilt. The window's minimum content size is 720 × 520, and the window is dark and movable by its background.
- A meeting countdown card enters with a spring (response 0.42, damping 0.82). Under Reduce Motion it uses opacity only; otherwise it fades and slides in from an edge.
- Home layout: the trailing panel width is clamp(root width − leading width − 464, 320, 520), or 520 when the width is unknown. Padding animations are disabled under Reduce Motion.

**HeyMate:** the original cursor (`CompanionCursorView.swift`, `CursorFlight.swift`, `CursorDockPhase.swift`) is protected and must not be swapped for a character cursor. Any spatial character work has to sit alongside it, not replace it.

---

## 2. Floating agent cards

- **One host panel per display.** It is transparent, borderless and non-activating, joins all Spaces including full-screen ones, has no shadow, and covers that display's visible frame. Panels are reconciled on screen changes: new displays get a panel, and removed displays have theirs closed. Panels start out ignoring mouse events; interactive regions opt back in.
- **Layout.** Content is anchored top-trailing with an 18 pt top and trailing inset and 8 pt inner padding. Rows stack trailing-aligned with 8 pt spacing (0 in compact mode). The header handle is a 40 × 18 pill with a 24 pt hit height and 12 pt corner radius, and header controls sit 6 pt apart.
- **Header controls.** One button opens the main window. The other hides or shows the bubbles, and its label flips with the state. Press feedback uses 0.14 s and 0.16 s ease-out.
- **Collapse/expand.** Expanding only works when there is at least one row to show; collapsing only when expanded. Hidden sections keep their layout and state (zero-size, transparent, not hit-testable) instead of being torn down.
- **Visibility.** The stack shows only when at least one of three groups has content. Hiding cancels the auto-hide timer and orders all panels out.
- **Three row groups**, in this order:
  1. **Remote task notifications.** They have a compact and an expanded form, a report sheet, and a Dismiss button. Dismiss removes the row immediately, then sends a read acknowledgement with a 20 s timeout and one retry on an auth failure. If the acknowledgement finally fails, the whole notification list is cleared and polling stops. The dismissed row is not restored.
  2. **Live agent chips.** Each chip holds pinned-expanded state, an inline follow-up draft, a final-answer preview, hovers that show file changes, a settle-after-launch motion, and a gentle bob that stops while hovered.
  3. **"Skill created" cards.** The subtitle shows creation time as max(1, round(ms / 60000)) minutes, rounded half away from zero. Opening a card goes to the skill library with that skill preselected.
- **Focus.** The HUD can become key only while inline text entry is allowed, and it never becomes main. The notch panel refuses key status while it is temporarily told to.
- **Full screen and cursor.** Bubbles can hide when the frontmost window is full screen or the cursor has gone idle. There is a fade duration and probe intervals, but their values weren't recovered.

---

## 3. Routines (scheduled jobs)

- A repeating poll every 30 s, plus an immediate check at setup. It stops when there are no routines.
- **Due** means not paused and next-run strictly before now.
- **Holds.** If the network is known to be offline, wait. If the network state is unknown, go ahead. After sleep, wait until the main display is awake. After the screens wake, wait for a full wake, for at most 180 s.
- **Keep-awake.** While a routine is armed and the Mac is on AC power, the app holds a prevent-idle-sleep assertion. It releases the assertion on battery or when disarmed.
- **Busy guards.**
  - Don't launch if a task for the same mate (or the same bound thread) is queued or running.
  - Separately, don't launch if that mate has a task waiting for extra-effort approval.
- **Accepted launch.** Increment the run count, record the start time, clear the last result and any retry, and set next run = now + interval.
- **Refused launch.** Retry in 300 s, without counting a run.
- **Prompt shape.** The first run gets a first-run instruction. Later runs are told when the last run started and asked to report only what's new or changed. If the previous attempt failed or was interrupted, the prompt says not to repeat external actions and to verify uncertain outcomes. Answers go in chat, not files, unless asked.

---

## 4. Proactive suggestions (morning deck)

- A server job is requested with a 180 s timeout. It is polled every 4 s for the first 15 min, then every 30 s, and abandoned at 6 h. A pending job survives relaunch for up to 6 h.
- **Cadence slots** are local hours: [6], [6, 12, 18] or [6, 9, 12, 15, 18]. A run is eligible if the most recent slot at or before now hasn't fired yet and any retry-after time has passed.
- **Dismissal fatigue.** Dismissals on three consecutive calendar days start a 5-day rest. The server can also send a "pause suggestions until" date.
- **Presentation.** The morning card is one candidate in the notch's presentation arbitration. Dictation, voice, toasts and agent peeks win over it. It shows only when there is a live card created today and no blockers. A snooze re-arms it with an 18 s on-screen countdown.
- Suggestion cards need a non-empty title, description and agent prompt. Approve, adjust and deny each have their own handlers.

---

## 5. Voice

- **Full-duplex realtime session** with server-side voice activity detection.
  - Threshold 0.5 or 0.72 (stricter in one audio mode), 300 ms of prefix padding, 300 ms of trailing silence.
  - The server doesn't auto-create or auto-interrupt responses; the app decides.
  - Noise reduction is near-field when echo cancellation is active, far-field otherwise. In manual mode, voice detection is off.
- **Commit.** Commits buffered input and requests a response. The commit itself has no minimum length.
- **Barge-in.** Bumps a playback generation so stale audio is ignored, cancels the response if one is in flight, truncates what has already been played, and stops the playback sink.
- **Stop.** Bumps generations, stops the microphone and playback, clears every pending audio and turn flag, and closes the socket with a "going away" code.
- **Streaming chat** has a 120 s request timeout, a 300 s resource timeout, waits for connectivity, and uses no cookies or cache. Only lines that start with the data prefix are parsed, and the stream ends on the done marker.

---

## 6. Permissions, consent and onboarding

- **Status rows** for Contacts, Calendar, Reminders and Photos read the current authorization only and never prompt. Automation status uses a non-prompting check: allowed, denied, not yet asked, or "target not running". The "not running" case falls back to a remembered list of targets that were seen granted. The reference app's Files & Folders row is a fixed label, not a real check, and HeyMate must not copy that.
- **Computer-use consent.** A global bypass setting allows everything. Otherwise, a thread is allowed if it, or one of up to 8 ancestor threads (9 IDs in total), is in the approved set. An empty approved set denies. Approving replaces the whole set.
- **Diagnostics.** Before sending, four targeted redactions remove OAuth token parameters, JWT-looking strings, bearer tokens and secret-key-looking strings. This is not general PII removal. Error reports are sent with a 10 s timeout and include account identifiers. Crash reporting sends default PII, has a 6 s app-hang threshold, and samples traces at 10 %.
- **Onboarding.** There is a pre-sign-in intro window with "phantom" staged agents and a flight anchor, plus a permission coach that uses the guide character states. The choreography itself wasn't recovered.

---

## 7. Agent runtime: live steering

When the user types while an agent turn is running, the reference app steers the active turn: it sends the new input tagged with the expected turn, polls every 200 ms for up to 10 s for the turn to be ready, and starts a fresh turn only if there is no active one. HeyMate currently queues follow-ups until the current step ends, except for planning turns.

---

## 8. What HeyMate implements today

Branch `claude/in-flight-work` (commit 46fc4d4). Paths are under `heymate/HeyMate/`.

| # | Behavior | Status | HeyMate file(s) | Notes |
|---|---|---|---|---|
| 1 | Reduce Motion overrides everything; idle-animation preference | Done | `CompanionMotionPolicy.swift`, `SettingsGeneralPane.swift` | |
| 2 | Pause when hidden, occluded, has a hidden ancestor, or has an empty visible rect | Done | `CompanionMotionPolicy.swift` (visibility probe) | Re-checks on scroll but doesn't pause *during* scrolling |
| 3 | Time-based frame clock that resets on state change; 1/24 s redraw | Done | `MateLiveFace.swift`, `MateArtworkMotionView.swift` | Fully paused under Reduce Motion (stricter than reference) |
| 4 | Expression vocabulary from companion state and agent status | Partial | `MateFace.swift` | 9 expressions vs about 56 states; no tool, file, web or text states |
| 5 | Gaze toward pointer, unit-disk clamp, 0.2 s out / 0.28 s back ease-out | Done | `MateLiveFace.swift`, `MateArtworkMotionView.swift` | No 0.008 dead-zone or elliptical scaling; minor |
| 6 | Blink (about 0.19 s) | Done | `MateLiveFace.swift` | Fixed 4.7 s cadence; no blink when the pointer enters |
| 7 | Breathing | Done | `MateLiveFace.swift`, `MateArtworkMotionView.swift` | Different amplitude and period (sine at 1.7 rad/s) |
| 8 | Click / hello reactions (six kinds) | Not started | — | No click handling on faces |
| 9 | One-shot reactions with a 2 s window, consumed once | Partial | `LiveMateFaceView.swift` | 2 s success/failure reaction on a newly observed own-job completion; no deferred delivery while hidden |
| 10 | Live motion for every pack | Partial | `MateFace.swift`, `MateArtworkMotionView.swift` | Colour mates get a face rig; drawn packs get whole-art poses; photos stay static |
| 11 | Sprite sheets with per-state FPS and once/loop | Won't port as-is | — | HeyMate has no sprite art. Adopt the FPS families only if we commission original sprites |
| 12 | Wake → stretch entrance timings | Not started | — | |
| 13 | Walk / run / sprint from token throughput | Not started | — | No token-rate signal reaches the face |
| 14 | Tool/file/web text classification into states | Not started | — | |
| 15 | Spatial travel, point and tap choreography | Won't port as-is | — | The original cursor is protected; only additive overlays allowed |
| 16 | Floating cards: one non-activating panel per display, all Spaces, full-screen auxiliary | Done | `FloatingAgentWindowController.swift` | Panel is sized to the stack (312 wide, 12/16 pt margins) instead of a full-frame host with 18 pt insets |
| 17 | Header: open main window and hide/show bubbles | Done | `FloatingAgentWindowController.swift` | No 0.14/0.16 s press feedback |
| 18 | Approvals first; hidden when there is nothing to show | Done | `FloatingAgentWindowController.swift` | |
| 19 | Result notifications with report and dismiss | Partial | `FloatingAgentNoticeStore.swift`, `FloatingAgentNoticeView.swift` | Local-only; no remote acknowledgement (none needed) |
| 20 | Rich live chip: inline follow-up, answer preview, file-change hover, settle and bob motion | Not started | — | Card opens the chat instead |
| 21 | "Skill created" cards | Not started | — | |
| 22 | Hide bubbles in full screen or when the cursor is idle | Partial | `FloatingAgentWindowController.swift` | Yields to system overlays and the recording preference only |
| 23 | Panel-to-window promotion that keeps the live view | Partial | `NotchCompanionController.swift` (existing) | Not compared in detail |
| 24 | Routine poll, plus checks at start and on network recovery | Done | `MateRoutineScheduler.swift` | 30 s, strict `<`; empty collection stops sources |
| 25 | Hold when offline | Done | `MateRoutineScheduler.swift` | Marks the routine waiting |
| 26 | Dark-wake / screens-awake hold (180 s) | Implemented | `MateRoutineScheduler.swift` | Main-display hold; 180 s fallback starts after awake display. Live Mac QA pending |
| 27 | Keep-awake assertion on AC only | Implemented | `MateRoutineScheduler.swift` | PreventUserIdleSystemSleep while armed; power-source callback releases on battery. Live Mac QA pending |
| 28 | Busy guard per mate | Done | `CompanionManager+Mates.swift` | Mate or bound chat with nonterminal work blocks; includes approval waits. Refusal retries in 300 s without counting a run |
| 29 | First-run / repeat-run / failed-run prompt shaping | Done | `HarnessTurnNotes.swift`, `MateRoutine.swift` | Snapshot previous attempt before launch accounting; interrupted launch survives relaunch; chat output unless files requested |
| 30 | Morning suggestion deck with cadence slots and dismissal fatigue | Not started | `DailySuggestions.swift` (no caller) | |
| 31 | Full-duplex realtime voice with server VAD and barge-in | Not started | `VoiceRouter.swift` et al. | HeyMate uses push-to-talk / hands-free speech-to-text plus TTS by design (BYOK, on-device) |
| 32 | Non-prompting permission status | Done | `PermissionGuide.swift`, `SettingsPermissionsPane.swift`, `MacPermissions.swift` | |
| 33 | Consent inheritance through ancestor threads | Won't port | `ComputerUseCoordinator.swift` | HeyMate uses per-chat and standing grants |
| 34 | Animated onboarding intro and character permission coach | Partial | `OnboardingTour.swift`, `PermissionGuide.swift` | Tour exists; no character choreography |
| 35 | Live steering of a running turn | Partial | `CodexAppServerConnection.swift`, `CodexAppServerPlanningSession.swift`, `HeadlessAgentLauncher.swift` | Planning turns only; write runs still queue |
| 36 | UI sound events (open/close, send/receive, job started/needs-you/done/closed, question, surprised, thumbs-up, level up/down, boot, hatching) | Implemented | `UISoundPlayer.swift`, `scripts/generate_ui_sounds.py` | Audio synthesized by the v5 profile in the generator script |

**Note on sounds.** Every `.m4a` in the catalog is the output of `heymate/scripts/generate_ui_sounds.py` (v5 profile). Re-run the script to change them; never import audio from another app.

---

## 9. Backlog: what's worth porting next

Ordered by user value per unit of effort. Every item is an original HeyMate implementation of the behavior described above.

1. ~~Regenerate the sound assets~~ Done: all sounds now come from `generate_ui_sounds.py`.
2. **Hello/click reactions on live faces.** Add 2–3 original reactions (for example a wave, a wink and a little hop) as short keyframe tracks of 0.4–1.4 s with ease-in-ease-out segments. Start each track from the current on-screen pose. Deliver them through a 2 s accept-once window that waits while the face is hidden. This is the biggest "alive" gain for little code (rows 8, 9).
3. **Richer agent expressions.** Map agent activity to distinct faces: reasoning, tool use, reading, writing, web, image, text streaming. Use the first-match substring rules from 1.2 on the agent's latest action text. Add a short wake-then-work entrance (about 0.55 s and 1.05 s) when a job starts (rows 4, 12, 14).
4. **Work pace from token rate.** Feed a smoothed tokens/s signal (EMA 0.65/0.35, 0.25 s floor) into the face or card motion, with walk / run / sprint style tempo at the 8 and 28 tokens/s thresholds. This gives users a visible "how hard is it working" cue (row 13).
5. **Floating card upgrades.**
   - An inline follow-up field. The panel becomes key only while it is being typed into.
   - A collapsible final-answer preview.
   - A settle animation on launch, and a gentle bob that pauses on hover.
   - 0.14 s / 0.16 s press feedback on the header buttons.
   - Hide in full screen or when the cursor is idle (rows 17, 20, 22).
6. Routine robustness implemented (rows 24–29), pending live Mac sleep/wake and power-source QA. Run `script/test_routines.sh` for standalone production-code regression checks and `scripts/typecheck.sh --tests` for the full app/test compile check.
7. A morning suggestion deck built on `DailySuggestions.swift`, with cadence slots and a 3-day-dismissal → 5-day rest (row 30).
8. Live steering for write-enabled runs on the app-server transport, with the 200 ms / 10 s readiness poll and no blind resend (row 35).
9. A "skill created" card in the floating stack with rounded-minutes timing (row 21).
10. Barge-in for hands-free voice: a playback generation counter, so stale audio is dropped and TTS stops the moment the user speaks (row 31, without moving to a duplex architecture).

## 10. Rules for anyone using this document

- Behavior and numbers only. Don't paste code, decompiled output, identifiers, strings, endpoint paths or assets from the reference app into this repository.
- Keep HeyMate's protected surfaces: the original cursor, the notch attachment, the single Integrations page, no Activity page, and original mate artwork.
- Private research notes and raw evidence stay outside the repo (they are archived locally, not in git). Nothing from `outputs/` is ever committed.

### Routine port validation — 2026-10-29

The scheduler port follows the saved native routine findings: strict due boundary,
30-second polling, offline hold, display/full-wake gates, AC-only idle-sleep
assertion, acceptance accounting and 300-second refusal retry. Completion keeps
the launch-time schedule. Optional persisted fields decode old routines unchanged;
a launch without completion is treated as unfinished on the next run.

HeyMate keeps its daily wall-clock schedule and three-failure pause. Hourly
schedules advance from acceptance. The shared chat path remains serialized;
nonterminal detached work for the same mate or bound chat also blocks dispatch.
Using 300 seconds for busy refusals and resetting the full-wake gate on workspace
`didWake` are HeyMate integration choices; the saved REA ledger did not fully
resolve those reference helpers. This is a behavioral Swift port, not recovered
source copied verbatim.

Validation: full app/test compile check passed; 41 standalone parser, schedule,
accounting, wake, scheduler and prompt tests passed. The standalone harness uses
fake network, wake and power sources, and never launches HeyMate. Real sleep,
battery transitions and manager/UI delivery still need installed-app QA.
