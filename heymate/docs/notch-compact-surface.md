# Compact notch surface

Updated 2026-10-31 after approval to implement and install locally.

The resting notch keeps the hardware's flat top, height, center and scaled
bottom radius. A static approved 05 Mischief line mark occupies a 24-point wing
outside the camera; there is no filled character, body, tile or ready label.
The opposite wing balances the silhouette. Voice adds just 64 points total;
managed-task status adds 112 points total and wraps into two short lines.
Usage wings grow only enough for the configured provider rings. The hardware
measurement functions remain unchanged.

The line mark comes from the user-approved logo chat's final baby-blue kit:
`/Users/umarsiddiqui/.codex/visualizations/2026/10/31/01a18fb9-2ecb-75d2-89df-2a19e2fc5560/heymate-logo-kit-baby-blue/notch-handoff.md`.
`docs/notch-mischief.svg` preserves its SVG master. `NotchBrandMark.swift` draws
the exact four paths with round caps/joins, nine-unit stroke in the 128-unit
viewBox, a 20-point canvas, and approved #A8CBFA. No raster decoding, timer,
glow, gradient, or expression animation is added. Visible artwork is about
16.4 by 13.1 points. The mark appears at rest and while planning/working;
attention and terminal states retain explicit status symbols.

Voice activity takes precedence over managed-agent status, then ambient activity,
then provider usage. Approval takes precedence among managed agents. Real
`AgentRun.latestAction` updates the compact label without replacing the host view.
Multiple active runs show a count; their selection stays stable until attention
or a lifecycle change warrants switching. Completion, failure and cancellation
appear for six seconds only after an observed live-to-terminal transition.
Historical completions do not replay at launch. The expiry uses one cancellable
task rather than polling. Idle has no new animation timer. The thinking state
uses the static mark and ellipsis; no spinner or long voice label widens it.

## Reference boundary

Reference directory, outside the product tree:
`/Users/umarsiddiqui/Projects/Umar/HeyMateReferenceArchive/references/heyclicky/native-1.1.1/`.

- `decompiled/by-type/HeyClicky.NotchRestingMarkSurface--0x1031aa04c.md` associates
  an idle-surface entry with the corresponding compiled type. Its fields observe
  the companion, roster, job store and reports.
- `declarations/types/HeyClicky.NotchSilhouetteShape--0x1031acca0.md` declares
  separate top/bottom radii. `NotchLiveEventCornerGlow--0x1031ac414.md` declares
  presentation, edges, an optional agent tint override and Reduce Motion input.
- `geometry-native-findings.md` separates measured hardware geometry from content
  geometry and documents the static live-event dispatch.

These establish reference structure, not exact visual equivalence. The archive
labels decompiler output as unreviewed, non-compilable pseudocode. No decompiled
implementation or HeyClicky artwork was imported. State glyphs, edge glints,
selection, layout and six-second completion policy are HeyMate design choices.
The user's hardware-notch screenshot guided the tight corners and restrained
edge rather than an oversized nested outline.

## Open and close motion

The compact widths above stay unchanged. Standard card motion remains 280 ms
open and 180 ms close; full chat uses 320/200 ms. Mouse-exit grace stays 120 ms
and compact activity resizing takes 140 ms.

Opening now has a small, intentional anticipation cue: a native 16-point ring
replaces the leading mark during 160 ms hover dwell or a 90 ms deliberate-click
preparation. Its track/fill arc and scale spring run in Core Animation; no
TimelineView or polling updates the SwiftUI host. Leaving cancels a hover cue,
replacement cue IDs reject stale callbacks, and a click cannot be overridden by
another hover. Reduce Motion removes layer animations and bypasses click delay.

The opening response now has a restrained underdamped tail. Width stays clamped
to its compact/expanded endpoints; only vertical travel can settle past the target,
by at most two points. Closing remains critically damped without undershoot.
Frame and corners share the display-link clock; interrupted transitions retain
current morph state. Unshadowed panels do not invalidate nonexistent shadows.

### HeyClicky comparison boundary

The installed reference is now HeyClicky 1.1.2, universal executable SHA256
`04ab32ec2001c2c9aa5f771bfcbb5fe6557ac3a970cc7f7fc8637128f41a5c0a`,
arm64 SHA256 `864e3d19eabd66c84664cda05c0105bedbc8583ea08f7ec05bf12878b9e25a5a`.
Its local native UI exposes only a blank notch envelope, with no usable Home
control in the inspected window or Window menu, so current live motion timing
could not be measured through this session.

Archived 1.1.1 evidence establishes a separate dwell-ring design: reflected fields
identify `trackLayer`, `fillArcLayer` and `currentDwell`; function `0x1016aa190`
sets both layers to a 16-by-16 frame and supplies ellipse/arc paths. Retained
REA record: `ev_8c0eb52e61df0fa81aecbe0864a50d7ac668811988a0c807b70d3f1b2dad7207`.
The companion update wrapper at `0x1016aa888` selects active versus cleared dwell
paths (`ev_61b157f7d3fc01ffcfa70b8151de1fbbbb18ed91a0dc1e084ccb95e5a17f960c`).
These are archived decompiler observations, not original Swift or a claim that
all callees or current 1.1.2 timing were recovered.

Compared with HeyMate's previous immediate, critically damped expansion, this
adds visible anticipation and a small spring settle. Ring duration, spring
parameters and the two-point height cap are original HeyMate tuning choices.
Exact 1.1.2 timing parity is not claimed; no HeyClicky implementation is imported.

## Validation

`script/test_notch_core.sh` passed 106 tests, including live action changes,
approval priority, completion expiry/no replay, stable selection, camera
clearance and display anchoring. The observed resize regression is addressed by
deduplicating projected run snapshots, avoiding geometry checks when only task
words change, and refusing to restart an animation already targeting the same
frame. This is a code-path fix, not a claim of measured whole-app speedup.
The isolated usage host reads the actual shared micro-font declaration so it
compiles independently of app services.

`script/build_and_run.sh --verify` built, installed and launched only
`/Applications/HeyMate.app`. It retained the installed Apple Development signer,
checked mutually compatible designated requirements and verified the app plus
10 nested executables. Post-install `--check` also passed. No ad-hoc signing,
TCC reset or permission settings change occurred. The live idle surface and
opening its existing Usage panel were checked through native UI observation;
permission-protected actions were not independently exercised.
