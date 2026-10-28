# Website suggestions for `website/index.html` (not applied)

These edits are proposed only. Apply them later on a branch in a separate session, after you approve. Then deploy and run `vercel alias set <new-url> getheymate.vercel.app`; the alias doesn't move on its own.

Edits are grouped by priority, and line numbers refer to `website/index.html` as of 14 Oct.

## P0: positioning and accuracy (do these before any campaign traffic)

### 1. Remove ReferenceRenderer from public copy, pending your decision (PLAN.md §7)

| Where | Current | Suggested |
|---|---|---|
| `<meta name="description">` | "…The open-source alternative to ReferenceRenderer—bring your own…" | "Hold ⌃⌥ and ask about anything on your screen. HeyMate answers out loud and points. It lives in your Mac's notch and runs on the Claude, ChatGPT or OpenCode plan you already have. Free and open source (MIT) for macOS 14.2+." |
| `<meta name="keywords">` | starts "HeyMate, ReferenceRenderer alternative, …" | "HeyMate, AI for Mac screen, ask about my screen, MacBook notch app, voice assistant for Mac, push to talk AI, Claude for Mac, ChatGPT for Mac, open source macOS app" |
| `og:description` | "…Open-source alternative to ReferenceRenderer…" | "Ask about anything on your screen. HeyMate answers out loud and points. Runs on the Claude or ChatGPT plan you already have. Free, open source, macOS." |
| `twitter:title` | "HeyMate — Learn your software. One step at a time." | "HeyMate: ask about anything on your screen" |
| `twitter:description` | "…Open-source ReferenceRenderer alternative…" | Same text as `og:description`. |
| Hero `.small`, line 75 | "Free and open source (MIT). The open-source alternative to ReferenceRenderer. macOS 14.2 or later." | "Free and open source (MIT). macOS 14.2 or later, with or without a notch." |
| Footer `.legal`, line 414 | "Not affiliated with Apple, Anthropic, OpenAI, or ReferenceRenderer." | "Not affiliated with Apple, Anthropic, or OpenAI." If you keep any comparison anywhere, keep the non-affiliation line. |

`website/llms.txt` also mentions ReferenceRenderer; update it too. `how-to-use-heymate.html`, `privacy.html`, `permissions.html` and `changelog.html` don't mention it. The OG image text still needs a check.

### 2. Hero: lead with the general capability

The current hero:

- **Kicker:** "Claude and ChatGPT are already great."
- **H1:** "a more fun way to use them."
- **Tagline:** "Learn an app. Ask about anything…"

That's charming, but it makes visitors work out what the app does. Suggested:

```html
<p class="kicker">Lives in your Mac's notch.</p>
<h1>Ask about anything<br>on your screen.</h1>
<p class="tagline">It answers out loud and points at what it means.</p>
<p class="lede">Hold ⌃⌥, ask, let go. HeyMate looks at the screen for that question, talks you through the answer, and moves a pointer to the spot. No screenshots, no switching windows.</p>
<p class="ask-line">Hold <kbd data-key>⌃</kbd><kbd data-key>⌥</kbd> and ask.</p>
<p class="byo-line"><span class="label">bring your own ai</span> Runs on the Claude, ChatGPT, or OpenCode plan you already have. No HeyMate subscription, no metered keys.</p>
```

- If you want to keep the "fun" animation, move "A more fun way to use the AI you already pay for" down to the `#ai` section heading.
- Update `<title>` to "HeyMate: ask about anything on your Mac screen".

### 3. Label the hero demo as an example

The interactive video-editor demo is fine as *one* example. Add a caption under `.screen`:

```html
<p class="small demo-note">Example. Here I asked: “How do I cut the intro off this video?” Recreated interface; try it with the keys above.</p>
```

### 4. Bring "What's new" up to date (it stops at 1.0.51)

Replace the three items in `#changelog` with 1.0.59, 1.0.55 and 1.0.51. Mirror them into `changelog.html` too, per the changelog rule. Draft bullets from the v1.0.59 release notes:

- **1.0.59:**
  - **A welcome tour.** First launch walks you through the notch, ⌃⌥, and your first question.
  - **Paste images into chat.** Drop a screenshot or picture straight into the chat box.
  - **One Integrations page,** and jobs now live with the agent that runs them.
- **1.0.55:** Maintenance build (dependency updates). List it on the full changelog only, and keep 1.0.51 in the top three instead.

Check each bullet against the app before publishing.

### 5. Replace the README and website Mac-slow example

