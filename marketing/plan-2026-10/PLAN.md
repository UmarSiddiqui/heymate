# HeyMate marketing plan: Thu 15 Oct to Wed 11 Nov 2026

Draft written 2026-10-14. Nothing here has been posted, sent, published, deployed or submitted. You post everything yourself.

Related files in this folder:

- `copy/`: ready-to-paste drafts (X, LinkedIn, Show HN, Reddit, Product Hunt, outreach, README hero, directory blurbs)
- `assets-brief.md`: every screenshot, GIF and clip to capture, with scene and aspect ratio
- `website-suggestions.md`: proposed edits to `website/index.html` (not applied)

---

## 0. Where things stand (checked 2026-10-14)

| Item | State | Source |
|---|---|---|
| Latest release | v1.0.59 (13 Oct): welcome tour, paste images into chat, one Integrations page | `gh release list` |
| GitHub | 2 stars, 1 fork. Last 14 days: 97 views, 28 unique visitors. Referrers: github.com, the site, wangchujiang.com (awesome-mac), Google | `gh api .../traffic` |
| DMG downloads | 70 across all releases, 3 on v1.0.59. This count includes auto-update downloads, so it overstates new installs. | release assets |
| awesome-mac #3055 | **Merged on 29 Sep.** It's already sending visitors. LAUNCH.md and the brief still call it open. | `gh pr view` |
| open-source-mac-os-apps #1441 | Open with no review since 28 Sep. It's mergeable. That repo merges in batches. | `gh pr view` |
| X | Pilot post and release/video post published (LAUNCH.md). About 3 followers. | LAUNCH.md |
| LinkedIn | Launch post live since 29 Sep with the old video. Leave it alone. | brief |
| Show HN | Blocked: the account `umarsiddiqui303` is too new | brief |
| Website "What's new" | **Stale.** It stops at 1.0.51, while 1.0.55 and 1.0.59 shipped. | `website/index.html` |
| PR #55 (draft) | Live faces, floating agent cards, v5 sounds, Permissions tab. Not merged. QA and the test suite are still open. | `gh pr view 55` |
| Analytics | Vercel Web Analytics (cookieless) with `download_click`, `github_click`, `install_copy`, `brew_copy` events. Hotjar 6785426 runs alongside it. | `website/js/*.js` |

**Positioning gap to fix first.** README.md, website/index.html and LAUNCH.md all lead with "Learn your software. One step at a time." and call HeyMate "the open-source alternative to ReferenceRenderer". The README GIF example is "why is my Mac so slow?". All three conflict with your current rules: lead with the general capability, keep it from sounding like a Mac-optimisation tool, and keep ReferenceRenderer out unless verified. See §7 and `website-suggestions.md`.

---

## 1. Goals and metrics (4 weeks, 15 Oct to 11 Nov)

The goal is to get about 100 real people to try "hold ⌃⌥ and ask", and to learn where they get stuck, before any big launch. Stars follow from that.

| Metric | Baseline (14 Oct) | Target by 11 Nov | Stretch | Where to read it |
|---|---|---|---|---|
| GitHub stars | 2 | 50 | 150 (if Show HN reaches the front page) | repo page |
| Unique repo visitors / 14 days | 28 | 400 | 1,500 | GitHub Insights → Traffic |
| Site unique visitors / week | pull from Vercel | 300 per week | 1,000 in Show HN week | Vercel Analytics |
| Install intent (`download_click` + `install_copy` + `brew_copy`) | pull from Vercel | 150 total | 400 | Vercel Analytics events |
| New installs (proxy) | about 0 per week | 60 | 150 | DMG downloads on the newest release, minus about 3 per release for your own machines and updaters, plus Homebrew |
| Pilot testers who finish one ask-and-point task | 0 | 8 of 10 | n/a | your pilot form or notes |
| Outside issues or PRs | about 0 | 5 issues, 1 PR | 3 PRs | GitHub |
| HN account karma | low or new | enough that Show HN submits | n/a | HN profile |

