# HeyClicky video review: positioning and feature notes

Written 2026-11-01 after watching all 28 public HeyClicky videos: 13 YouTube uploads, 9 Shorts and 6 demo clips on heyclicky.com. 18 of them had captions. The other 10 were reviewed from frames only, because they have no captions and no Whisper key is set up: the "Saathi" music video, "I went viral for this feature", "trying again 10 years later", "something is happening to me" and the 6 site demos.

The rule still stands: never copy HeyClicky's code, art, audio or footage (see the sound-profile memory). These notes cover what they say and show, not their assets.

Sources: https://heyclicky.com and https://www.youtube.com/@HeyClicky

---

## 1. Where HeyClicky stands now

| Item | What they've said publicly | Video |
|---|---|---|
| Platforms | Mac, plus Windows (launched in about month 6 after a waitlist of about 42K–43K signups) | "heyclicky is now on windows" |
| Downloads | About 25,000 | "our new logo is a keyboard shortcut." |
| Customers / MRR | 400 customers, about $9K MRR | "we are a real company now" |
| Payment conversion | About 9.5% | "shipping a ton and fixing 200+ bugs" |
| Pricing | Free / $20 / $100 tiers | Pricing section shown on the landing page |
| Referral | Your friend gets 25% off, and you earn 25% each month | "shipping a ton…" |
| Hotkeys | Hold Ctrl+Option to talk, double-press for hands-free mode, hold Fn+Ctrl to dictate | Several videos |
| Brand | Their logo is the ⌃⌥ keys merged into a smiley face. Blob/character mascot. Warm retro look (Aqua, XP, Clippy jokes), a theme song called "iPod Touch", Easter eggs on the landing page | Logo and Windows videos |

## 2. Features in the order they shipped them

1. **Pointing and drawing on screen.** Arrows, circles and step-by-step guidance ("On the kick row, click this first square") in FL Studio, DaVinci Resolve, Premiere, Blender, Maps routes and sheet music. They also draw explanations over web pages, for example a Pythagoras proof.
2. **Screen-aware dictation.** You speak an instruction and it writes into the focused text box using what's on screen. Examples: a Gmail reply "in my voice" based on its memories of you, a follow-up prompt in a Claude Code terminal, a pitch-deck one-liner in Google Slides. They say it's buggy.
3. **Skills.** A library you turn on with an "Add skill / activate" step. They lead with a Y Combinator skill "written by a YC partner", plus skills for Claude, Blender and After Effects.
4. **Memory.** It remembers facts about you and uses them in dictation and suggestions.
5. **Agent buddies.** Onboarding is a short spoken interview ("What's your story? What would count as a win?"). From that it creates three named background agents. A "Suggested for you" card arrives each morning with No / Adjust / Yes, do it buttons. The agents write Gmail drafts, research Shopify stores and Discord communities, and merge or shrink PDFs ("PDF Buddy"). Each agent gets its own chat thread with progress messages and file cards.
6. **Real-time graphics (their newest launch).** It generates diagrams and 3D-style illustrations over whatever you're looking at, with labels, within a few seconds. Examples: an F-35B hover cutaway, the Raspberry Pi camera-latch steps, a sodium-potassium pump, a MiniDV camcorder, Karpathy tensors. They say it uses a rendering engine they built in-house and that it isn't pre-rendered. Their pitch line is "a new visual interface for AI, no chat or terminal."

## 3. How they market it

- **Weekly "everything we shipped" vlogs.** The whole team speaks on camera, filmed in SF and Bangalore, and they share real numbers (customers, MRR, conversion). It's cheap to make and builds trust.
- **UGC Shorts with a "comment X for the link" call to action.** Each one follows the same arc: a non-technical person is stuck, HeyClicky gets them unstuck in one ask, then the CTA. Topics so far: chess, biology lecture slides, a Premiere mask tool, an IMAX seat-tracker agent built in Claude Code, a YC pitch deck, a visa PDF portal.
- **Polished launch films.** Each feature gets a 2-minute demo with real use cases and closes on "it's in production now."
- **Brand and story pieces.** A music video ("Saathi"), a founder comeback story ("trying again 10 years later") and a landing-page tour.
- **Their demos aren't about coding.** Learning, creative software, admin chores and small business dominate. Coding only shows up as "I'm non-technical, help me use Claude Code".

## 4. Where HeyMate stands against this

