# HeyMate 30-second cursor demo

## Verdict

For a solo developer, lead with one real screen question and show the cursor landing on its answer. Keep it to 30 seconds, in a landscape screen recording. Put the question in the first five seconds and the cursor payoff on screen by about eight seconds. Skip a logo intro and feature list.

The 15-video sample points to product-specific visuals and a clear spoken hook, but view counts are strongly affected by brand reach and distribution. The closest match, ReferenceRenderer's screen-drawing demo, says what the feature does as the presenter starts showing it. The strongest broad examples use a distinctive opening image or established product recognition. HeyMate's advantage is its real cursor movement, so show that immediately.

## Hook line

> Ask your Mac. Watch the cursor point to the answer.

## Record this take

**Screen to prepare:** In Chrome, open [HeyMate PR #53](https://github.com/UmarSiddiqui/heymate/pull/53/files) and scroll to `CompanionManager+Onboarding.swift`, where this call is visible:

```swift
location: globalPoint(forScreenshotPixel: pixel, in: screen)
```

Keep the HeyMate notch visible. Put the code call in the lower third, and park the pointer in the upper-left corner so the cursor has a long, clear route to the answer. Use a clean browser window with the line readable at a glance.

| Time | What's on screen | Umar says | Caption text |
|---|---|---|---|
| 0:00–0:03 | Full Mac display. The code diff and HeyMate notch are both visible; pointer rests in the upper-left. | "Ask your Mac. Watch the cursor point to the answer." | **Ask your Mac. Watch the cursor point to the answer.** |
| 0:03–0:08 | Press and hold HeyMate's talk control. Keep the diff visible while asking. | "What does `globalPoint(forScreenshotPixel: pixel, in: screen)` do? Answer in one sentence and point to that exact call." | **What does `globalPoint(forScreenshotPixel: pixel, in: screen)` do?** |
| 0:08–0:16 | HeyMate answers aloud. The cursor travels across the screen, lands on the call and circles it. Keep the whole flight in frame. | **HeyMate:** "It maps the screenshot pixel to its position on the Mac's screen." | Caption HeyMate's actual one-sentence answer; keep it clear of the code line. |
| 0:16–0:22 | Hold on the circled line for two seconds; keep the answer bubble and notch visible. | "I can follow the answer straight to its source." | **I can follow the answer straight to its source.** |
| 0:22–0:30 | Pull back to the full screen, then end on a simple HeyMate card with the repo address. | "HeyMate is free and open source for Mac. Try it on GitHub." | **HeyMate · Free and open source for Mac** / **github.com/UmarSiddiqui/heymate** |

**Edit note:** Record the real response. If HeyMate phrases it differently, caption what it actually says. Cut dead air before the cursor moves, but keep the cursor's flight continuous.

## Three precise questions to try

These use real HeyMate source code so the answer has a visible, unique target:

1. **GitHub PR #53 diff:** "What does `globalPoint(forScreenshotPixel: pixel, in: screen)` do? Point to that exact call."
2. **Cursor or Xcode, `CompanionManager+Onboarding.swift`:** "Which call captures the screen before the tour asks the model about it? Point to the call."
3. **Cursor or Xcode, the tour's point prompt:** "What exact marker tells the model where to point on screen? Point to the marker." The visible target is `[POINT:x,y:label]`.

For the longest cursor travel, keep the target in the lower third and start the pointer far from it. Don't ask about a line that isn't visible in the captured screen.

## macOS recording setup

- **Frame and resolution:** Capture the full display at its native resolution. Export landscape at 1920×1080 if a 16:9 crop keeps the notch and cursor path; otherwise retain the MacBook's wider 16:10 frame. Keep the code large enough to read.
- **Cursor:** In System Settings → Accessibility → Display → Pointer, increase pointer size slightly and choose a contrasting outline or fill. Test one short capture to make sure the HeyMate cursor remains easy to see.
- **Notifications:** Turn on Do Not Disturb from Control Center before recording.
- **Screen:** Close unrelated tabs and apps, hide the Dock, and zoom the GitHub diff until the target line is readable. Keep the notch, answer bubble, and destination line inside the frame.
- **Audio:** Use a quiet room and capture both Umar's mic and HeyMate's spoken output. Make a five-second test recording first and listen back for both.
- **Captions:** Burn in short captions for silent autoplay. Keep them in a clear lower band so they don't cover the code or cursor circle.

## X post

Ask your Mac a question about what's on screen. HeyMate answers out loud, then the cursor flies to the exact spot and circles it.

HeyMate is free and open source for Mac. Try it or star the repo: https://github.com/UmarSiddiqui/heymate

## LinkedIn post

I've been building HeyMate, a free and open-source Mac companion. Ask it about what's on your screen and it answers out loud, then flies the cursor to the relevant spot and circles it.

Here's a 30-second demo. If you try HeyMate, I'd love your feedback and a star on GitHub:
https://github.com/UmarSiddiqui/heymate
