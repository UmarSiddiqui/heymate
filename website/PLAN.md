# HeyMate — Landing Page Plan (v1, free tier)

> Status: BUILT and hosted at https://getheymate.vercel.app (static site in this folder). This document remains the spec.
> Product facts below are pulled from the app source (`heymate/HeyMate/*.swift`, `README.md`, `design-qa.md`). Do not invent features that are not listed in §2.

---

## 0. Ground rules for the build model

1. Follow this document literally. Copy is final unless marked `[TBD]`.
2. Price is **free**. Never show a price, "Buy", "Pro", or "Pricing" nav item. The primary CTA is **Download free**.
3. Every image slot in §6 has an ID (`IMG-xx`). Reference IDs in code comments so assets can be swapped later.
4. Never claim a feature not in §2. Never claim "works offline", "end-to-end encrypted", "App Store", or "notarized" — none are true yet.
5. Aesthetic = Apple product page. Dark obsidian default. One accent: HeyMate nebula violet. No gradients on text, no glassmorphism cards except the nav, no emoji, no stock-photo people.
6. Ship a single static page (`index.html`) + `privacy.html`. No backend, no analytics until the user adds a key.

---

## 1. Product truth sheet (for copywriting and honesty)

| Fact | Value | Source |
|---|---|---|
| Name | HeyMate | pbxproj `MARKETING_VERSION 1.0` |
| One-liner | An AI buddy that lives in your Mac's notch, sees your screen when you ask, talks back, and hands real coding work to Claude Code, Codex, or OpenCode. | `README.md` |
| Platform | macOS 14.2+ | pbxproj `MACOSX_DEPLOYMENT_TARGET` |
| Notch required? | No. Non-notch Macs get a top-center pill. | `NotchLayoutMath.swift` |
| Pricing | Free (MIT licensed). Uses your existing Claude / ChatGPT / OpenCode CLI subscriptions. No HeyMate API bill. | `LICENSE`, `AgentBrain.swift` |
| Default brain | Claude Code CLI (`claude -p`) | `AgentBrain.swift` |
| Push-to-talk | Hold **⌃ ⌥** (control + option) | `BuddyDictationManager.swift` |
| Compact notch chat | **⌃ ⌘** | `NotchChatView.swift` |
| Dictation | **⇧ fn** default | `CompanionManager.swift` |
| Privacy line (verbatim in app) | "Nothing runs in the background. HeyMate only takes a screenshot when you press the hotkey, and screenshots are never stored." | `NotchExpandedView.swift` |
| Storage | `~/Library/Application Support/heymate/` — chats.json (text only), memory.json, mates.json, routines.json; secrets in Keychain | `ChatHistoryStore.swift` et al. |
| Integrations | Apple-native (Calendar, Reminders, Notes, Mail, Messages, Shortcuts…), local CLIs (gh, git, docker, kubectl, aws, vercel, supabase, stripe…), MCP servers, Composio (1,400+ toolkits) | `ConnectorCatalog.swift`, `ComposioToolkitDirectory.swift` |
| Agents | Plan (read-only) → you approve → execute in `~/Projects/heymate/<slug>`; undo snapshots; background runner survives quit | `README.md`, `BehaviorContract.swift` |
| Mates | Up to 5 persistent personas with name, job, soul, face, memory, workspace | `MateCreation.swift`, `MateProfile.swift` |
| Routines | Per-mate schedule: daily at a time, or every N hours | `MateRoutine.swift` |
| Distribution today | No signed public DMG yet. `appcast.xml` has no releases. | `appcast.xml`, `ReleaseChannel.plist` |

**Distribution decision needed before launch:** the Download CTA needs a real target. Options, in order of preference:
1. GitHub Releases DMG (signed + notarized) → `https://github.com/UmarSiddiqui/heymate/releases/latest`
2. Until then: CTA label **Get early access** linking to the GitHub repo, with a one-line "Build from source · Xcode 26" secondary link.
Build the page with a single `DOWNLOAD_URL` constant so this is a one-line swap.

---

## 2. Feature inventory allowed on the page

Pick from this list only.

**Notch & ambient**
- Lives in the notch; expands on hover/click into Home / Apps / Agents
- Software notch fallback for non-notch Macs
- Notch micro-apps: File Shelf, Timers, Battery, Now Playing, Next Event, Clipboard, Camera Mirror, Downloads, Volume HUD, Reminders
- Theme rim on the bezel (6 accents: Signal, Iris, Mint, Amber, Coral, Rose)
- Hide from screenshots and screen shares

