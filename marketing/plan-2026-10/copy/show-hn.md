# Show HN (week 4 target, gated)

Account: `umarsiddiqui303`. Submit only once HN accepts it from this account and the readiness gate in PLAN.md §4 is met.

- Always keep the "Show HN:" prefix.
- Never ask anyone to upvote or comment.
- Never repost from another account.

**URL to submit:** `https://github.com/UmarSiddiqui/heymate`. Use the repo with no UTM. HN prefers something people can run and inspect, and the README carries the real clip.

**Best time:** Tue 10 or Wed 11 Nov, 8–9 am US Pacific. Stay in the thread for 4–6 hours.

## Title (80-character limit)

Primary, **79 characters**:

```
Show HN: HeyMate – ask about anything on your Mac screen, it answers and points
```

Alternates (78 and 80 characters):

```
Show HN: HeyMate – push-to-talk Mac companion that sees your screen and points
Show HN: HeyMate – open-source notch app that answers out loud about your screen
```

HN strips some punctuation and may lowercase things. Avoid "AI-powered", "revolutionary" and exclamation marks.

## First comment (post right after submitting)

```
Hi HN, I built HeyMate, a macOS app that lives in the notch. You hold Control+Option, ask a question out loud about whatever is on your screen, and let go. It captures the screen for that question, answers by voice, and moves a pointer to the thing it is talking about. The README has an unedited recording.

A few design choices that might be interesting here:

- No metered API keys. It drives the official Claude Code or Codex CLI, so it runs on the Claude or ChatGPT subscription you already have. When it spawns those CLIs it strips ANTHROPIC_API_KEY / OPENAI_API_KEY and base-URL variables from the child environment, so a stray key can't silently switch you to pay-per-token. OpenCode, any OpenAI- or Anthropic-compatible endpoint (including local ones), and Apple Intelligence (text only) also work.
- Screen capture happens when you ask, not continuously. Chat history stores text, not screenshots or audio. Password managers and System Settings are excluded, and one switch hides the notch and pointer from screen shares.
- Voice can run fully on-device (Parakeet for speech-to-text and Kokoro for TTS, via FluidAudio on the Neural Engine), with the regular Mac voices as a fallback, or ElevenLabs with your own key.
- Longer jobs go to "agents": named helpers with their own folder, notes and schedule. They plan read-only first and wait for approval. Anything that sends, deletes or pays asks first.

Native SwiftUI, MIT licensed, macOS 14.2+. Works on Macs without a notch (it becomes a small pill at the top).

Rough edges, honestly: builds are self-signed, not notarized (I don't have a Developer ID), so first launch needs "Open Anyway" or the brew/curl installer. It asks for several permissions (mic, screen recording, accessibility, input monitoring), and each is explained at getheymate.vercel.app/permissions. Pointing is only as good as the vision model, and it does sometimes point at the wrong thing.

I'd love to hear where it breaks for you, and what you'd ask it first.
```

Before posting, check these claims against the shipped build:

- The env-var stripping (it's in the README, so it should hold).
- Input Monitoring listed as a permission (yes, per the site).
- "The README has an unedited recording". Only true once Clip A is in the README.

## Likely questions, with prepared answers

Keep these short when you reply, and edit them in your own voice.

- **"Why not just use the ChatGPT or Claude desktop app?"** "You can. HeyMate is for when you don't want to switch windows or paste a screenshot. It's one key-hold from any app, it answers out loud, and it points at the spot. It uses those same subscriptions underneath."
- **"Is the screen sent to the cloud?"** "Yes, to whichever model provider you picked, only when you ask (and between steps of a walkthrough). Nothing goes to me; HeyMate has no server for your chats. If you want it to stay on the machine, point it at a local vision model through the OpenAI-compatible option."
- **"Not notarized? No thanks."** "Fair. A Developer ID costs money I've chosen not to spend on a free project yet. The source and the release workflow are public, each release ships a SHA-256, and you can build it yourself in Xcode."
- **"How is this different from ReferenceRenderer / Mate?"** **Don't post this until you've decided the ReferenceRenderer question in PLAN.md §7.** Neutral draft: "Similar idea: push-to-talk, it looks at the screen, a pointer. HeyMate is MIT-licensed, runs on your existing subscription rather than its own plans, and has agents and routines. I'd rather people try both than take my word on a comparison." Don't add a feature checklist, and make no claims about their privacy or pricing beyond what their own site states.