`docs/media/heymate-vision.gif` and `clip-vision-v2.mp4` (if used anywhere on the site) show the Activity Monitor "why is my Mac so slow?" scene. Swap in Clip A once it's recorded (`assets-brief.md`). Use new filenames, because assets are cached as immutable.

## P1: structure

### 6. Add a "What people ask" strip right after the hero

This broadens the use cases without a pitch per scenario. Use six small cards with matte surfaces and one accent, each labelled "Here I asked…":

- "What does this setting actually do?" (web dashboard)
- "Which of these numbers is the total?" (spreadsheet)
- "Where's export?" (an app you rarely use)
- "What does this paragraph mean in plain English?" (PDF)
- "Walk me through this, one step at a time." (any app; links to `#walkthrough`)
- "Remind me to reply to this tomorrow at 9." (Reminders integration)

Only list questions you've tried on the current build.

### 7. Reorder the sections

| | Current | Suggested |
|---|---|---|
| 1 | Hero | Hero |
| 2 | #walkthrough | **What people ask** (new) |
| 3 | #ai | #ai (Bring your own AI) |
| 4 | #agents | #walkthrough (renamed "Step by step, when you need it") |
| 5 | #builder | #tour (the video, moved up) |
| 6 | #integrations | #agents and #builder |
| 7 | #tour | #integrations |
| 8 | #privacy | #privacy |
| 9 | #changelog | **FAQ** (new) |
| 10 | #install | #install |
| 11 | finale | #changelog, then finale |

Why:

- Visitors from X, HN and Reddit decide in the first two screens, so show the capability, the range of uses and the "no new bill" point there.
- Walkthroughs are a deeper feature.
- The video is the second-best proof after the hero, so it belongs higher.
- Update the nav to match: How it works → "What you can ask", plus Your AI, Agents, Privacy, What's new, GitHub.

### 8. Add an FAQ section

This answers the questions HN, PH and Reddit will ask. Use `<details>` items:

- **Is it free?** Yes, MIT. You use your own Claude or ChatGPT plan, or a local or API model. Provider limits apply.
- **What does it send, and where?** Your question plus a screenshot, only when you ask (and between walkthrough steps). It goes to the AI provider you chose. HeyMate has no server for your chats.
- **Why does macOS warn me on first launch?** The builds are self-signed, not notarized; there's no Apple Developer ID yet. Use the one-line installer or Homebrew, or "Open Anyway". The source and SHA-256 are on GitHub.
- **Does it need a notch?** No. Other Macs get a small pill at the top centre.
- **Which models can see the screen?** Vision-capable Claude, ChatGPT, OpenCode or API models. Apple Intelligence is text only.
- **Can it act on its own?** Agents plan first and ask before anything that sends, deletes or pays.
- **Can it run offline?** Voice can run on-device (Parakeet and Kokoro). Answers need your chosen model, which can be local through an OpenAI-compatible server.

Add `FAQPage` JSON-LD to `<head>` for search. It's free, and Search Console is already verified.

### 9. Install section

- Keep "Recommended: paste one line". Add one sentence of reassurance under it: "The script is about 60 lines; read it on GitHub." (`install.sh` was 60 lines on 14 Oct.)
- Add a single "Star on GitHub" button in the finale only, not the hero, to keep one CTA per screen. It should fire the existing `github_click` event.

## P2: polish and measurement

10. **One accent.** Recheck that `css/site.css` uses only the Signal-blue accent, with no violet left over from the v1 "nebula violet" plan in `website/PLAN.md`. That's a historical doc; consider adding a note that it's superseded by the matte direction.
11. **Hotjar.** Create a funnel (hero → `#tour` play → `#install` → `install_copy`/`brew_copy`/`download_click`) and a heatmap for `/`. Keep the privacy.html disclosure accurate. Don't add new trackers.
12. **UTM capture.** `js/main.js` sends `download_click`. Consider attaching `document.referrer` and the landing `utm_campaign` as event properties, so installs can be attributed per channel. It's a small JS change, and needs your approval.
13. **Agents section.** The roster's "Builds: Ships small fixes to your side projects" is the only coding card. That's fine as one of four, but make it the last card, and lead with Inbox Ivy and Screen Guide (currently Builds is third).
14. **After #55:** replace the static `faces-row` with a short looping Clip E (muted, `prefers-reduced-motion` respected, with a poster image). Add one line to `#agents`: "Each agent has a face that looks where you're working and reacts when a job lands." Add Clip F under the agents window screenshot.
15. **OG image.** `og-teaching-v2.png` says "Learn your software. One step at a time." Make a new OG card (1200×630, Still S1 composition, headline "Ask about anything on your screen.") with a new filename.
