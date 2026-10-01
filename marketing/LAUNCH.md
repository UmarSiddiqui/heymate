# HeyMate launch kit

Everything below is ready to paste. Post from your own accounts. Links:

- Repo: https://github.com/UmarSiddiqui/heymate
- Site + 38 s demo: https://getheymate.vercel.app/#demo
- Direct download: https://github.com/UmarSiddiqui/heymate/releases/latest/download/HeyMate.dmg
- Vertical video for X / TikTok / Reels / Shorts: `marketing/demo-video/out/heymate-demo-vertical-1080x1920.mp4`
- Landscape video: `marketing/demo-video/out/heymate-demo-1080p60.mp4`
- Looping GIFs: `docs/media/heymate-vision.gif`, `docs/media/heymate-agents.gif`

## Status (2026-09-28)

- Done: GitHub social preview, X thread + Boring Notch reply, Search Console on umarsiddiqui3037@gmail.com.
- PRs open: [awesome-mac #3055](https://github.com/jaywcjlove/awesome-mac/pull/3055), [open-source-mac-os-apps #1441](https://github.com/serhii-londar/open-source-mac-os-apps/pull/1441).
- You, by hand: awesome-claude-code (human-only web form, see below), Reddit (blocked for Claude's browser), Product Hunt (next week).
- LinkedIn: draft sits in the composer (not posted). Hotjar site 6785426 tracks getheymate.vercel.app; privacy page discloses it.
- Show HN blocked: HN is temporarily restricting Show HN posts from new accounts (umarsiddiqui303, karma 1). Comment genuinely for a couple of weeks, then retry. Don't drop the "Show HN" prefix to get around it.

**awesome-claude-code form** (https://github.com/hesreallyhim/awesome-claude-code/issues/new?template=recommend-resource.yml). One-line description, no pitch:

> Native macOS notch app that runs Claude Code behind a plan-then-approve gate: the CLI plans read-only, the user approves, then the same session resumes with write access after an undo snapshot. Uses the user's existing Claude subscription.

## Before you post (10 minutes)

1. **GitHub social preview:** Repo → Settings → General → Social preview → Upload `docs/media/github-social-preview.png`. This is the card people see when the repo link is shared.
2. **Pin the repo** on your GitHub profile.
3. **Add music to the video** if you have a licensed track (see `marketing/demo-video/README.md`). Silent is fine for X, where most people watch on mute.
4. **Test the download on a clean Mac account**, including the Control-click → Open step, so the first 50 people don't hit something you've never seen.

## Order that tends to work

1. **Hacker News (Show HN)** on a Tuesday–Thursday, 8–10 am US Pacific. From Perth that's 11 pm–1 am. Stay online for 3 hours to answer every comment.
2. **X thread** the same hour, with the vertical video attached natively (don't link to it).
3. **Reddit:** r/macapps first, then r/ClaudeAI and r/ChatGPTCoding a day later. One subreddit per day reads less spammy.
4. **Product Hunt** a week later, once there are stars and comments to point at.
5. **Awesome lists** (PRs): `jaywcjlove/awesome-mac` (AI tools section), `serhii-londar/open-source-mac-os-apps`, `hesreallyhim/awesome-claude-code`.

---

## Angle: "Boring Notch, plus an AI"

People who already love notch apps are the easiest audience. Lead with: *everything you use a notch app for (music, calendar, file shelf with AirDrop, battery, volume HUD, mirror), plus an AI that sees your screen and runs your coding agents.* Keep it factual: HN commenters will check. As of v1.0.2, HeyMate covers every shipped Boring Notch feature (music with album art and visualizer, calendar, AirDrop shelf, battery, volume/brightness/keyboard-backlight HUDs, Bluetooth activity, mirror). Weather is on Boring Notch's roadmap and not in either app. The comparison table is in the README.

X reply to add under the thread:

> If you use Boring Notch: HeyMate does all the notch stuff too (music with album art + visualizer, calendar, AirDrop shelf, battery, volume/brightness HUDs, Bluetooth, camera mirror), then adds timers, clipboard history, and an AI that can see your screen and run Claude Code for you. MIT licensed.

## Show HN

**Title** (80 characters max):

> Show HN: HeyMate – an AI buddy in your Mac's notch that uses your own Claude/Codex CLI

**Text:**

> Hi HN, I built HeyMate, a free, open-source macOS app that lives in the notch.
>
> You hold Control + Option, ask about something on screen ("why is my Mac so slow?"), and it answers out loud while its cursor flies to the thing it means. It only takes a screenshot when the question needs one, and screenshots are never stored.
>
> The part I cared most about: it runs on the Claude Code, Codex, or OpenCode CLI you're already signed in to, so there's no HeyMate account and no second API bill. It actively strips ANTHROPIC_API_KEY / OPENAI_API_KEY from the child process so you can't get switched to metered billing by accident.
>
> Coding agents are approval-gated. The CLI first writes a plan with writes disabled, you approve it, and only then does HeyMate resume the same session with write access, after taking an undo snapshot. Approved work moves into a separately signed helper, so it survives quitting the app.
>
> Other bits: "mates" (small persistent helpers with their own memory, folder, and schedule), notch micro-apps (file shelf, timers, clipboard), and connectors (Apple apps, local CLIs, MCP).
>
> It's native SwiftUI, MIT licensed, macOS 14.2+. Builds aren't Developer ID-signed yet, so first launch is Control-click → Open. Every push to main builds and publishes a release automatically.
>
> 38-second demo: https://getheymate.vercel.app/#demo
> Code: https://github.com/UmarSiddiqui/heymate
>
> I'd love feedback on the approval flow and on what you'd want it to see and not see.

## X / Twitter thread

Attach the **vertical video** to post 1.

1. > I put an AI in my MacBook's notch.
   >
   > Hold ⌃⌥, ask "why is my Mac so slow?", and the cursor flies to the app hogging your CPU and tells you out loud.
   >
   > Free, open source, and it runs on the Claude/Codex subscription you already pay for. 🧵

2. > It lives where your Mac has had a blank spot for years. No dock icon, no menu-bar clutter. Hover the notch → Home, Apps, Agents.

3. > It hands real coding work to Claude Code, Codex, or OpenCode, with a leash:
   >
   > 1. the agent plans read-only
   > 2. you approve
   > 3. only then can it write, with an undo snapshot first
   >
   > (attach heymate-agents.gif)

4. > "Mates" are small persistent helpers: a name, a job, their own memory and folder, and a schedule. Mine reads my YouTube comments every morning at 8:30.

5. > No HeyMate account. No HeyMate server. Chats and memory stay on your Mac, keys stay in Keychain, screenshots are never stored.
   >
   > Download (macOS 14.2+): https://github.com/UmarSiddiqui/heymate
   >
   > A ⭐ genuinely helps.

## r/macapps

**Title:** I made a free, open-source AI assistant that lives in the MacBook notch (uses your existing Claude/ChatGPT CLI, no extra subscription)

> HeyMate folds into the notch and opens on hover. Hold Control + Option to ask about anything on screen; it answers out loud and points its cursor at what it means.
>
> - Runs on the Claude Code, Codex, or OpenCode CLI you already have. No account, no API bill from me.
> - Notch micro-apps: file shelf, focus timer, clipboard history, now playing, downloads, camera mirror.
> - Coding agents that must show you a plan and get approval before changing a file, with undo.
> - Local-first: chats and memory stay on your Mac, and screenshots are never saved.
>
> Free and MIT licensed, macOS 14.2+ (Intel and Apple silicon). It isn't notarized yet, so it needs Control-click → Open the first time. Happy to answer anything about permissions or privacy.
>
> Demo + download: https://getheymate.vercel.app

## r/ClaudeAI

**Title:** I built a Mac notch app that drives Claude Code with a plan-then-approve gate, on your normal Claude subscription

> Talk to it (push-to-talk), it can see your screen when you ask, and "HeyMate agent, add dark mode to this project" spins up a sandbox where Claude Code writes a read-only plan. Nothing touches disk until you approve; then it resumes the same session with writes enabled, after an undo snapshot.
>
> It uses `claude auth login --claudeai`, so it's your subscription, not Console billing, and it strips API-key env vars from the child so you can't get metered by accident. Open source (MIT): https://github.com/UmarSiddiqui/heymate

## Product Hunt

- **Name:** HeyMate
- **Tagline** (60 characters max): *The AI buddy that lives in your Mac's notch*
- **Description:** Hold ⌃⌥ and ask about anything on screen. HeyMate answers out loud, points at the answer, and runs Claude Code, Codex, or OpenCode agents that plan first and wait for your approval, all on the subscription you already have. Free and open source.
- **Topics:** Mac, Artificial Intelligence, Developer Tools, Open Source, Productivity
- **Gallery:** og-card.jpg, then the landscape video, then the website screenshots.
- **Maker comment:** reuse the Show HN text.

## Replies to have ready

- **"Is it safe to give it Accessibility and Screen Recording?"** It captures only when a question needs sight. Password managers and System Settings are excluded, screenshots are deleted after the turn, there's no server, and the code is open.
- **"Why not notarized?"** It will be once there's a Developer ID account. Until then every build is made on GitHub Actions from public source, with a SHA-256 next to each DMG.
- **"Windows/Linux?"** No. It's built around the Mac notch and macOS APIs.
- **"Does it cost anything?"** No. Your AI provider bills you exactly as before.