Hotjar (6785426): use it to see behaviour, not to count. Each week:

1. Check the hero scroll-depth heatmap. Do people reach `#install`?
2. Watch 5 recordings from campaign traffic (filter by UTM landing URL).
3. Note the furthest point people reach before leaving.

Tag the Hotjar funnel: hero → `#tour` play → `#install` → copy or download.

**UTM convention:** `utm_source=<x|linkedin|reddit|hn|ph|email|github>&utm_medium=<social|community|listing|outreach>&utm_campaign=<short_name>`. HN and GitHub links stay bare. HN readers dislike tracking parameters, and the referrer header covers them.

---

## 2. Audience segments

Order matters. Talk to the first two first.

1. **People who already pay for Claude or ChatGPT and want more from it.** They chat in a browser tab and paste screenshots. The hook: "your plan, in the notch, can see your screen". Find them in r/ClaudeAI, the Claude and ChatGPT parts of X, and LinkedIn's AI-curious professionals.
2. **Mac power users and notch-app fans.** They install menu-bar and notch utilities, and they like native SwiftUI and open source. Find them in r/macapps (megathread), awesome-mac (merged), open-source-mac-os-apps, Boring Notch users, and Mac productivity YouTube.
3. **People learning or using unfamiliar software.** They have creative tools, spreadsheets and admin websites open and get stuck on "where is that setting?". Walkthroughs are one thing to show them, not the pitch. Reach them through tutorial creators (§4, outreach) and later Product Hunt.
4. **Open-source and privacy-minded developers.** They care about MIT, local data, the no-metered-billing design and voice models running on the device. Reach them through Hacker News, GitHub and r/opensource. Talk to them about the architecture, not about coding agents as the product.
5. **People who prefer voice (secondary).** They'd rather talk and listen than type. Use the on-device Parakeet/Kokoro and Mac voices. Don't make accessibility claims until someone tests with real assistive-tech users.

Not a target: "AI coding agent" shoppers. Agents and routines are a second act, so mention them after the core ask.

---

## 3. Message

**Core message (use everywhere first):**

> Hold ⌃⌥ and ask about anything on your screen. HeyMate answers out loud and points at what it means. It lives in your Mac's notch, runs on the Claude or ChatGPT plan you already have, and is free and open source.

Demo examples always come after the core message, phrased "Here I asked…". Pick a variety: a confusing setting on a website, a chart in a spreadsheet, a menu in a creative app, a sentence in a PDF. Avoid Activity Monitor and "my Mac is slow", and don't lead with coding.

**Proof points, in order:** asks by voice → looks at the screen → answers out loud → points with the cursor → uses your existing plan through official CLIs, with no metered keys → MIT and native SwiftUI → agents and routines that ask before they send, delete or pay → on-device voice option.

**Three alternate hooks:**

1. **"Stop pasting screenshots into a chat window."** This names a pain everyone has felt and needs no explanation. Best for X, Reddit and the PH tagline.
2. **"An AI that points."** The pointer is the most visual, most memorable element. Best for short clips, GIFs and the first second of any video.
3. **"You already pay for Claude. Let it live in your notch."** Bring your own subscription, with no new bill. Best for r/ClaudeAI, HN (state it plainly) and LinkedIn.

Backup hook for the second act, once agents land: "A small team in your notch that asks before it acts."

**Words to avoid:** "ReferenceRenderer alternative" (pending §7), "optimise your Mac", "AI coding assistant", "revolutionary", "best", unqualified "always-on". Don't say "it sees everything" either; the screen is captured when you ask.

---

## 4. 4-week channel calendar

One clear call to action per post. Every clip that is recreated rather than recorded keeps its label. Any post using a Meet HeyMate video carries the Peyruis credit block (in `copy/x-posts.md`).

