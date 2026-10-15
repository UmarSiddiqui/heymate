# Assets brief

## Rules for every asset

- **Real before recreated.** Clips A–G are real screen recordings of the shipped app. Computer-use can't drive HeyMate, so you record them. Claude can then trim, crop, caption and export them with ffmpeg. Anything rendered in Remotion is labelled "Recreated product demo" or "Illustration" on every frame.
- **Look.** Matte black or white surfaces, one Signal-blue accent (`#3380FF`), Avenir Next or SF. No purple, violet glow or nebula imagery. Use a plain grey or black desktop wallpaper.
- **Privacy.** Use a clean demo user account with seeded sample data. Don't show real email, contacts, notifications, file names or browser tabs. Turn on Do Not Disturb, hide the dock, and quit chat apps.
- **Demo variety.** Don't use Activity Monitor or "why is my Mac slow". Don't lead with coding. Each "here I asked" uses an everyday app or website. Good picks: a web dashboard settings page, a spreadsheet, Keynote or Pages, Photopea, a PDF, the System Settings-style page of a website. Don't use actual System Settings, because HeyMate excludes it from capture.
- **Captions.** Burn in captions for the spoken question and HeyMate's spoken answer. X and LinkedIn autoplay muted.
- **Music.** None on real recordings. If a cut reuses the Meet HeyMate track, it needs the Peyruis CC BY 3.0 credit block wherever it's posted.
- **Capture setup.** Record at 2× Retina on a notch MacBook so the notch is visible. Use QuickTime or `screencapture -v` at full screen, plus the app's own voice output; enable system-audio capture if your recorder needs it. Keep the uncut original, and note the provider, model and version for each recording.
- **Website files.** New filenames for anything that replaces a website asset, because `/assets/*` is cached as immutable.

## Aspect ratios

| Ratio | Size | Use |
|---|---|---|
| 16:9 | 1920×1080 | X, YouTube, HN/README, the PH video |
| 1:1 | 1080×1080 | LinkedIn, X alternate |
| 4:5 | 1080×1350 | LinkedIn feed (most screen space) |
| 9:16 | 1080×1920 | Shorts, TikTok, Reels |
| PH gallery | 1270×760 | |
| OG card | 1200×630 | |
| README GIF | 720 px wide, 15 fps, under 8 MB | |

For 9:16 and 4:5 cuts, crop around the notch-to-pointer path. Don't crop away the target the pointer lands on.

---

## Available now (current release, v1.0.59)

### Clip A: the core ask-and-point (top priority, needed by week 1)

- **Used in:** X1, LinkedIn, Show HN/README GIF, the PH video, outreach.
- **Length:** 15–25 s, unedited apart from trims. If you speed anything up, label it on screen ("2× speed").
- **Ratios:** 16:9 master, plus 1:1, 4:5 and 9:16 crops, plus a 720 px GIF for the README.
- **Scene:** a browser on a realistic but fake web-app settings page, for example a sample analytics dashboard with a cryptic toggle. You could build a static fake page in the scratchpad, or use a public demo site.
  1. 0–2 s: show the screen, unchanged.
  2. 2–5 s: the ⌃⌥ keycaps overlay appears; add it in post as a small bottom-left overlay. The notch shows the listening waveform. Caption your question: "What does 'Sampling rate' change here?"
  3. 5–8 s: release the keys. The typing dots show in the notch.
  4. 8–18 s: HeyMate speaks the answer, with the caption burned in, and the pointer moves to the toggle and rests there.
  5. 18–22 s: hold on the result. End card: "Hold ⌃⌥ and ask · getheymate.vercel.app".
- **Check:** the pointer lands on the right control first time. Re-record rather than cut around a miss.

### Clip B: "Here I asked…" in a different app (week 2)

- **Used in:** X2, r/macapps.
- **Length:** 12–20 s. **Ratios:** 16:9 and 9:16.
- **Scene:** a spreadsheet (Numbers or Google Sheets) with a sample budget. Ask "Which cell is pulling this total down?" HeyMate answers and the pointer lands on the cell. Add the same keycap overlay and end card as Clip A.

### Clip C: a short walkthrough (optional, week 2–3)

- **Used in:** the README "Walkthroughs" section, the PH gallery.
- **Length:** 30–45 s. **Ratio:** 16:9.
- **Scene:** Photopea with the owned sample logo from `marketing/demo-video/public/pixel-coach/`. Ask "Walk me through removing this background, one step at a time." Show steps 1–2 being pointed at and clicked, then the finished transparent export. This is the real-capture brief already in LAUNCH.md.

