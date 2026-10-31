# HeyMate landing page refresh — 2026-10-31

- [x] Audit live site, current installed app, and current capability source.
- [x] Remove old screenshots, illustrated hero editor, and homepage video.
- [x] Reduce copy; explain screen help, approved computer control, specialist mates/routines, Notes, and usage.
- [x] Recreate current notch Home/Usage, chat rail, blue controls, voice/type composer as a labelled, local scripted preview.
- [x] Add context-aware buddy cursor, reduced-motion support, and an off switch.
- [x] Add Milo, Nova, Tide, and Peach, with live gaze and small laptops.
- [x] Make real download/star counts prominent; cache GitHub data on server; label failures and stale data.
- [x] Verify desktop/mobile layouts, keyboard navigation, safe typed content, consent flow, network failure, and reduced motion.
- [x] Review release availability of capabilities against production DMG before publishing.
- [ ] Publish approved website; repoint getheymate.vercel.app alias after production deploy.
- [ ] Feedback form / public board: deferred by user. No new collection or email service.

## Capability evidence

- Current installed app inspected read-only: Home/Usage notch, Mates, Notes, chat, voice/type composer. No user conversation screenshot is included in public assets.
- `HeyMate/TalkToolCatalog.swift`: screen-aware talk, local actions, Chrome tools, specialist creation, handoff, status, and recurring routines.
- `HeyMate/DriveTakeOverController.swift`, `ComputerUseTakeBack.swift`: consent before computer actions, bounded drive, user takes control back.
- `HeyMate/NoteStore.swift`, `agent-runtime/src/notes.mjs`: persisted Notes and agent notes.
- Current local app source has uncommitted work outside website; this task does not alter it or install/build the app.

## Preview and checks

From repository root:

```sh
node website/preview.mjs
node --test website/tests/*.test.mjs
```

Open http://127.0.0.1:4173. Vercel serves `api/stats.mjs` in production. No new dependencies or secrets. GitHub counts unavailable on static-only hosting without the API; failure state is explicit.

## Verification results

- Browser checks: 360, 390, 768, 1024, and 1440 px; no horizontal overflow. Real touch emulation: notch tabs, mate selection, dock hides over preview, buddy hidden for coarse pointers.
- Keyboard: notch tabs use arrow keys/Home/End, Escape collapses and restores focus; typed composer, voice shortcut, and buddy toggle checked.
- Scripted handover: approve, decline, and stop paths; unrecognized prompts clearly explain the preview. Typed HTML remains text.
- Reduced motion: zero running animations; companion stays still. Cursor follows independently of caption bounds near right/bottom edges.
- Stats: exact DMG asset aggregation, pagination, zero stars, invalid/upstream error tests pass. Browser 503 state shows unavailable rather than fabricated counts.
- GitHub release on main: latest three release workflow runs succeeded; latest run https://github.com/UmarSiddiqui/heymate/actions/runs/40749602217.
- Published v1.0.76: HeyMate.dmg present; appcast parses as XML, enclosure points to exact HeyMate.dmg and has positive length.
- v1.0.76 already includes computer control, Chrome, Notes, routines, and usage. New handover design and voice-created mates are labelled next release in preview.
- No production deployment performed. Alias reminder remains pending with deployment.

## Review adjustments

- Website-only notch trigger, floating panel, and decorative demo notch removed at user request. Actual Mac app capabilities remain described.
- Cursor arrow reduced from 27×32 to 22×26 px. Bubble text increased from 11 to 14 px (13 px at compact widths), with 1.6 line height and a wider bubble.
- Headline uses canonical Signal blue #3380FF from AppTheme.swift.
- Buddy messages type in HeyMate's own voice, with brief typing dots, punctuation pauses, stable bubble bounds, and immediate text for reduced motion.

- Cursor parity update: ported CompanionCursorShape.swift path (0.50/0.04, 0.08/0.92, 0.50/0.66, 0.92/0.92), 16pt square, -35° heading, AppTheme Signal fill and 8pt glow, no outline. CompanionCursorView pointer-center offset 35×25pt, immediate 60Hz following, up-to-8° banking and a 3-second idle breath now match source. Readable typed bubble retained.

- Added a new minimal notch at user's later request: compact trigger, Home and Usage tabs, local example usage readings, and Park/Recall with dock flights. Replaces the floating Buddy on/off button; no decorative notch restored inside the desktop mockup.
- Copy refresh covers all homepage sections and key links/actions in HeyMate's voice. Per-app integration messages, provider setup, consent, preview limits and footer links have specific buddy text. Scroll resolution now checks the element under the pointer instead of overriding it from viewport-center guesses.
- Verified Park hides the buddy, Recall restores it, keyboard tab navigation and Escape work, panel fits 360/390/768px, ten main copy contexts resolve correctly, and no runtime errors occur.

