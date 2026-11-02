# Draft better email on Mac with HeyMate and a review step

Turn rough notes into a focused email draft, check its claims, and keep sending separate from drafting. Includes reusable prompts for tone and edits.

By the HeyMate project. Published 2026-11-01. Category: Workflows.

> Use HeyMate to understand the visible context, discuss a response, or work with an email integration you configure. Drafting and sending should remain separate decisions, especially when the message makes a commitment.

## Give the draft a purpose and boundaries

Start with what the recipient needs to know or do. State the relationship, the desired tone, and the facts that must remain exact. If you are replying to a thread, check which messages and attachments the model can actually access. A visible screen is only part of a conversation, and an integration has only the permissions you grant it.

Try this prompt:

> Draft a reply to the context I provide. Goal: agree on a meeting time without promising a delivery date. Use a warm, direct tone and fewer than 120 words. Preserve names and dates exactly. If a necessary fact is missing, ask instead of inventing it. Do not send.

## Use voice for rough thoughts, then edit for the reader

Hold Control + Option to explain what you want to say in your own words. An unstructured spoken note can be a useful first input because it preserves your priorities. Then ask for a concise version with the request near the beginning. Read the result aloud; remove phrases that do not sound like something you would write.

Try this prompt:

> Keep my meaning but remove repetition. Put the requested action first. List any factual claims or commitments you added that were not present in my notes.

For repeated replies, save a clear template or use a dedicated text-expansion tool. Asking a model to regenerate an unchanged address or standard paragraph adds uncertainty without adding much value. [The Alfred comparison](https://getheymate.vercel.app/blog/heymate-vs-alfred) explains when snippets are a better fit.

## Check the risky details yourself

- Recipient and reply-all list: confirm the actual destination.
- Names, dates, amounts, links, and attachments: compare with the source.
- Commitments: identify promises, approvals, deadlines, or concessions.
- Tone: remove implied blame or urgency you did not intend.
- Context: confirm that the draft does not reveal private details from another thread.

A polished draft can still contain an unsupported statement. Asking for a separate fact check is useful, but it is not independent evidence if the model is checking its own invented detail. Compare the draft against the original notes and correspondence.

## Sending needs its own decision

If you connect an email service, its capabilities depend on the configured tools and account access. Do not assume a draft has been saved or sent because the assistant described it. Check the service’s draft or sent view, and approve the actual destination and content before an external send.

HeyMate’s local undo cannot unsend an email or reverse another remote service change. Keep your first experiment to sample content. Read [privacy details](https://getheymate.vercel.app/privacy) before sharing a real thread; the selected provider receives the context it processes.

## Build a reusable editing habit

A writing mate can hold preferences such as “short paragraphs,” “ask before making promises,” and “always list unknown facts.” Those instructions are useful across tasks, but they do not replace a final read. If your need is a one-press rewrite in a launcher, [Raycast may also fit](https://getheymate.vercel.app/blog/heymate-vs-raycast). Choose the interaction that makes review easiest for you.

## Related reading

- [Prepare for meetings on Mac with a source-backed AI brief](https://getheymate.vercel.app/blog/ai-meeting-prep-mac)
- [HeyMate vs Raycast: which Mac AI workflow fits you?](https://getheymate.vercel.app/blog/heymate-vs-raycast)
- [HeyMate vs Alfred: AI guidance or repeatable Mac workflows?](https://getheymate.vercel.app/blog/heymate-vs-alfred)

[Set up HeyMate](https://getheymate.vercel.app/connect-claude-codex) · [Privacy](https://getheymate.vercel.app/privacy) · [Permissions](https://getheymate.vercel.app/permissions)
