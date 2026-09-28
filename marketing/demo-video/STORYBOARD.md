# HeyMate demo — storyboard

About 40 seconds at 60 fps. Matte black (`#0A0A0A`), Avenir Next everywhere, and one accent: Signal blue `#3380FF`. The icon's violet glow (`#5E54FF`) shows up only during the logo reveal.

Motion follows the app's `buddySpring` (response 0.42, damping 0.78). Scenes cross-fade with a 1.02× scale settle, with no wipes or spins. Callout text sits left of the UI in landscape and above it in vertical.

| # | Scene | Duration | On-screen text | Visuals | Animation |
|---|---|---|---|---|---|
| 1 | Hook | 4.5 s | "Stuck on an error?" → chips: "Copy it" · "Switch apps" · "Paste" · "Explain" · "Wait" → "There's a faster way." | Pure black, centred type | Headline rises in with a blur-to-sharp effect. Chips drop in one at a time, then pile up and fade (the chore). The last line fades up. |
| 2 | Logo reveal | 3.5 s | "HeyMate" / "Say hey. It's already looking." | App icon (real asset) with violet bloom behind it | Icon springs from 0.6× and the bloom breathes once. The wordmark tracks in from wide letter-spacing and the tagline fades in after it. |
| 3 | Lives in your notch | 6 s | **Lives in your notch.** / "Hover to peek. Click to open." | Mac menu bar (HeyMate File Edit View Window · Sun 27 Sep 9:41 AM) with the collapsed notch pill and green Ready dot | The pill springs open into the Home card (Ask HeyMate…, Last agent, Jump to grid). Then the tab slides to Apps: micro-app grid, with the 24:49 focus timer ticking. |
| 4 | Sees what you see | 7 s | **It sees what you see.** / "Hold ⌃ ⌥, ask, release. It answers out loud." | Code editor with CheckoutView.swift and a red error on line 42. ⌃ ⌥ keycaps, the listening pill, and a spoken caption: "What's wrong with this error?" | Keycaps press down and the notch pill shows a live waveform. The blue cursor buddy flies along an arc to line 42 and the line lights up. A reply bubble streams in next to the cursor. |
| 5 | Real work, with a leash | 7.5 s | **Real work. With a leash.** / "Agents plan read-only. Nothing changes until you approve." Brain chips: claude · codex · opencode, "on the subscription you already have" | The Agents card "Test the optional checkout total" (amber "Needs you" border, the plan in 3 steps) | The card rises in and the plan lines stagger. The cursor clicks **Approve plan**, the border shifts amber → blue (Running) → green (Done), and a completion receipt slides in ("2 files changed · Ready undo"). |
| 6 | Mates | 6.5 s | **Not one assistant. A small team.** / "Mates with their own job, memory, and schedule." | Window with the Mates sidebar (First Mate, Comments, Builds, Inbox, Research, using the app's real faces), the Comments chat, and a routine card "Daily at 8:30am" | Sidebar rows stagger in and unread badges pop. The chat message types in and the routine card lifts in with a soft shadow. |
| 7 | Close | 5 s | "Say hey." / **Download free for Mac** / "macOS 14.2+ · Free · Bring your own AI" | Small icon, big line, Signal-blue pill button | Everything settles in on a spring, the button gets a single gentle shine sweep, then it holds. |

Cross-fades overlap by 18 frames, so the total runtime is a little under the sum of the scene durations.

**Music:** there's a slot in `src/config.ts` (`MUSIC_SRC`). Drop a licensed track into `public/music/` and set the filename there.