**Talk, voice, vision**
- Push-to-talk (⌃⌥), release to send
- Screen-aware: screenshots only when the question needs sight; never stored
- Focused-window-only capture option
- Cursor buddy flies to and highlights what it is talking about
- On-device Apple Speech STT and system voice TTS by default; optional cloud voices
- Literal and smart dictation into any focused text field

**Mates**
- Create by voice: "make me a mate that…"
- Name, job, soul (personality), face, memory, workspace folder
- 20 built-in faces + custom
- Routines: daily or every N hours, results land in the mate's chat

**Agents**
- Claude Code, Codex, OpenCode
- Plan first (read-only), approve, then write
- Sandbox folders under `~/Projects/heymate`
- Undo snapshots, Terminal takeover, background runner

**Connectors**
- Apple-native, local CLIs, MCP, Composio (1,400+)
- Contextual "Connect X" suggestions when you're on that site
- Risk tiers: read-only silent, external/destructive always ask

**Control & trust**
- Mac automation is opt-in; clicks/types/sends always show an approval card
- Editable behavior contract (`behavior-contract.md`)
- Skills (Markdown), Memory (local JSON, clearable), Standing orders
- Bring your own subscription: Claude.ai, ChatGPT, OpenCode, or Custom Anthropic-compatible API

---

## 3. Design system

### 3.1 Tokens (CSS custom properties)

```css
:root {
  /* surfaces */
  --bg:            #000000;   /* page background */
  --bg-elev:       #0B0B0F;   /* cards, alternating sections */
  --bg-elev-2:     #141419;   /* hover, nested */
  --hairline:      rgba(255,255,255,0.10);
  --hairline-2:    rgba(255,255,255,0.18);

  /* text */
  --fg:            #F5F5F7;
  --fg-2:          #A1A1A6;   /* subheads */
  --fg-3:          #6E6E73;   /* captions, footer */

  /* brand */
  --accent:        #8B7CFF;   /* Iris — HeyMate lilac/violet from app palette */
  --accent-deep:   #5E54FF;   /* icon glow, used in shadows only */
  --nebula:        #B9A9E8;   /* warmth, decorative highlight only */
  --ready:         #34D399;   /* status dot only, never decorative */

  /* light section variant (used once, §4 S7 "Trust") */
  --porcelain:     #F5F5F7;
  --ink:           #1D1D1F;

  /* radii */
  --r-pill: 980px; --r-lg: 28px; --r-md: 18px; --r-sm: 12px;

  /* spacing scale (8pt) */
  --s-1: 8px; --s-2: 16px; --s-3: 24px; --s-4: 40px; --s-5: 64px;
  --s-6: 96px; --s-7: 128px; --s-8: 160px; --s-9: 220px;

  /* type */
  --font: -apple-system, "SF Pro Display", "SF Pro Text", Inter, "Helvetica Neue", sans-serif;
  --font-display-serif: "Didot", "Playfair Display", serif; /* wordmark only, see 3.2 */
}
```

### 3.2 Typography

| Role | Size (desktop / mobile) | Weight | Letter-spacing | Line-height |
|---|---|---|---|---|
| Hero H1 | 96px / 48px | 700 | -0.035em | 1.0 |
| Section H2 | 64px / 40px | 700 | -0.03em | 1.05 |
| Card H3 | 28px / 24px | 600 | -0.015em | 1.15 |
| Subhead | 28px / 21px | 400 | -0.01em | 1.3 |
| Body | 19px / 17px | 400 | 0 | 1.5 |
| Caption / eyebrow | 13px | 500 | 0.08em uppercase | 1.4 |
| Nav | 12px | 400 | 0 | 1 |

- Wordmark rule: the word **HEYMATE** may be set in Didot (matches the in-app empty state) **only** in the footer sign-off block. Everywhere else it is "HeyMate" in the sans.
- Max text width: 720px for body, 980px for H1.
- Use `text-wrap: balance` on all headlines.

### 3.3 Components