### Clip D: one-sentence agent (week 3)

- **Used in:** X4.
- **Length:** 10–15 s. **Ratios:** 16:9 and 1:1.
- **Scene:** the agent builder. Type "Draft replies to customer email every morning". The drafted card appears, showing the name, the habits, and "Asks you before: sending any email". Click Create. Use seeded sample data only.

### Still S1: hero

- **Ratios:** 1270×760 (PH 1) and 1200×630 (OG card).
- **Scene:** a frame from Clip A at the moment the pointer rests on the target and the answer bubble is visible. Add the overlay text from the PH shot list.

### Still S2: keycaps and notch listening

- **Ratio:** 1270×760.
- **Scene:** a close crop of the notch with the waveform active and the spoken-question caption.

### Still S3: "pick your brain" onboarding

- **Ratios:** 1270×760 and 16:9 (for X3).
- **Scene:** the onboarding screen listing Claude, ChatGPT, OpenCode, API key and Apple Intelligence. Claude can capture this with the screencapture helper on a test build.

### Still S4: agent builder review card

- **Ratio:** 1270×760.
- **Scene:** reuse `website/assets/screens/v3/builder-review.webp`, re-composed onto a 1270×760 matte canvas.

### Still S5: privacy and permissions

- **Ratio:** 1270×760.
- **Scene:** the Settings → Privacy & Data permission list, with each "HeyMate can see your screen when you ask" line legible.

### Still S6: install

- **Ratio:** 1270×760.
- **Scene:** a typographic card, rendered in Remotion and labelled as a graphic. It shows `brew install umarsiddiqui/tap/heymate`, a DMG icon, and "Free · MIT · macOS 14.2+".

---

## After PR #55 ships in a release

These are gated. Capture them only from the released build, never from the draft branch, and re-check each behaviour against the release notes first.

### Clip E: live mate faces with gaze and reactions

- **Used in:** X5, the PH gallery (Still S7), the LinkedIn monthly post, and a README feature-row GIF.
- **Length:** 8–12 s. **Ratios:** 1:1 master (faces read best square), plus 16:9 and 9:16.
- **Scene:** the Mates/Agents window with 3 agents' faces visible in the sidebar.
  1. Move the cursor slowly left to right across the screen. The faces' gaze follows.
  2. Start a job on one agent; its face shows the "working" expression.
  3. The job finishes, and its face reacts (pleased or done).
  4. Caption the beats: "They look where you're working" and "They react when a job lands".
- **Reduce Motion:** also record 3 s with Reduce Motion on, to show the calmer state for accessibility-minded viewers. Use it in the README only.

### Clip F: floating agent cards

- **Used in:** X5 (alternate), the PH gallery, the website agents section.
- **Length:** 10–15 s. **Ratios:** 16:9 and 9:16.
- **Scene:** an everyday app full screen, such as Pages with a document. Start 2 agent jobs from the notch. Two small floating cards appear at the screen edge with their status, one goes to "Needs you", and a task-result notice slides in. Click it to open the result.
- **Overlay text:** "Your agents work while you do."

### Clip G: sound tour (with sound)

- **Used in:** X5 ("sound on"), the YouTube Short, the website.
- **Length:** 15–20 s. **Ratios:** 16:9 and 9:16.
- **Scene:** sound is the point, so the visual can be simple. A matte black canvas shows each event name as it plays, synced to the real app interaction behind it in a small inset:
  - boot
  - listen start
  - message sent
  - response ready
  - job started
  - job needs you
  - job done
  - level up
- **Audio:** record app audio directly (24-bit WAV for the master, AAC in the export). Add the caption "All sounds made from scratch for HeyMate". The sounds are clean-room synthesized by `heymate/scripts/generate_ui_sounds.py`, so this claim is fair. Never use or reference another app's sounds.

### Still S7: faces and floating card

- **Ratios:** 1270×760 (PH 6) and 1200×630 (an updated OG card candidate).
- **Scene:** a frame from Clip E or F showing a face looking toward a floating "Done" card.

### Still S8: the Permissions settings tab

- **Ratio:** 1270×760.
- **Scene:** the new Settings → Permissions tab with every grant's state. Use it in the permissions page and PH 7. It reinforces the "nothing hidden" message.

---

## Deliverable file naming (for Claude's edit pass)

`marketing/plan-2026-10/assets/` doesn't exist yet. Create it only when real captures arrive. Name files `clip-a-ask-16x9.mp4`, `clip-a-ask-9x16.mp4`, `clip-a-ask-720.gif`, `still-s1-hero-1270x760.png`, and so on, following the same pattern for each asset.