How much of each feature HeyMate already has is a quick read of the source tree on 2026-11-01. Nothing below has been tested against a running build.

| HeyClicky feature | In HeyMate source? | Note |
|---|---|---|
| Pointing / drawing | Yes: `CursorPointingMotion`, `Drawing*`, `DrawCardWindowController` | Equal footing. Show it in non-coding apps. |
| Dictation into focused field | Yes: `DictationInserter`, `DictationVocabulary` | Check that it uses screen context ("reply to this email") and isn't plain speech-to-text. That's the part they call new. |
| Skills | Yes: `DefaultSkillCatalog`, `DesktopSkillsView`, `MateSkillInstaller` | They make skills a clear one-tap thing with a credible author. |
| Memory | Yes: `CompanionManager+MemoryEdit` | |
| Morning suggestions with Yes / Adjust / No | Yes: `DailySuggestions`, Standing Orders | This is their agent-buddy hook. Standing Orders is our version. Make sure the morning card and one-tap approval show up in demos. |
| Interview-style onboarding that creates agents | Partial: `CompanionManager+Onboarding`, `OnboardingFirstTaskStep` | Theirs ends with 3 named agents already working. That ending is the hook. |
| Real-time generated diagrams | Yes: real Oct 31 captures show HeyMate drawing a biryani plan, a 2D Raspberry Pi diagram and a rotating 3D Pi | Equal footing. Lead with it: see `marketing/demo-video/src/askdraws/` ("Ask. It draws."). |
| Windows | No | Mac-only stays fine. Their 42K waitlist shows the demand exists. |

## 5. Positioning takeaways for HeyMate

1. **Keep the lead: "ask about anything on screen".** HeyClicky has moved toward "the world's cutest AI interface" and background agents. Our general, voice-first, on-screen promise is still distinct. Keep it as the headline (see the positioning memory).
2. **Lean into what they can't claim.** HeyMate is open source, has a local and on-device voice option (Parakeet/Kokoro), uses bring-your-own-key, and needs no account to try. HeyClicky is closed and paid above the free tier. "Open-source alternative to HeyClicky" already stays in the README and on the site. Back it with a short comparison line: open source, BYOK, no subscription needed.
3. **Show the moments of getting unstuck, not feature lists.** Their best-performing format is: non-technical person, real app, one question, visible result. Our demos should use the same structure with HeyMate's own scenarios. Use fresh captures only, as the AGENTS.md note from 2026-11-01 requires.
4. **Keep demos away from coding.** This matches the existing positioning memory. Learning, creative tools and admin chores carry their channel.
5. **Make trust visible.** Their weekly vlogs share real numbers. Our version could be a short weekly "what shipped" post linking the changelog (see the changelog memory). It costs little.

## 6. Feature ideas worth evaluating (not committed)

- **Generated explainer diagrams on screen.** A first version could draw a labelled diagram card using the existing drawing stack (`DrawCardWindowController`). It doesn't need their 3D engine. Scope it before promising anything.
- **Onboarding that ends with agents already running.** After the first-task step, offer 2–3 Standing Orders built from the user's answers, and start one right away.
- **A credible flagship skill.** Pick one well-known, clearly attributed skill to feature in the skill library. Only use attribution we're actually allowed to use.
- **Screen-aware dictation demo.** If `DictationInserter` already uses screen context, film "reply to this email in my voice". If it doesn't, that's the feature to build.
- **Pending from AGENTS.md:** the notch-shelf blob that eats dropped files. A mascot moment like that matches the "cute interface" area they're claiming, so it's worth shipping in our own style.

## 7. Video list (for reference)

YouTube: introducing real-time graphics. · heyclicky is now on windows · something is happening to me · shipping a ton and fixing 200+ bugs · introducing agent buddies · this song is not AI-generated · the world's cutest ai interface · trying again 10 years later · our new logo is a keyboard shortcut. · this is everything we shipped. · introducing screen-aware dictation. · we are a real company now · hi i'm heyclicky

Shorts: i can help you learn biology · i wanna be a good agent · the worst part of visa applications fixed · 100 robot companies vs 1 guy · i can teach you how to play chess · crashing out? link in bio · yc rejected this pitch deck… · film bro builds an IMAX seat tracker with AI · I went viral for this feature

Site demos: heyclicky-draw · usecase · it-draws-too-omg · daddyshome · nohandstricklol · hello (the same footage as "we are a real company now")