## Native motion pass

- Notch now morphs a single SVG silhouette using the app's camera neck/shoulder geometry. Spring parameters match CNNotchMotion: open response 0.62, damping 0.72; close 0.26/0.92. Width stops at target, height settles softly. Content fades on the same clock, without scaling text.
- Added app's 180 ms hover intent / 220 ms exit grace; explicit clicks pin the panel. Home/Usage selection glides, content fades over 160 ms, shell height and footer action positions transition rather than snap.
- Park/Recall port CursorFlight's quadratic arc, smoothstep clock, reach-based lift/scale, optional long-flight wind-up, and distance-based 0.6–1.4 s duration.
- Pointer motion no longer measures the page dock or bubble dimensions on every event; cached ResizeObserver bounds preserve bubble edge safety.
- Verified mid-open close/reopen, rapid tabs, rapid Park/Recall, keyboard Escape, responsive panels and reduced-motion settling. Local motion recording: .playwright-mcp/heymate-motion-demo.mp4.

## Landing-page feedback pass, 2026-10-31

- Replaced the scripted interactive hero with a generated static hero illustration, delivered as a 64 KB WebP. Initial concept superseded by the screenshot-based artwork documented below.
- Kept the notch companion and character lineup; removed the hero chat engine and routed its former actions to the demo, setup, permissions, and mates sections.
- Restored all 30 integration entries, searchable directory, Composio key/setup copy, MCP/CLI/Chrome details, and permission information.
- Restored the illustrated 41-second demo with native video controls, disclosure, and music attribution.
- Removed eyebrow labels, numbered feature decoration, and small character taglines. Main-page supporting copy is at least 14 px; body descriptions are 16-18 px.
- Verified GitHub's latest published release is v1.0.76 (2026-10-28), added its summary to changelog.html, and mirrored the latest three releases on the landing page with a full-changelog button.
- Existing stats tests pass. Local asset/anchor checks pass; desktop and mobile browser checks cover hero, search results/no results, notch, video, and changelog navigation.
- No production deployment performed. Repoint getheymate.vercel.app after the next approved production deploy.

## Screenshot-based product artwork, 2026-10-31

- Replaced the generic laptop-and-blobs hero with a generated close-up based on the supplied real Home/Usage screenshots.
- Added screenshot-based chat and integrations artwork to their sections and Brain/Voice images in a new setup section. All five images have full-size PNG links and optimized WebP delivery (about 340 KB combined).
- Kept the actual black panels, blue controls, characters, and settings layout. Replaced personal conversation/activity snippets with neutral examples; unrelated desktop content is removed. The sensitive Notes screenshot is not used.
- Corrected Brain artwork's notch silhouette after visual inspection. Five final asset pairs live in assets/img/product; prompts and provenance live in marketing/website-product-images-2026-10-31.json.
- Detailed integrations and Composio copy, latest changelog, demo video, download links, and existing companion interactions remain.

- Final browser verification: 360, 390, 768, 1024, and 1440 px without horizontal overflow; all five final product images load; no browser errors; notch Park/Recall works. Supporting text remains at least 14 px. Local links/assets/IDs pass checks. No production deployment.

## Original screenshot and notch expansion correction, 2026-10-31

- Latest user instruction supersedes the generation choice: hero uses the user's exact blue-desktop Home screenshot, not generated artwork. PNG is copied unchanged; lossless WebP is verified pixel-identical. Natural wide aspect ratio stays visible without cropping.
- Generated chat mockup removed from the landing page. Settings artwork remains.
- Interactive notch now grows into a wide, top-attached Home surface (up to 760 px). No narrow neck or panel floating 31 px below the top. Two-column ask/roster layout, Home/Usage tabs, Chat/settings controls, Park/Recall, and permissions link follow the reference. Compact screens stack content within the viewport.

## Live notch replaces static hero screenshot, 2026-10-31

- Latest instruction removes the hero screenshot entirely: the live, wide expanding notch already demonstrates the Home surface. No generated chat mockup or duplicate Home screenshot remains on the page.
- Demo video, detailed integrations/Composio message, settings feature images, and latest changelog remain.
- Companion dock now hides over the demo film on compact screens; it no longer depends on the removed hero-image element.

- Final checks: desktop panel 760 px wide, top 0; mobile Home panel 366 px wide and 328 px tall at 390 px viewport, no overflow. Home/Usage arrow keys and Escape/focus restore pass. Three existing stats tests pass; local links/assets/IDs and JS syntax pass. No production deployment.
