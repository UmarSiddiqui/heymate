# How to choose an open-source AI assistant for Mac

Evaluate Mac AI assistants by workflow, provider access, privacy, permissions, installation, and total cost. Includes a practical HeyMate evaluation checklist.

By the HeyMate project. Published 2026-11-01. Category: Choosing tools.

> Choose by the task you want to complete and the access you are comfortable granting. Open-source app code helps inspection, but it does not guarantee local processing, correct answers, private providers, or a notarized installer.

## Start with the interaction you need

A Mac AI assistant can mean a chat window, a command launcher, a screen tutor, or an agent that changes files. Write down one task you actually repeat and the result you want. If you mainly need the same fixed text inserted, a snippet may be enough. If you want to understand unfamiliar software, prioritize the explanation and review loop.

- Guidance: you do the task while the assistant explains and points.
- Delegation: the agent plans and performs scoped work for review.
- Repetition: a defined workflow applies known steps to a new input.
- Research: tools gather current sources and separate evidence from interpretation.

These categories overlap. The important question is how much interpretation the task needs and how easily you can inspect the result. A longer feature list does not establish a better fit for your routine.

## Separate app licensing from provider cost

HeyMate is MIT licensed and adds no subscription fee. It can use configured Claude Code, Codex, OpenCode, and custom Anthropic-compatible API routes. Those providers have their own limits, account requirements, and charges; optional voice and connector services can also cost money.

When comparing products, ask what you pay for the app, what you pay for inference, and what connected services charge. Reusing an existing subscription can be useful, but it is not unique to HeyMate: [Raycast also documents that route](https://sayheymate.vercel.app/blog/heymate-vs-raycast). Look at current terms rather than a comparison’s old price screenshot.

## Check what “local” actually covers

Ask separately about chat storage, model inference, speech processing, credentials, temporary files, and connected services. Local chat history does not mean the model ran locally. Open-source app code does not determine a cloud provider’s retention policy.

In HeyMate, local history stores text, while relevant questions and screen images can go to the selected provider. Some integrations write temporary screenshots; interrupted cleanup can leave files behind. Optional Apple Intelligence is text-only on eligible Macs running macOS 26 or later and cannot see the screen. Review the detailed [privacy explanation](https://sayheymate.vercel.app/privacy).

## Review installation and access

HeyMate supports macOS 14.2 or later on Apple silicon and Intel. Current builds use a stable self-signed certificate and are not Apple Developer ID signed or notarized. That differs from a polished installation experience you may expect from another vendor. Read the [setup guide](https://sayheymate.vercel.app/connect-claude-codex) and decide whether the tradeoff is acceptable.

For any assistant, review the permissions the chosen task needs. A question about text need not become broad access to your entire desktop. Screen guidance needs a vision-capable provider and appropriate permissions. Connected tools have their own account scope, and local undo cannot reverse every external action.

## Run one evaluation with sample content

1. Choose a small task with an answer or outcome you can verify.
2. Use non-sensitive sample content and grant only relevant access.
3. Record setup effort, corrections, and what data leaves the machine.
4. Check the output against the original evidence.
5. Decide whether the result is useful enough to keep using the tool.

HeyMate is worth evaluating if a desktop companion, spoken guidance, and specialist mates match the way you work. Another tool may fit better if its explicit workflows, integrated environment, or installation model matter more. See the comparisons with [Alfred](https://sayheymate.vercel.app/blog/heymate-vs-alfred), [Apple Shortcuts](https://sayheymate.vercel.app/blog/heymate-vs-apple-shortcuts), and [Claude Cowork](https://sayheymate.vercel.app/blog/heymate-vs-claude-cowork). No universal ranking or reliability percentage is established by these guides.

## Related reading

- [HeyMate vs Raycast: which Mac AI workflow fits you?](https://sayheymate.vercel.app/blog/heymate-vs-raycast)
- [HeyMate vs Claude Cowork: choose your desktop AI workflow](https://sayheymate.vercel.app/blog/heymate-vs-claude-cowork)
- [Learn a Mac app with AI guidance, one step at a time](https://sayheymate.vercel.app/blog/learn-mac-apps-with-ai)

[Set up HeyMate](https://sayheymate.vercel.app/connect-claude-codex) · [Privacy](https://sayheymate.vercel.app/privacy) · [Permissions](https://sayheymate.vercel.app/permissions)
