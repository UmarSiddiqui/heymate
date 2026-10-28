# Reddit drafts (you post these by hand)

Claude can't post to Reddit. Before posting either draft:

- Re-read the subreddit's sidebar rules and pinned posts on the day. The notes below come from Reddit mirrors (Reddit blocks direct fetching), so they may be out of date.
- Build karma with plain helpful comments first. r/macapps mods recommend at least 10 karma, without links, before posting a link from a new account. r/ClaudeAI needs 50 total karma for a feed showcase.
- Rewrite the drafts in your own voice. r/macapps mods say AI-style formatting, especially em dashes, raises auto-removal odds. These drafts avoid em dashes and fancy bullets on purpose.
- Use one post per subreddit. Answer every comment for the first few hours.

## Why these two subreddits

| Subreddit | Why | Rule constraint |
|---|---|---|
| **r/macapps** | The core audience of Mac users who install utilities. awesome-mac traffic already shows interest. | Apps that aren't on the Mac App Store and come from a young repo must go in the **monthly "App Pile" megathread**, in **Problem / Comparison / Pricing (PCP)** format. This counts toward the 30-day promotion limit (Rule 3). |
| **r/ClaudeAI** | People who already pay for Claude, which is the bring-your-own-plan hook. HeyMate runs on Claude Code sign-in. | Project showcases follow Rule 7. Under 50 karma, you're directed to the "Built with Claude" showcase megathread. Frame it as a way to use your Claude plan, not as a coding tool. |

Backups if either is a poor fit: r/opensource (lead with MIT and the architecture) and r/SideProject (very promotion-tolerant, but a low-value audience).

---

## Post 1: r/macapps November App Pile megathread (Sun 1 or Mon 2 Nov)

Post this as a **comment** in the megathread, not as a new post.

```
HeyMate: ask about anything on your screen, it answers out loud and points (free, open source)

Problem
When something on screen confuses me (a setting buried in a web dashboard, a chart, a menu in an app I rarely use), my options were to screenshot it, switch to a chat app, paste, describe what I'm looking at, then switch back. HeyMate cuts that to one gesture: hold Control+Option, ask out loud, let go. It looks at the screen for that question, answers by voice, and moves a pointer to the thing it means. Here I asked "[your Clip B question]" (clip linked below, real recording).

It lives in the notch (or a small pill on Macs without one). Other bits: helpers that run on a schedule and ask before they send or delete anything, on-device voice (Parakeet and Kokoro) or Mac voices, and Calendar, Reminders, Mail and Gmail integrations.

Comparison
vs a chat app window: no screenshots, no window switching, and it can point instead of describing where to click.
vs notch utilities: it has the usual shelf, media and timer bits, but the main thing is the assistant.
It uses your existing Claude or ChatGPT subscription through the official Claude Code or Codex sign-in. It does not use its own model or a metered key.

Pricing
Free, MIT licensed. You need your own Claude or ChatGPT plan (or a local or API model). Provider limits apply.
Honest caveats: builds are self-signed and not notarized, so first launch needs Open Anyway (or use the Homebrew cask). macOS 14.2+.

Links
Site: https://getheymate.vercel.app/?utm_source=reddit&utm_medium=community&utm_campaign=macapps_nov
Source: https://github.com/UmarSiddiqui/heymate
Brew: brew install umarsiddiqui/tap/heymate
```

Notes:

- Upload Clip B somewhere the megathread allows (a Reddit video upload if comments support it, or the GitHub README anchor) and link it.
- If the mods want a named competitor in "Comparison", don't add ReferenceRenderer until you've decided PLAN.md §7. You could name Apple's own tools instead (for example, "vs Siri and Apple Intelligence: …"), but only after you've checked the claims yourself.

---

## Post 2: r/ClaudeAI showcase (week 2, Wed 28 Oct)

Use the "Built with Claude" flair if posting to the feed (50+ karma). Otherwise post the same text in the showcase megathread.

**Title:**

```
I made my Claude plan live in my Mac's notch: hold a key, ask about anything on screen, it answers out loud and points
```

**Body:**

```
I pay for Claude Pro and kept doing the same dance: screenshot, switch to the Claude tab, paste, explain what I'm looking at. So I built HeyMate, a free, open-source macOS app that sits in the notch.

How it works
- Hold Control+Option, ask out loud, let go.
- It grabs the screen for that one question and sends it through the official Claude Code CLI, signed in with your normal Claude subscription. No API key, no per-token billing. It strips ANTHROPIC_API_KEY from the child process so a stray key can't switch you to metered usage.
- Claude answers, HeyMate speaks the reply and moves a pointer to what it's talking about.

Here I asked "[your Clip A question]" (real recording): [link]

Other things it does with the same plan
- Helpers you describe in one sentence. Claude drafts the name, job, habits and what it must ask you first.
- Routines on a schedule ("every morning at 8"), with results landing in that helper's chat.
- Anything that sends, deletes or pays always asks first.

How Claude helped build it
[1 to 3 honest sentences: what you used Claude or Claude Code for while building it, plus one prompt you used. The showcase rules historically asked for this, so check Rule 7.]

Free, MIT, native SwiftUI, macOS 14.2+. ChatGPT through Codex works too. Self-signed (not notarized), so first launch needs Open Anyway or the brew cask.

Source: https://github.com/UmarSiddiqui/heymate
Site: https://getheymate.vercel.app/?utm_source=reddit&utm_medium=community&utm_campaign=claudeai_oct

What would you ask it first?
```

Notes:

- Keep the coding-agent side out of the headline. Anyone who asks will find it in the README.
- Check that the Claude Code CLI sign-in really uses the subscription with no Console billing. The README says so (`claude auth login --claudeai`).
