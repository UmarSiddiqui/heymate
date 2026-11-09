# How to ask AI about your Mac screen by voice

Try a spoken walkthrough in TextEdit. Ask HeyMate to point out the next step, then check the PDF yourself in Preview.

By the HeyMate project. Published 2026-11-09. Category: Workflows.

> Open the Mac app you want help with, hold Control + Option, and ask one question about what you see. In HeyMate, ask for one step at a time so you can check the highlighted control and try it yourself.

## Start with something you can check

Use a sample TextEdit document for your first walkthrough. Type a few lines and leave the window in front. The task is to create a PDF copy in a folder you can find again. You can verify both the suggested menu path and the finished file. [Apple’s TextEdit guide](https://support.apple.com/guide/textedit/txtee6663a0e/mac)

In HeyMate, connect a vision-capable AI provider. Microphone access lets you ask aloud, Screen Recording provides screen context, and Accessibility supports the hotkey and pointing. [Connect your AI](https://sayheymate.com/connect-claude-codex) · [Review Mac permissions](https://sayheymate.com/permissions)

## Ask for the next click

1. Hold Control + Option while you ask the question below, then release the keys when you finish speaking.
2. Check the label and position of the suggested control. Open the File menu yourself and look for Export as PDF.
3. If the walkthrough is waiting, say “next” or click the indicated target when you are ready. Ask about the save dialog if you need help choosing a location.
4. Open the PDF in Preview. Check that the text matches your sample and that the original document is still open in TextEdit.

Try this prompt:

> I want a PDF copy of this TextEdit document. Show me the first control to use. Wait while I click it, then help me check where the PDF will go.

If the assistant describes a control you cannot see, report what is visible. For example, “The File menu is open and I see Print. Where should I look for Export as PDF?” A guided turn can capture the updated screen.

## Choose between talking and typing

Speaking is convenient when your hands are on the mouse. Typing can be easier in a shared office or when the question includes a precise error string. The HeyMate 1.0.90 update also supports typed screen explanations. For questions that are answerable from text alone, use text-only chat and paste the relevant part of the message. [HeyMate 1.0.90 release notes](https://github.com/UmarSiddiqui/heymate/releases/tag/v1.0.90)

If a task needs a visible cue, say so. “Explain this setting” asks for an answer. “Point to the setting and wait” tells the assistant how to help you use the interface. That distinction matters when the same label appears in two places.

## If the screen or microphone seems unavailable

If typed questions work but spoken ones fail, start by checking microphone permission and the app’s voice settings. If the assistant answers but cannot describe the visible app, bring the intended window forward, check Screen Recording permission, and confirm your model supports images. [Screen guidance troubleshooting](https://sayheymate.com/screen-guidance#troubleshooting)

Use the same method with a small app task you actually care about, such as finding an export option or making sense of a warning. If the screen contains someone else’s work or personal information, [choose what to share first](https://sayheymate.com/blog/mac-ai-screen-sharing-privacy).

## Related reading

- [AI assistants that can see your Mac screen](https://sayheymate.com/blog/ai-assistants-that-see-your-screen-mac)
- [What can AI see when you share your Mac screen?](https://sayheymate.com/blog/mac-ai-screen-sharing-privacy)
- [Learn a Mac app with AI guidance, one step at a time](https://sayheymate.com/blog/learn-mac-apps-with-ai)

[Set up HeyMate](https://sayheymate.com/connect-claude-codex) · [Privacy](https://sayheymate.com/privacy) · [Permissions](https://sayheymate.com/permissions)
