# Get Step-by-Step AI Screen Guidance on Mac with HeyMate

> HeyMate can explain what is on your Mac screen, point out the next step, and wait while you try it. Use screen guidance when a button is unfamiliar, an error needs context, or a tutorial does not match the app in front of you.

By Umar Siddiqui. Updated November 1, 2026.

## What you need for screen guidance

HeyMate supports macOS 14.2 or later on Apple silicon and Intel. A MacBook notch is optional: Macs without one use a top-center pill. Install the app and [connect a vision-capable AI provider](https://getheymate.vercel.app/connect-claude-codex).

Enable the permissions needed for your chosen features. Microphone supports spoken questions, Screen Recording supplies screen context, and Accessibility supports the hotkey and pointing. The [permissions guide](https://getheymate.vercel.app/permissions) explains each permission and how to revoke it.

Apple Intelligence is an optional text-only provider on eligible Macs running macOS 26 or later. It cannot provide screen guidance because it cannot see screen images.

## Start a walkthrough in a Mac app or website

- Open the app or website you want help with. Use sample content for your first attempt.

- Hold Control + Option and describe one outcome: “Show me how to export this document as a PDF.”

- Listen to the explanation and check where the pointer is pointing.

- Try the current step yourself. In multi-step guidance, HeyMate can wait for a target click or for you to say “next”.

- If the screen changes unexpectedly, explain what changed before continuing.
A walkthrough can show a plan and capture fresh screen context between steps. Model mistakes remain possible: read important controls before acting and check the result afterward.

## Example prompts for real tasks

- Learn an unfamiliar app: “Explain the panels on this screen, then show me where to start.”

- Understand an error: “Explain this error message. What should I check first?”

- Find a control: “Point to where I can change the export format. Wait while I try it.”

- Learn a tool: “Walk me through this one step at a time. Ask what I already know first.”
These are example questions, not guaranteed outcomes. Specific tasks depend on your app, current screen, permissions, and selected provider. For recorded examples of drawn explanations, see [HeyMate’s actual visual answer recordings](https://getheymate.vercel.app/index#visual-answers).

## Screen guidance and computer control are different choices

With guidance, HeyMate explains and points while you perform the steps. If you want HeyMate to click or type, enable computer control and approve the work. Click, type, or press Escape to take back control.

Use small, reviewable tasks first. Before approving a message, file change, purchase, or remote action, check the destination and effect. Local workspace undo cannot reverse sent messages or changes in a remote service.

## When the pointer or answer is wrong

- Wrong window: bring the intended app to the front and describe the goal again.

- Missing screen context: check macOS Screen Recording permission and your provider’s vision support.

- Hotkey or pointing unavailable: review Accessibility permission in System Settings > Privacy & Security.

- Answer does not match the interface: say what is different and ask for one corrected step. Do not keep following instructions that no longer match the screen.
If connection problems persist, use the [Claude and Codex connection checks](https://getheymate.vercel.app/connect-claude-codex#connection-troubleshooting). Include the app version and a non-sensitive description when reporting a bug.

## What happens to screen context?

Relevant questions and screen images go to the provider you select. HeyMate’s local chat history contains text, not screenshot or audio bytes. Some integrations write temporary screenshots; interrupted cleanup can leave files behind. Provider retention and CLI histories follow separate rules.

Enabled routines, standing orders, and approved jobs can run in the background. Review [privacy and storage details](https://getheymate.vercel.app/privacy) and [macOS access settings](https://getheymate.vercel.app/permissions) before using HeyMate with private work. Continue with the [everyday workflow guide](https://getheymate.vercel.app/how-to-use-heymate) when you are ready to create a specialist mate.