- **Nav**: fixed, 52px tall, `background: rgba(0,0,0,0.6); backdrop-filter: blur(20px) saturate(180%)`, hairline bottom border. Left: 20px app icon + "HeyMate". Center: links `Overview · Mates · Agents · Privacy · GitHub`. Right: pill CTA (accent bg, ink text, 12px, 8px × 16px padding).
- **Pill button primary**: `--accent` bg, `#0B0B0F` text, 17px, 14px × 28px padding, hover brightens 6%.
- **Text link CTA**: `--accent` text, trailing `›` glyph, underline on hover.
- **Feature card**: `--bg-elev` bg, 1px `--hairline` border, radius `--r-lg`, padding 40px, hover border → `--hairline-2`. No drop shadows.
- **Device frame**: MacBook Pro 14" outline drawn in CSS (bezel #1a1a1a, 18px radius, 2px #333 hairline), notch cutout 180 × 32px centered at top. Screenshots are placed inside via `object-fit: cover`.
- **Hero glow**: single radial gradient behind the device, `radial-gradient(60% 40% at 50% 30%, rgba(94,84,255,0.35), transparent 70%)`, `filter: blur(40px)`.
- **Keycap**: inline element for shortcuts — `⌃` `⌥`, 1px hairline, radius 6px, monospace-ish, `--bg-elev-2` bg.

### 3.4 Motion spec

All motion via IntersectionObserver + CSS; no scroll-jacking. Respect `prefers-reduced-motion` (disable all transforms, keep opacity fades at 0ms).

| Name | Trigger | Behavior |
|---|---|---|
| `fade-up` | element 15% in view | opacity 0→1, translateY 24px→0, 700ms, `cubic-bezier(.2,.8,.2,1)`; children stagger 80ms |
| `hero-reveal` | page load | H1 lines stagger 120ms; device image scales 1.04→1.0 over 1200ms with the glow fading in |
| `sticky-scale` (S3 Notch) | section scroll progress 0→1 | Sticky device frame; screenshot scales 0.92→1.0 and the notch pill "expands" by cross-fading `IMG-03` → `IMG-04`. Implement with a sticky container 220vh tall and `requestAnimationFrame` reading `getBoundingClientRect` |
| `count-up` (S6 Connectors) | in view | "1,400+" counts from 0 over 1.2s, ease-out |
| `nav-shrink` | scrollY > 24 | nav background opacity 0.6→0.85 |
| `marquee` (S6 logos) | always | Two rows of connector wordmarks scrolling opposite directions, 60s loop, pause on hover |

Video: hero uses `IMG-02` still with the `VID-01` loop layered on top (`<video autoplay muted loop playsinline poster=IMG-02>`), max 6s, ≤ 3 MB, `prefers-reduced-motion` → still only.

---

## 4. Page structure and final copy

Section order, IDs, and exact copy. Anchor IDs are used by the nav.

### S0 — Nav
Links: Overview `#overview` · Mates `#mates` · Agents `#agents` · Privacy `#privacy` · GitHub (external)
CTA: **Download free**

### S1 — Hero `#overview`
- Eyebrow: `macOS · Free · Bring your own AI`
- H1 (two lines, balanced):
  **Say hey.**
  **It's already looking.**
- Subhead: An AI buddy that lives in your Mac's notch. Hold a key, ask about anything on your screen, and it answers out loud — using the Claude or ChatGPT subscription you already pay for.
- CTAs: `Download free` (pill) · `See how it works ›` (scrolls to S3)
- Visual: `IMG-01` (MacBook Pro front-on, HeyMate notch pill expanded) with `VID-01` loop.
- Footnote under device (13px, `--fg-3`): Requires macOS 14.2 or later. Works on Macs with or without a notch.

### S2 — Statement band
Full-width, `--s-9` padding, single centered H2, no image.
> **Your Mac has had a blank spot at the top for years.**
> **We moved in.**

Body (subhead weight): No menu-bar clutter. No dock icon. HeyMate folds into the camera housing and expands only when you want it.

### S3 — Notch, sticky-scale scroll story
Sticky device frame left (or top on mobile); three text beats scroll past on the right, each cross-fading the screenshot.

| Beat | Eyebrow | H3 | Body | Image |
|---|---|---|---|---|
| 1 | Collapsed | Out of the way. | A quiet pill hugging the notch. Hover to peek, click to open. | `IMG-03` |
| 2 | Home | One glance, everything ready. | Ask HeyMate, drop files onto the shelf, start a timer, or open a door to Agents, Skills, and Settings. | `IMG-04` |
| 3 | Apps | Small apps for the space you never used. | File Shelf, Timers, Battery, Now Playing, Clipboard, Downloads, Camera Mirror. Turn on only what you want. | `IMG-05` |

