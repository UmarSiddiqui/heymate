# Understand terminal errors with HeyMate before changing code

Use screen-aware AI to read an error, form a testable hypothesis, and plan a small fix. Includes prompts, secret handling, and verification steps.

By the HeyMate project. Published 2026-11-01. Category: Workflows.

> HeyMate can explain a visible terminal error and help you decide what evidence to collect next. When you want code changed, use a scoped agent task, review its plan, and verify the result with a relevant test.

## Ask for an explanation before a command

A terminal failure often contains several messages, and the last line may be a consequence rather than the cause. Begin by asking which line matters and what it actually establishes. Keep the failing command, the working directory, and the first relevant error visible. Remove tokens, private URLs, and customer data from anything you share.

Try this prompt:

> Explain this error using only the visible output. Separate facts from guesses. What is the smallest read-only check that would distinguish the two most likely causes? Do not run or suggest a destructive command.

## Build a short debugging loop

1. Reproduce the error with the smallest command or input you can.
2. Ask what the output proves and what information is missing.
3. Run a relevant diagnostic that you understand.
4. Update the hypothesis using the new output.
5. Change one thing, then rerun the command or focused test.

This approach works whether the failure is a missing tool, a dependency mismatch, or a test assertion. The point is not to guess the right fix immediately. It is to make each next action produce evidence that narrows the problem. A plausible explanation without a reproduction remains a guess.

## Turn the investigation into an approved coding task

Try this prompt:

> In this project, fix the failing test we just discussed. First show a read-only plan naming the files you expect to change, the reason for the change, and the test you will run. Do not change dependencies or unrelated formatting.

HeyMate can hand work to configured coding providers. Use Claude Code or Codex when the task needs shell commands to build or test itself; HeyMate’s OpenCode jobs can edit files but cannot run shell commands. Provider capabilities and access rules differ. Review the proposed scope before approving execution.

## Verify behavior, not just a clean log

A passing command is useful only if it checks the behavior that failed. Confirm the original trigger, a normal case, and any boundary exposed by the bug. Inspect the diff for unrelated changes. If the result depends on a remote service, distinguish a successful local test from a verified production fix.

Workspace snapshots can support local undo, but they cannot unsend a message or reverse a remote service change. Approved work may continue in a background helper after the app quits. Choose the project folder carefully and check job status before starting a second attempt.

## Use the right source for the exact error

Check the tool’s official documentation when an error concerns a command flag, supported runtime, or provider limit. HeyMate can help interpret that documentation in context. It does not turn model memory into an authoritative version-specific reference.

Start with [provider setup](https://sayheymate.vercel.app/connect-claude-codex) and [screen guidance](https://sayheymate.vercel.app/screen-guidance). Review [privacy](https://sayheymate.vercel.app/privacy) before showing logs: screen context can leave your Mac through the provider connection you select.

## Related reading

- [HeyMate vs Claude Cowork: choose your desktop AI workflow](https://sayheymate.vercel.app/blog/heymate-vs-claude-cowork)
- [How to choose an open-source AI assistant for Mac](https://sayheymate.vercel.app/blog/choose-open-source-ai-assistant-mac)
- [Build a weekly research brief with a specialist HeyMate](https://sayheymate.vercel.app/blog/ai-weekly-research-brief)

[Set up HeyMate](https://sayheymate.vercel.app/connect-claude-codex) · [Privacy](https://sayheymate.vercel.app/privacy) · [Permissions](https://sayheymate.vercel.app/permissions)