### Week 1: Thu 15 Oct to Wed 21 Oct. Fix the front door and start earning accounts.

| Day | Channel | Action | Who |
|---|---|---|---|
| Thu 15 | Decision | Decide the ReferenceRenderer question (§7) and approve or edit `website-suggestions.md` and the README hero (`copy/readme-hero.md`). | You |
| Thu 15 to Fri 16 | Repo and site | Apply the approved edits on a branch in a separate session. Bring "What's new" up to 1.0.59. | Claude preps, you approve; you deploy and repoint `getheymate.vercel.app` |
| Daily | HN | Start real comment history: 1–2 thoughtful comments a day on macOS, Swift, local AI or accessibility threads where you know something. Don't link HeyMate or mention it. | You |
| Daily | Reddit | Comment helpfully in r/macapps and r/ClaudeAI, with no links. Goal: 10+ karma before any Reddit promo. r/ClaudeAI needs 50 total karma for a feed showcase; below that, it routes you to the megathread. | You |
| Fri 16 | Capture | Record **Clip A**, the core ask-and-point (`assets-brief.md`). Computer-use can't drive HeyMate, so this one is yours. | You record, Claude edits captions |
| Sat 17 | Pilot | DM or email 10 people you know who use a Mac. Give them one task: "ask about something confusing on a page you have open". Track installs, the first answer, and any second use within 7 days. | You |
| Mon 19 | X | Post **X1** with Clip A natively. | You |
| Tue 20 | List | Comment politely on open-source-mac-os-apps #1441: is anything needed to merge? | You |
| Wed 21 | Directory | Submit to awesome-claude-code through its human web form, using `copy/directories.md`. | You (web form only) |

### Week 2: Thu 22 Oct to Wed 28 Oct. Your existing network, then the first community.

| Day | Channel | Action | Who |
|---|---|---|---|
| Thu 22 | X | **X2** (screenshots hook) with Clip B, a "here I asked" example. | You |
| Fri 23 | Pilot | Collect pilot results. Turn every repeated blocker into an issue. | You and Claude (issue drafts) |
| Sat 24 | X | **X3** (bring your own plan), with Still S3 from `assets-brief.md`. | You |
| Tue 27 | LinkedIn | Post the follow-up from `copy/linkedin-followup.md`. It's a new post; the 29 Sep post stays as it is. | You |
| Wed 28 | Reddit | If you have the karma: **r/ClaudeAI** showcase (`copy/reddit-posts.md`, post 2), on the feed or in the megathread depending on karma. | You by hand |
| Through the week | Creators | Send 5 personalised emails (`copy/creator-outreach.md`). Each one names a specific video of theirs that you actually watched. | You |
| Through the week | Release | If a release ships, run the pipeline in §5. | Claude preps |

### Week 3: Thu 29 Oct to Wed 4 Nov. Mac community, and #55 if it ships.

| Day | Channel | Action | Who |
|---|---|---|---|
| Thu 29 | X | **X4** (agents in one sentence) with Clip D. | You |
| Sun 1 to Mon 2 Nov | Reddit | **r/macapps** November "App Pile" megathread entry, in Problem/Comparison/Pricing format (`copy/reddit-posts.md`, post 1). Post early in the month for the longest visibility. This counts toward their 30-day promotion limit. | You by hand |
| When #55 merges and the release is live | Capture | Record Clips E–G (faces, floating cards, sound tour). See the "after #55" section of `assets-brief.md`. | You record, Claude cuts |
| Release day for #55 | X and site | Post **X5** (faces, cards, sounds; with sound) and update the changelog. | You post; Claude preps |
| Tue 3 Nov | HN check | Try opening the Show HN submit page with the title from `copy/show-hn.md`. Don't submit yet unless week 4's readiness gate is already met. | You |

### Week 4: Thu 5 Nov to Wed 11 Nov. Show HN, if unlocked.

**Show HN readiness gate.** All of these must be true:

- HN accepts the submission.
- The README hero is updated.
- A fresh-Mac-account install test has passed. Document the "Open Anyway" step.
- Clip A is embedded in the README.
- You have a free 5-hour window to answer comments.

| Day | Channel | Action | Who |
|---|---|---|---|
| Tue 10 or Wed 11 Nov, 8–9 am US Pacific | HN | Submit the Show HN, using the title and first comment from `copy/show-hn.md`. Stay in the thread for the first 4–6 hours. Don't ask anyone to upvote. | You |
| Same day | X | One quiet "I posted a Show HN" post is fine. Don't solicit votes. | You |
| Next 2 days | GitHub | Triage HN feedback into issues and reply to every one. | You and Claude |
| Thu 5 to Fri 6 | Product Hunt | Prepare the PH listing in a draft (`copy/product-hunt.md`) and pick a launch date 2–3 weeks after HN. Best is a Tue–Thu at 12:01 am PT, with #55 shipped and HN fixes in. | You (account and scheduling); Claude (copy, gallery) |

**If Show HN is still blocked in week 4,** keep commenting. Email hn@ycombinator.com and politely ask when a new account can post a Show HN. That's asking, not working around the rule. Never drop the "Show HN" prefix, never post it as a plain link, and never post from another account. Move HN into the PH window, or after it.

### After week 4

- Product Hunt launch, gated on #55 shipped plus HN learnings.
- A second video channel: a YouTube Short or a TikTok of Clip A in a 9:16 cut.
- r/opensource or r/SideProject as a backup community, if the first two posts landed well.

---

## 5. Content pipeline tied to releases

Every app release (push to main → Release run → approve the `release` environment → DMG published):

| Step | What | Who |
|---|---|---|
| 1 | Read the real version with `gh release list --limit 1`. Don't guess; it's MARKETING_VERSION plus the run number. | Claude |
| 2 | Write plain-language bullets for `website/changelog.html` (full) and the `#changelog` top three in `index.html`. | Claude drafts, you approve |
| 3 | Deploy the website, then run `vercel alias set <new-url> getheymate.vercel.app`. | You (Release Captain reminds you) |
| 4 | If the release has a visible change: one X post (280 characters or fewer) with one 6–12 s silent GIF or MP4 of that change. Use the template in `copy/x-posts.md`. | Claude drafts and cuts; you record and post |
| 5 | If the UI visibly changed: refresh the README GIF or still, and the site screenshot. New filenames, because `/assets/*` is cached as immutable. | Claude (stills via the screencapture helper where possible) |
| 6 | Weekly: link a "What shipped this week" note from the GitHub release body to the site changelog. | Claude |
| 7 | Monthly: one LinkedIn post summarising the month, with a real clip and no music unless it carries the credit. | You post; Claude drafts |

Release tiers:

