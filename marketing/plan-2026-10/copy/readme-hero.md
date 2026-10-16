# README hero rewrite (suggestion only, not applied)

This replaces everything from the top of `README.md` down to and including the first GIF block. It keeps the badges, links and Boring Notch credit, and removes the HeyClicky line until you decide on it (PLAN.md §7).

**Why change it:**

- The current hero leads with "Learn your software. One step at a time." That's one use, not the capability.
- The GIF example, "why is my Mac so slow?", makes HeyMate read as a Mac-optimisation tool.

```markdown
<div align="center">

<img src="docs/media/heymate-icon.png" width="112" alt="HeyMate app icon">

# HeyMate

**Ask about anything on your screen. It answers out loud and points.**<br>
Hold <kbd>⌃</kbd> <kbd>⌥</kbd>, ask, let go. HeyMate lives in your Mac's notch and runs on the Claude or ChatGPT plan you already have. No metered keys, no HeyMate subscription.

Free and open source (MIT) · native SwiftUI · macOS 14.2+

[badges unchanged]

[**Download for Mac**](https://github.com/UmarSiddiqui/heymate/releases/latest/download/HeyMate.dmg) · `brew install umarsiddiqui/tap/heymate` · [Website](https://getheymate.vercel.app) · [Changelog](https://getheymate.vercel.app/changelog)

<br>

<a href="docs/media/heymate-ask-real.mp4">
  <img src="docs/media/heymate-ask-real.gif" width="720" alt="A real recording: holding Control and Option, asking a question about a settings page, and HeyMate answering out loud while its pointer moves to the right control">
</a>

<sub>Real recording, not sped up. Here I asked "[exact Clip A question]".</sub>

<sub>Inspired by <a href="https://github.com/TheBoredTeam/boring.notch">Boring Notch</a>.</sub>

</div>

## What you can ask

- "What does this setting actually do?" on a web dashboard
- "Which of these columns is the total?" in a spreadsheet
- "Where's the export option?" in an app you rarely open
- "Summarise this paragraph" in a PDF
- "Walk me through this, one step at a time." HeyMate points at each step and waits while you do it.

Longer jobs go to **agents**: helpers you describe in one sentence, with their own notes and schedule. They plan first and ask before anything that sends, deletes or pays.
```

**Notes:**

- `docs/media/heymate-ask-real.gif` and `.mp4` don't exist yet. They come from Clip A (`assets-brief.md`): 720 px wide, 15 fps, under 8 MB for GitHub.
- Leave the existing "Try a task you want to learn" section in place. Rename it "Walkthroughs" and move it below "What you can ask".
- Rename the "Coding agents, on a leash" heading in the feature table to "Agents that ask first". Make its example a non-coding task, such as "draft replies to this morning's customer email", and mention the coding example second.
- Keep the README's "Changelog" link pointing at the site changelog rather than GitHub Releases. The release notes are raw commit subjects.