### S4 — Three pillars grid
H2: **Three things it does that nothing else on your Mac does.**
Three equal cards, `IMG` top, H3, body.

1. `IMG-06` — **It sees what you see.** Hold <kbd>⌃</kbd><kbd>⌥</kbd>, ask "what's wrong with this error?", release. HeyMate looks at your screen only for that question, answers out loud, and points its cursor at what it means.
2. `IMG-07` — **It runs on your subscription.** Claude Code, Codex, or OpenCode — whichever you already have installed and logged in. No HeyMate account. No second API bill. Ever.
3. `IMG-08` — **It asks before it acts.** Agents plan read-only first. Nothing is written, clicked, or sent without an approval card. Every change is snapshotted so you can undo.

### S5 — Mates `#mates`
Two-column: text left, `IMG-09` right (mate rail with 4–5 faces).
- Eyebrow: Mates
- H2: **Not one assistant. A small team.**
- Body: Say "make me a mate that tracks my YouTube comments" and HeyMate creates one — with a name, a job, a personality, and a face. Give it a folder to work in. Give it a schedule. It'll report back in its own chat.
- Bullets (three, hairline separated):
  - **Souls.** Each mate has its own personality prompt and its own memory.
  - **Routines.** Daily at 9, or every 4 hours. Results land in the mate's chat, even while you're elsewhere.
  - **Faces.** Twenty built-in, or drop in your own.
- Secondary image below: `IMG-10` (face grid, 20 tiles).

### S6 — Connectors
H2: **Plugs into the apps you already use.**
Subhead: Apple Calendar, Reminders, Notes, Mail and Messages out of the box. Your local `gh`, `git`, `docker`, `kubectl`, `vercel`, `supabase` and `stripe` CLIs with your own logins. Any MCP server. And <span data-count="1400">1,400+</span> more through Composio.
Visual: `IMG-11` (connector logo marquee, two rows) + small callout card `IMG-12` (contextual "Connect YouTube to HeyMate" suggestion).
Micro-copy under marquee: Read-only calls run quietly. Anything that sends, deletes, or pays asks first.

### S7 — Agents `#agents`
Dark → **porcelain** section (`--porcelain` bg, `--ink` text) for contrast. This is the only light section.
- Eyebrow: Coding agents
- H2: **Real work. With a leash.**
- Body: "HeyMate agent, add dark mode to this project." HeyMate opens a sandbox in `~/Projects/heymate`, has Claude Code or Codex draft a plan, and shows you the plan before a single file changes. Approve it, walk away, and it keeps running even if you quit.
- Visual: `IMG-13` (notch Agents tab with a plan awaiting approval) beside `IMG-14` (three-step diagram: Plan → Approve → Run).
- Step strip (three columns, numbered 01/02/03): **Plan** — read-only inspection. **Approve** — you see the diff of intent. **Run** — background runner, undo snapshots, Terminal takeover anytime.

### S8 — Privacy `#privacy`
Back to obsidian. Centered.
- H2: **Nothing runs in the background.**
- Subhead (verbatim app copy): HeyMate only takes a screenshot when you press the hotkey, and screenshots are never stored.
- Four-up fact row (icon-less, hairline boxes):
  - **On your disk.** Chats, memory, mates, and routines live in `~/Library/Application Support/heymate/`. Text only.
  - **In your Keychain.** API keys and connector tokens never touch a HeyMate server — there isn't one.
  - **Excluded by default.** Password managers and System Settings are never captured.
  - **Invisible on calls.** One switch hides the notch and cursor from screen shares.
- Link: `Read the privacy notes ›` → `privacy.html`

### S9 — Setup
H2: **Free. Yours in two minutes.**
Three numbered steps, monospace command in a code chip:
1. **Download HeyMate** and drag it to Applications.
2. **Log in to one CLI you already own.** `claude auth login` · `codex login` · `opencode auth login`
3. **Hold <kbd>⌃</kbd><kbd>⌥</kbd> and say hey.**
Footnote: HeyMate is open source under the MIT license. It never charges you. Your AI provider bills you exactly as it did before.

