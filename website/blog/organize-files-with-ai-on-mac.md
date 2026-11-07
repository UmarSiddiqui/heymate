# Organize Mac files with AI: plan first, move second

Use HeyMate to draft a file organization plan, preview renames, and review small batches. Includes duplicate handling and verification prompts.

By the HeyMate project. Published 2026-11-01. Category: Workflows.

> HeyMate can help plan file organization and hand an approved task to tools with the access you configure. Start with an inventory and a proposed change list; a filename alone does not establish that a file is safe to delete.

## Define what “organized” means

A folder can be tidy and still be hard to use. Choose a rule that helps your next task: group invoices by year, collect assets by project, or separate exports from source files. Name the one folder in scope. Keep a backup or work on a sample copy before trying an agent on files that matter.

Try this prompt:

> Inspect only this sample folder. Propose a folder structure and a table of current paths and proposed paths. Do not move, rename, overwrite, or delete anything yet. Flag ambiguous items for my review.

## Review the proposed paths

- Keep original file extensions and identify filename collisions.
- Ask for the rule used for dates instead of assuming a filename contains the creation date.
- Separate exact duplicates from files that merely look similar.
- Leave uncertain items unchanged and list the question needed to place them.
- Keep a record of the original path for every proposed change.

A useful plan should be understandable without running it. If the agent cannot explain why an item belongs in a destination, a catch-all “review” folder may be better than a confident guess. Do not mix a cleanup with an unrelated change to permissions, synchronization, or cloud storage.

## Approve a small batch

Try this prompt:

> Apply only the ten renames I approved. Do not overwrite existing files. Stop on a collision or missing file. Report every completed move and every skipped item, with original and new paths.

The tools available depend on the provider and integrations you connect. A Finder screenshot can support discussion, but it is not a complete inventory of nested folders. Use a configured file tool or coding job when the task needs an actual listing. Review the plan before granting broader access.

## Verify before considering deletion

1. Compare the reported changes with the approved list.
2. Open a few moved files and confirm their content is intact.
3. Check that project references or linked assets still resolve.
4. Keep the change log and backup while you use the new structure.
5. Handle deletion as a separate decision, after reviewing actual file contents or verified duplicate evidence.

HeyMate’s workspace snapshots support some local undo flows, not universal recovery across every folder or connected service. A remote move, synchronized deletion, or external action can have effects outside the local workspace. Do not treat an undo button as a replacement for a backup.

## Choose a simpler tool when the rule is fixed

If you repeatedly apply the same known transformation, an explicit automation or file-search workflow may be easier to inspect and maintain. Read [HeyMate versus Apple Shortcuts](https://sayheymate.com/blog/heymate-vs-apple-shortcuts) and [HeyMate versus Alfred](https://sayheymate.com/blog/heymate-vs-alfred) for those tradeoffs.

Before working on private files, review [what leaves your Mac](https://sayheymate.com/privacy). HeyMate is open source, but connected AI providers and services have their own processing and retention rules.

## Related reading

- [HeyMate vs Alfred: AI guidance or repeatable Mac workflows?](https://sayheymate.com/blog/heymate-vs-alfred)
- [HeyMate vs Apple Shortcuts: conversation or a defined automation?](https://sayheymate.com/blog/heymate-vs-apple-shortcuts)
- [Understand terminal errors with HeyMate before changing code](https://sayheymate.com/blog/explain-terminal-errors-with-ai)

[Set up HeyMate](https://sayheymate.com/connect-claude-codex) · [Privacy](https://sayheymate.com/privacy) · [Permissions](https://sayheymate.com/permissions)
