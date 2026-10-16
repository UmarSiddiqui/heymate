# Cross-chat integration audit — 2026-10-16

Audited PR #61 after its Milo/Nova integration commit (`75b911f`). The audit covered all 19 registered Git worktrees, the recent related Codex chats, both remaining open feature PRs, and five saved combined source checkpoints. Source comparisons included tracked edits, untracked source files, deleted assets, and asset bytes; commit ancestry alone was not treated as proof because several historical PRs were squash-merged.

| Source | Result |
| --- | --- |
| Character/UI session, worktree `57a8` | Milo/Nova assets, editor, gaze, outfits/accessories, black/glass UI, handoff and integration changes present. No missing new source or assets. Older catalog tests updated for the final two-pack design. |
| Chat-wall session, worktree `4628` | Message layout, Markdown, execution-context disclosure, finished-task cards and notice persistence present. No missing new source files. |
| Earlier character-motion worktree | Original planning transport, motion, routines and appearance work present or superseded by later implementations. Older source differences retain the newer execution steering, work expressions, wake recovery and presentation mode. |
| Floating-circle chat and saved circle checkpoint | Compact native panels, fixed-avatar expansion, reports and private failure diagnostics present. |
| Voice settings and OpenCode chats | Automatic local voice setup, ElevenLabs Advanced settings, legacy preference migration, OpenCode installation/managed server/free-model selection present. |
| Adoption and steering checkpoints | Handoff, suggestions/skill discovery, onboarding, diagnostics, account recovery, progress health and approval-bound Codex execution steering present. |
| PR #59, sound/motion cues | Was missing; integrated during this audit. Adapted cues to current floating bubbles and task cards, and preserved list/quote formatting during word reveal. |
| PR #60, plain approval cards/read-risk classification | Was missing; integrated during this audit, including tests and action descriptions. Existing execution-approval ownership guards retained. |
| Uncommitted `snappy-notch` refinements | Was missing; integrated silhouette/shoulder geometry, tool-surface layout, control refinements and tests. Newer Milo/Nova glass controls win where older visual styling conflicts. |
| Historical merged branches | Already in main, including UI-test data isolation, composer, integrations, onboarding, paste support, and release compilation fixes. Obsolete pre-squash commit IDs do not imply missing behavior. |

The chat-wall, circle, finished-work, adoption and steering source checkpoints contain no production source/test files absent from the integrated checkout. Every character asset present in those checkpoints matches byte for byte. Differences in Swift files represent the later combined implementations and integration fixes; older implementations were not copied over newer work.

Editable Blender models are retained in `art/characters/blender`, together with all ten character authoring scripts and gaze geometry metadata. Script syntax was checked; the full rendering pipeline was not rerun. The old session's render-resume list is not reused.

Intentional exclusions: generated app bundles, build caches, raw captures, rendered demo exports, private runtime profiles, local mate memory (`AGENTS.md`, `CLAUDE.md`, stub), and abandoned prototype studies. These remain in their original locations. No production source file is excluded solely because it was uncommitted.

Validation results are recorded in PR #61. Build/unit checks do not establish live provider success, acoustic/visual timing, or deployment readiness. Original PRs #59 and #60 remain open; their changes are included here, so avoid merging overlapping implementations independently without reviewing the resulting diff.