- **Patch** (fixes): changelog only.
- **Feature** (a visible change): changelog and one X post.
- **Moment** (#55 faces, cards and sounds; anything with a new face on screen): changelog, X, a LinkedIn monthly mention, new clips, a README GIF swap, and a Product Hunt candidate.

---

## 6. Who does what

**Only you can do these** (accounts, posting, recording, judgment):

- Post every X, LinkedIn, Reddit, HN and PH item, and send every email.
- Build HN and Reddit comment history. Do it genuinely; Claude must not write comments for you to farm karma.
- Record real screen clips with your voice or the app's voice. Computer-use can't drive HeyMate.
- Submit the awesome-claude-code web form and create or schedule the Product Hunt account and launch.
- Approve website edits, deploy, and repoint the alias.
- Decide the ReferenceRenderer question.
- Run the pilot and talk to testers.

**Claude can prepare:**

- All drafts in `copy/`, rewritten per release.
- Character counts and UTM links.
- Changelog bullets.
- Captions and SRT files, and trims and crops of your recordings with ffmpeg.
- Remotion renders, clearly labelled as recreated.
- Still screenshots through the screencapture helper.
- A README and website edit branch, without committing to `main` unless you approve.
- Issue drafts from pilot or HN feedback.
- Weekly metric pulls (`gh` traffic, release downloads, read-only Vercel analytics).

---

## 7. Open questions and risks

1. **ReferenceRenderer in public copy (decision needed).**
   - **Current state.** README.md, website/index.html and marketing/LAUNCH.md all say "the open-source alternative to ReferenceRenderer". So do the `<meta>` keywords, the description, OG and Twitter tags, and the footer.
   - **Overlap.** Third-party listings describe ReferenceRenderer as a YC Spring 2026 Mac product. It has a hotkey to see your screen, voice answers, an on-screen pointer, a "Mate agent" voice trigger for background tasks, macOS 14.2+, and paid tiers. HeyMate overlaps closely, down to the minimum macOS version and the "HeyMate agent, …" phrasing in the README.
   - **What I couldn't verify.** I didn't confirm feature parity from primary sources. Most results were aggregators.
   - **Recommendation.** Remove "ReferenceRenderer" from all public copy and meta until you've done your own primary-source check, ideally with someone qualified to advise on comparative advertising and trademark use. Position on HeyMate's own merits.
   - **What to expect.** Commenters on HN and r/macapps will likely raise it themselves. `copy/show-hn.md` has a neutral answer, marked "don't post until you decide".
   - **Also review** the "HeyMate agent, …" voice phrase.
2. **r/macapps requires a "Comparison".** Their megathread format is Problem / Comparison / Pricing. The draft compares against generic workflows (pasting screenshots into a chat app) and against notch utilities, and names no competitor. Check that this satisfies the mods.
3. **Recreated vs real footage.** Every current video is recreated UI. Show HN and PH audiences will ask whether it really points. Get Clip A recorded for real before HN, and keep the "Recreated" label on anything else.
4. **Install friction.** The app is self-signed and not notarized, so first launch needs "Open Anyway", and it asks for 5+ permissions. HN and PH visitors bounce here. Lead the install section with the `brew` and `curl` lines, be upfront about why, and make the fresh-account install test a gate.
5. **Download counts overstate installs.** The auto-updater also fetches release assets. Use the website events plus the pilot as the real signal.
6. **Coming-soon features.** Don't post about faces, floating cards or sounds as available until #55 merges and a release ships. X5 and the post-#55 assets stay gated.
7. **Mates vs agents naming.** The app and site say "agents"; PR #55 says "mate faces". Pick one public word before #55's posts. The drafts use "agents".
8. **Reddit spam filters.** Drafts avoid em dashes and AI-ish formatting, because r/macapps mods say those raise removal odds. Edit them into your own voice before posting.
9. **LAUNCH.md is out of date.** It still says awesome-mac is open and uses the old positioning. It wasn't edited (the brief only allowed new files). Update it when the checkout is free.
10. **Rules checked through mirrors.** Reddit rules came from mirrors; Reddit blocks fetching directly. Re-read each subreddit's sidebar and pinned posts the day you post.

Sources consulted (read-only):

- HN Show HN guidelines: https://news.ycombinator.com/showhn.html
- HN FAQ: https://news.ycombinator.com/newsfaq.html
- r/macapps App Pile megathread rules, via mirror: https://redlib.groet-infra.nl/r/macapps
- r/ClaudeAI showcase megathread note on 50 karma, via mirror: https://redlib.groet-infra.nl/r/ClaudeAI/comments/1sly3jm/built_with_claude_project_showcase_megathread/
- Product Hunt specs (third-party guides): https://app.getlaunchlist.com/blog/how-to-launch-on-product-hunt-2026 and https://screenhance.com/blog/product-hunt-launch-checklist-2026
- ReferenceRenderer descriptions (third-party): https://moge.ai/product/reference-renderer and https://www.voiceos.com/compare/reference-renderer-windows
