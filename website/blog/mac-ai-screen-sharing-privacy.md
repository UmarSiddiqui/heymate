# What can AI see when you share your Mac screen?

Understand what Mac screen permissions allow, what an AI request can send, and when a cropped screenshot or text is enough.

By the HeyMate project. Published 2026-11-09. Category: Choosing tools.

> macOS Screen Recording permission allows an app to capture screen content. What the AI receives depends on the app, the mode you choose, and the provider handling the request. A cropped attachment, a window capture, and a walkthrough that captures again each have a different scope.

## Separate permission, capture, and sending

Permission is the macOS setting that lets an app capture screen content. Capture is the material the app actually collects. Sending is what the app includes when it asks a model for a response. Check the app’s settings and privacy documentation for the last two. [Apple’s screen access controls](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac)

A screenshot can contain more than the button you meant to ask about. A window may show customer names in its title, open document tabs, or sidebar previews. A capture refreshed later can show a different dialog. Review the full area that could be shared and use sample content if the task allows it.

## Pick the smallest useful input

| Your question | Input to try | What to check |
| --- | --- | --- |
| What does this error code mean? | Paste the error code and app name in a text-only question. | Remove account IDs, credentials, and private paths. |
| Which toolbar icon opens export settings? | Attach a cropped image of the toolbar or a clean sample window. | Include enough surrounding controls to identify the app and the button. |
| How do I get through this dialog one step at a time? | Use a walkthrough with a sample file and share the relevant window. | Look at the new window or dialog before asking for the next step. |

For example, if a client invoice fails to export, reproduce the problem with a blank invoice template and one made-up line item. If the export error appears again, you have the same clue without sharing the customer details.

## What HeyMate captures and sends

HeyMate uses screen context for interactions that need it, including guided walkthroughs. It can capture again between steps. Talk can capture every display by default. In Settings under Talk & Voice, turn on “Look at the front window only” to prefer the frontmost window. If no window qualifies, Talk can fall back to all displays. For strict control over what you share, use a manually cropped attachment in an app that accepts it, or ask a text-only question. Relevant screen images can go to the vision-capable provider you selected. [HeyMate privacy details](https://sayheymate.com/privacy)

HeyMate’s local chat history stores text. Some CLI integrations create temporary image files, and interrupted cleanup can leave them behind. A provider’s retention policy and CLI history apply separately. If your question is about data handling, check both the app and provider policies. [What leaves your Mac](https://sayheymate.com/privacy#what-leaves-your-mac)

## Review or revoke Mac screen access

Open System Settings, choose Privacy & Security, and find Screen & System Audio Recording or Screen Recording, depending on your macOS version. Turn access off for the app when you no longer want it to capture. Follow any relaunch prompt from macOS. For existing messages or provider copies, use the corresponding history and data controls. [Apple’s permission steps](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac) · [HeyMate’s permission guide](https://sayheymate.com/permissions)

## Related reading

- [AI assistants that can see your Mac screen](https://sayheymate.com/blog/ai-assistants-that-see-your-screen-mac)
- [How to ask AI about your Mac screen by voice](https://sayheymate.com/blog/ask-ai-about-your-screen-by-voice-mac)
- [How to choose an open-source AI assistant for Mac](https://sayheymate.com/blog/choose-open-source-ai-assistant-mac)

[Set up HeyMate](https://sayheymate.com/connect-claude-codex) · [Privacy](https://sayheymate.com/privacy) · [Permissions](https://sayheymate.com/permissions)
