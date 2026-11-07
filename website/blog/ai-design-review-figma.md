# Use HeyMate for a focused Figma or website design review

Ask for actionable design feedback on hierarchy, copy, spacing, and contrast. Turn a screen-aware AI critique into a small revision you can compare.

By the HeyMate project. Published 2026-11-01. Category: Workflows.

> HeyMate can discuss a visible design and point out what it means. Use it for a focused critique, then verify measurements and accessibility with design and browser tools.

## Give the critique a real brief

“Make this look better” leaves too much to guess. State who the page serves, what the user should do next, and what you are allowed to change. A checkout, documentation page, and portfolio need different kinds of feedback. Bring the frame or live page into view and ask about the most important part first.

Try this prompt:

> This page helps first-time visitors download a Mac app. Review the visible hierarchy and wording. Give me three changes, ranked by impact. Point to each element you mean. Keep the existing typeface and brand colors.

## Review in separate passes

- Hierarchy: can a reader identify the main message and next action?
- Wording: do labels describe a concrete action or hide behind vague language?
- Layout: do spacing and alignment group related content?
- Accessibility: which elements need a measured contrast or keyboard check?

Treat the critique as a set of hypotheses. Ask why each change supports the user’s goal, and reject suggestions that ignore constraints such as brand guidelines or a component library. A smaller set of specific changes is easier to evaluate than a complete redesign.

## Make one revision and compare

1. Duplicate the frame or use a safe branch of the page.
2. Apply one suggested change yourself, or approve a tightly scoped task if you want computer control.
3. Compare the original and revision at the same size.
4. Check the page at a narrow viewport and with longer real copy.
5. Keep the change only if you can explain the improvement.

Try this prompt:

> Compare the current version with the goal I gave you. Did this change make the next action clearer? Name one remaining issue and one part I should leave alone.

## Measure what a screenshot cannot establish

A screen image does not prove the exact contrast ratio, DOM reading order, keyboard focus behavior, responsive breakpoints, or screen-reader output. Use an accessibility checker and keyboard testing for those checks. HeyMate can help you understand the results on screen, but a visual opinion is not an accessibility certification.

For Figma work, inspect the actual spacing and typography values rather than copying measurements guessed from pixels. For a website, test the rendered page. The same design can behave differently with real content, browser zoom, or a different font load.

## Keep client work and permissions in view

Relevant screen images go to your selected AI provider. Use a sample frame or approved project material, and read the [privacy explanation](https://sayheymate.com/privacy). Connected app access is separate from simply looking at a Figma window; it depends on the tools and accounts you configure.

Start with the [screen guidance walkthrough](https://sayheymate.com/screen-guidance). For broader software practice, see [learning a Mac app with AI](https://sayheymate.com/blog/learn-mac-apps-with-ai). Results depend on the model and the context it can actually see.

## Related reading

- [Learn a Mac app with AI guidance, one step at a time](https://sayheymate.com/blog/learn-mac-apps-with-ai)
- [Ask HeyMate for diagrams and visual explanations on your desktop](https://sayheymate.com/blog/visual-explanations-on-mac)
- [HeyMate vs Raycast: which Mac AI workflow fits you?](https://sayheymate.com/blog/heymate-vs-raycast)

[Set up HeyMate](https://sayheymate.com/connect-claude-codex) · [Privacy](https://sayheymate.com/privacy) · [Permissions](https://sayheymate.com/permissions)