### S10 — Final CTA
`--s-9` padding. Small app icon (`IMG-15`, 96px) above.
- H2: **Say hey.**
- CTA: `Download free` · `View on GitHub ›`
- Caption: macOS 14.2+ · Apple silicon and Intel · No account required

### S11 — Footer
- Left: Didot wordmark **HEYMATE** (32px, `--fg-2`), under it "Made for the Mac."
- Columns: Product (Overview, Mates, Agents, Privacy) · Developers (GitHub, README, MCP server docs `[TBD]`) · Legal (Privacy, MIT License)
- Bottom line: © 2026 HeyMate. Not affiliated with Apple, Anthropic, or OpenAI. Claude, ChatGPT, and macOS are trademarks of their respective owners.

### privacy.html
Reuse nav/footer. H1 "Privacy notes." Sections: What HeyMate captures · What it stores and where (table of files) · What leaves your Mac and when (CLI provider, optional cloud voice, Composio, analytics only if built with a key) · How to delete everything (`Settings → Memory → Delete everything`; delete the Application Support folder). Copy sourced from §1 and README; keep plain.

---

## 5. Screenshot capture plan (real app, done first)

Capture on a 14" or 16" MacBook Pro at 2× (Retina). Settings before capture:
- Dark mode. Wallpaper: solid black (`System Settings → Wallpaper → Colors → Black`) so composites are clean.
- Accent theme: **Iris** (`#8B7CFF`) so rim/cursor match the site accent.
- Menu bar: hide clock seconds, hide extra items (`⌘-drag` them out) — only Wi‑Fi, battery, clock.
- Turn on **Screen share stealth = off** (otherwise `screencapture` won't see the notch UI).
- Use `screencapture -x -R x,y,w,h out.png` for pixel-exact crops, or `⌘⇧5` window capture with shadow off.
- Seed realistic content first: 2 mates with faces, 1 routine, 5 chat sessions with sensible titles, 1 agent awaiting approval.

| ID | What to capture | Crop / size | Notes |
|---|---|---|---|
| `SS-01` | Collapsed notch pill, idle | 800 × 120 around notch | Ready dot visible |
| `SS-02` | Expanded notch **Home** tab | full card, ~1360 × 560 @2× | Match `heymate-brand-notch-final-dark.jpeg` state: "Ready when you are" card, composer, Doors row |
| `SS-03` | Expanded notch **Apps** tab | full card | File shelf with 2 files, a running timer, battery |
| `SS-04` | Expanded notch **Agents** tab, one plan awaiting approval | full card | Plan text should read like a real task (dark mode example from S7) |
| `SS-05` | Compact notch chat (⌃⌘) mid-answer | full card | Answer text visible, model chip visible |
| `SS-06` | Desktop window, Chat/Mate home, empty state | 1920 × 1290 @2× | The HEYMATE Didot empty state (see `heymate-hermes-source-port-final-dark.png`) |
| `SS-07` | Desktop window, mate rail with 4–5 mates | window | Faces: Lilac, Indigo, Coral, CuteGirl, Robot |
| `SS-08` | Mate settings sheet (name, job, soul, face, routine) | sheet only | One routine configured "Daily at 9:00" |
| `SS-09` | Face picker showing all 20 faces | grid only | |
| `SS-10` | Connectors view, Composio directory | window | Show mix: Calendar, GitHub, Notion, Slack, YouTube connected |
| `SS-11` | Contextual "Connect YouTube to HeyMate" suggestion card | card only | Trigger by opening youtube.com then ⌃⌘ |
| `SS-12` | Approval card for a destructive/external action | card only | e.g. "Send message in Slack?" with Allow / Deny |
| `SS-13` | Cursor buddy pointing at a UI element with caption bubble | 1200 × 700 region | Use Xcode error or a Finder window as subject |
| `SS-14` | Privacy settings pane (excluded apps, stealth toggle) | window | |
| `SS-15` | Settings → Brain picker (Claude / Codex / OpenCode / Custom) | pane | |
| `SS-16` | App icon | export `AppIcon-v8-celestial-dark.png` 1024 | already exists in `heymate/design/` |

Deliver to `website/assets/raw/SS-xx.png`. Do not retouch. These are inputs to §6.

---

## 6. Asset generation plan (AI image + real screenshot compositing)

Pipeline per asset: **real screenshot → placed into AI-generated hardware/scene → cleanup**. The UI must always be the real screenshot (never let the model hallucinate UI). Two techniques:

- **Method A — Composite**: generate the hardware/scene with a blank black screen, then place the screenshot in post (Figma/Photoshop/`ImageMagick`) with perspective transform. Most reliable; use for all device shots.
- **Method B — img2img (low strength 0.25–0.35)**: feed a rough composite in, let the model unify lighting/reflections. Only run on the *hardware*, mask the screen area as protected. Use Flux/Midjourney `--cref` or Nano Banana / gpt-image with the screenshot attached as reference and the instruction "keep the screen contents pixel-identical".

Global negative prompt: `text, letters, logos, watermark, people, hands, blurry, extra keyboards, distorted bezel, glare on screen, colorful RGB lighting, wood desk, plants, coffee cup`

Global style suffix: `Apple product photography, studio lighting, pitch black background, soft volumetric rim light, ultra-sharp, 8k, photoreal, centered composition, no props`

| ID | Slot | Prompt (Method) | Source screenshot | Output |
|---|---|---|---|---|
| `IMG-01` | S1 hero | (A) `A 14-inch MacBook Pro in space black, viewed straight on and slightly from above at 12 degrees, lid open at 105 degrees, screen completely black, the display notch clearly visible at the top center. Single soft violet rim light (#5E54FF) grazing the top edge of the lid and the keyboard deck, everything else fades into pure black. Floor is a black mirror with a faint 8% reflection of the laptop. Massive negative space above.` + suffix. Then composite `SS-02` into the notch region enlarged so the expanded card is legible; the rest of the screen stays black with a faint desktop-less glow. | `SS-02` | 2880 × 1800 PNG, WebP |
| `IMG-02` | S1 hero video poster | Same as `IMG-01` frame, collapsed state (`SS-01`) | `SS-01` | 2880 × 1800 |
| `IMG-03` | S3 beat 1 | (A) `Extreme close-up macro photograph of the top center of a MacBook Pro display in space black, the camera notch filling the frame, screen pitch black, thin violet light reflecting along the bezel edge, shallow depth of field.` + suffix. Composite `SS-01` pill exactly hugging the notch. | `SS-01` | 2400 × 1200 |
| `IMG-04` | S3 beat 2 | Same plate as `IMG-03`, composite `SS-02` expanded card dropping below the notch. | `SS-02` | 2400 × 1200 |
| `IMG-05` | S3 beat 3 | Same plate, composite `SS-03`. | `SS-03` | 2400 × 1200 |
| `IMG-06` | S4 card 1 | (A) `Isometric floating dark UI window on a black background, cropped tightly, no laptop, soft violet glow beneath it, slight 6 degree tilt, glass-like edge highlight.` Composite `SS-13` (cursor buddy pointing). | `SS-13` | 1600 × 1200 |
| `IMG-07` | S4 card 2 | (Pure design, no AI) Three terminal-style chips in a row on black: `claude`, `codex`, `opencode`, each with a green Ready dot, hairline borders, set in the site's type. Build in Figma. Below them `SS-15` brain picker cropped. | `SS-15` | 1600 × 1200 |
| `IMG-08` | S4 card 3 | (A) Same floating window plate as `IMG-06`. Composite `SS-12` approval card, large. | `SS-12` | 1600 × 1200 |
| `IMG-09` | S5 main | (A) `A 14-inch MacBook Pro space black, three-quarter view from the left, lid open, screen black, resting on a black mirror floor, violet rim light from upper right, deep black background.` + suffix. Composite `SS-07` full desktop window. | `SS-07` | 2400 × 1600 |
| `IMG-10` | S5 faces | (Pure design) 5 × 4 grid of the 20 mate faces from `Assets.xcassets/MateFace*.imageset/*.png`, 160px tiles, 24px gap, on `--bg-elev` with hairline. No AI. | asset PNGs | 2000 × 1600 |
| `IMG-11` | S6 marquee | (Pure design) SVG wordmarks/monochrome logos: Calendar, Reminders, Notes, Mail, Messages, Shortcuts, GitHub, Git, Docker, Kubernetes, AWS, Vercel, Supabase, Stripe, Notion, Slack, Gmail, Google Drive, YouTube, Linear, Figma, Postgres, Playwright, MCP. White at 60% opacity. Use official brand SVGs (simpleicons.org), check each license. | — | SVG sprite |
| `IMG-12` | S6 callout | Crop of `SS-11` on `--bg-elev` card, no AI. | `SS-11` | 1200 × 600 |
| `IMG-13` | S7 agents (light section) | (A) `A 14-inch MacBook Pro in silver, straight-on, lid open, screen black, on a seamless porcelain white (#F5F5F7) studio background, soft top light, gentle contact shadow underneath, no reflections.` + suffix (replace "pitch black background" with "porcelain white background"). Composite `SS-04` into the notch region. | `SS-04` | 2400 × 1500 |
| `IMG-14` | S7 diagram | (Pure design) Three ink-colored circles connected by hairlines: Plan → Approve → Run, with tiny captions. SVG. | — | SVG |
| `IMG-15` | S10 icon | Existing `AppIcon-v8-celestial-dark.png` at 1024, exported also 192/96 | existing | PNG |
| `IMG-16` | OG / social | (A) Reuse `IMG-01` plate, add wordmark "HeyMate" top-left in site type and tagline "Say hey. It's already looking." | `SS-02` | 1200 × 630 |
| `IMG-17` | Favicon | Cursor-arrow glyph from the icon on black, 32/180/512 | icon | ICO + PNG |

Delivery: `website/assets/img/IMG-xx.{png,webp}` plus `@1x` halves. All device images must have transparent or pure `#000000` surroundings so they blend into `--bg`.

### 6.1 Face asset note
Face PNGs live in `heymate/HeyMate/Assets.xcassets/MateFace*.imageset/mate-face-*.png`. Copy, do not regenerate.

---

## 7. Video plan

| ID | Slot | Spec | Prompt / storyboard |
|---|---|---|---|
| `VID-01` | Hero loop | 6s, 2880 × 1800, H.264 + WebM, ≤ 3 MB, muted, seamless loop | **Screen recording, not AI.** Record the real notch: 0.0–1.5s collapsed pill idle (Ready dot breathes) · 1.5–2.0s cursor moves up, pill expands · 2.0–4.5s Home card visible, composer placeholder cycles "Ask HeyMate…" · 4.5–5.5s collapses · 5.5–6.0s hold for loop. Record with `screencapture -v` or QuickTime at 60fps, crop to notch region, composite onto the `IMG-02` plate in After Effects/DaVinci with the same perspective as the still. |
| `VID-02` | S4 card 1 (optional hover) | 4s loop, 1600 × 1200 | Screen recording: hold ⌃⌥ (keycap overlay lights up), speak, cursor buddy flies to a Finder file and a caption bubble appears. Then fade. |
| `VID-03` | S7 (optional, light section) | 5s, 2400 × 1500 | Screen recording: Agents tab shows "Plan ready", user clicks Approve, status flips to Running, progress ticks. |
| `VID-04` | Launch / social (not on page) | 30s, 16:9 + 9:16 | AI-generated B-roll **only for hardware plates**; all UI from screen recordings. Beat sheet: 0–3s black, single violet line traces the notch outline · 3–6s "Your Mac has had a blank spot at the top for years." · 6–9s pill appears, "We moved in." · 9–15s three quick real-UI clips (Talk pointing, Mate creation, Agent approve) · 15–20s "Runs on the subscription you already have." with `claude`/`codex`/`opencode` chips · 20–25s "Nothing runs in the background." · 25–30s icon, "Say hey." + "Free for Mac". |

AI video prompt for `VID-04` hardware B-roll (Runway/Veo/Kling, 5s each, generate 4 variants, pick 1):
```
Cinematic slow dolly-in toward a space black MacBook Pro on a black mirror floor in a pitch black studio. Lid open, screen completely black. A single thin violet rim light slowly sweeps across the top edge of the lid, revealing the display notch. No text, no people, no reflections other than the floor. 24fps, shallow depth of field, Apple product film aesthetic, ultra clean.
```
Second B-roll:
```
Macro shot tracking slowly along the top bezel of a MacBook Pro display in the dark, the camera notch enters frame center, subtle violet glow pulses once beneath it like breathing. Pure black surroundings, photoreal, shallow focus, 24fps.
```
Never generate UI with AI video. Overlay the real recordings.

---

## 8. Build spec for the implementation model

### 8.1 Stack
- Plain **HTML + CSS + vanilla JS**. No framework, no build step required. (Reason: cheapest model, zero tooling risk.)
- Optional: Vite for dev server only. Deploy as static (Vercel/Netlify/GitHub Pages).
- Fonts: system stack (`-apple-system`) first; load **Inter** from Google Fonts as fallback with `font-display: swap`. Didot is system on macOS; fall back to Playfair Display.

### 8.2 File layout
```
website/
  index.html
  privacy.html
  css/
    tokens.css       ← §3.1 verbatim
    base.css         ← reset, type scale §3.2
    components.css   ← nav, buttons, cards, device frame, keycap
    sections.css     ← per-section layout S1–S11
    motion.css       ← §3.4 keyframes + reduced-motion
  js/
    main.js          ← IntersectionObserver fade-up, nav-shrink, count-up
    sticky.js        ← S3 sticky-scale progress
    config.js        ← export const DOWNLOAD_URL, GITHUB_URL
  assets/
    raw/             ← SS-xx (not deployed)
    img/             ← IMG-xx
    video/           ← VID-xx
    logos/           ← IMG-11 SVGs
  PLAN.md            ← this file
```

### 8.3 Responsive breakpoints
- ≥ 1280: full layout as specified
- 768–1279: H1 72px, two-column sections stack with image first, cards 1-col
- < 768: mobile type scale (§3.2), sticky-scale disabled → simple stacked images with fade-up, nav collapses links into a single `Menu` that toggles a full-screen list
- Device frames keep 16:10 ratio; never letterbox screenshots

### 8.4 Performance budget
- LCP image (`IMG-01`) ≤ 350 KB WebP, `fetchpriority="high"`, explicit width/height
- All other images `loading="lazy"`, `<picture>` with WebP + PNG fallback
- Total JS ≤ 12 KB; no third-party scripts
- Lighthouse ≥ 95 performance / 100 accessibility / 100 best practices / 100 SEO (desktop)

### 8.5 Accessibility
- All screenshots get real alt text describing the UI state (write from §5 table)
- Contrast: `--fg-2` on `--bg` = 7.4:1; `--fg-3` only for ≥ 13px captions
- Keyboard: nav and CTAs focusable, visible focus ring (`2px solid var(--accent)`, offset 3px)
- Videos muted, no autoplay when `prefers-reduced-motion`
- `<kbd>` for shortcuts

### 8.6 SEO / meta
- `<title>HeyMate — The AI buddy in your Mac's notch. Free.</title>`
- Description: `HeyMate lives in your MacBook's notch, sees your screen when you ask, talks back, and runs Claude Code, Codex, or OpenCode on your existing subscription. Free and open source for macOS 14.2+.`
- OG image `IMG-16`; `og:type website`; Twitter `summary_large_image`
- JSON-LD `SoftwareApplication`: name, operatingSystem `macOS 14.2+`, applicationCategory `UtilitiesApplication`, offers price `0` currency `USD`, license MIT URL

### 8.7 Acceptance checklist (build is done when all are true)
- [ ] Every section S0–S11 present with copy matching §4 character-for-character
- [ ] No price, "Buy", or "Pro" anywhere
- [ ] `DOWNLOAD_URL` set in one place and used by all three CTAs
- [ ] All `IMG-xx` slots wired with `<!-- IMG-xx -->` comments and placeholder black rectangles of the correct aspect until assets arrive
- [ ] Sticky-scale works at 1440 × 900 and degrades to stacked on mobile
- [ ] `prefers-reduced-motion` verified: no transforms, videos paused
- [ ] Lighthouse desktop ≥ 95/100/100/100
- [ ] `privacy.html` shipped and linked from nav, S8, footer
- [ ] Renders correctly in Safari 17, Chrome, Firefox
- [ ] Zero console errors; HTML validates

---

## 9. Open items (owner: you, before build)

1. **Distribution URL** — signed DMG on GitHub Releases, or "Get early access" fallback (§1).
2. **Domain** `[TBD]` — needed for OG/canonical tags.
3. **Screenshots** — capture §5 first; assets in §6 depend on them.
4. **Composio logo licensing** — confirm each third-party mark in `IMG-11` is used under its brand guidelines (nominative use, monochrome).
5. **Analytics** — leave out. Add PostHog/Plausible later only if wanted.
6. **Apple silicon vs Intel claim** in S10 caption — pbxproj has no arch restriction, but confirm an Intel build actually runs before shipping that line; otherwise change to "Apple silicon".
