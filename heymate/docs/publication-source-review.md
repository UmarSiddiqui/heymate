# Publication source review — 2026-10-29

Status: unresolved, advisory. Current implementation must not be represented as cleared for publication.

The local drawing parameter work uses Swift-native paths. Separate drawing,
geometry, browser, notes, workflow and shader resources retain recovered source.
Renaming symbols, changing comments, and correcting spelling do not establish
independent authorship or permission to distribute those implementations.

`../publication-sources.json` records known unresolved files. The user requested release on 2026-10-29 with this review unresolved.
The release workflow and manual release script no longer enforce this inventory.
Local signed development builds remain available for comparison.
The advisory review is not legal clearance, and the inventory is
not a claim that every other file has already been reviewed.

No bulk replacement has been accepted. Preserve public command schemas,
streaming behavior, safety controls and rendering until reviewed replacements
pass regression and visual comparisons. Existing licensed dependencies retain
their notices; publishing requires completing the separate source review.

Original reference material and pre-rename snapshots were preserved outside
this checkout in the sibling `HeyMateReferenceArchive` directory. Historical
hashes remain in manifests beside hashes of the renamed local resources.
Current hashes validate packaging only; they do not prove originality.

Validation so far: 30 browser/render tests and 63 agent-runtime tests pass.
Four isolated publication-gate tests also pass; the actual inventory correctly
reports unresolved source review; release enforcement was subsequently removed by user request. Signed local installation passes certificate, mutually compatible designated
requirements, nested signature checks, and startup verification. These checks
provide regression evidence; they do not establish complete behavioral parity.

Known misspelled internal reference comments were replaced with neutral resource
descriptions. Source and resource names use this project's namespace. Source
history, generated build artifacts and the external reference archive are not
rewritten by this cleanup.

## 3D part builder replacement — 2026-10-31

The recovered 3D part builder was replaced. `HeyMate/mate-three-parts.js` keeps its public contract (`mateThreeKinds`, `mateThreeBuild(kind, recipeJSON)`, every kind and recipe key, the packed output arrays) and is otherwise newly written: its own profile revolver with crease-aware normals, curve sweeps with round or flat ends, wall builder, soft-shape mesher (narrow-band surface nets with Newton projection onto the surface), SVG path reader and packing. Measured against the shipped original, 6% of substantive lines remain identical, all generic idioms (loop headers, cross products, the public function signature); sequence similarity is 0.05.

Behavior was held to the previous file on a 37-recipe corpus: bounds, volume within 2% (soft and noise blobs within their noise), outward winding and build time at parity (soft blobs ~24 ms in both). Defects in the recovered file are fixed: open ends on pipes, springs, arrows and partial tori; open sides on partial cylinders; smooth-shaded sharp rims; a crash on repeated arrow points; prototype names accepted as kinds. `scripts/three_parts_tests.mjs` (9 tests) encodes these; the previous file fails 5 of them. The native Metal check, stage, screen-sampling and browser-port suites pass. The historical hash pin is retained in `scripts/recovered-port-hashes.json` under `replaced`. The replacement awaits source and behavior review; this is not publication clearance.

## three.js slice rebuilt — 2026-10-31

`HeyMate/mate-three.js` was the recovered three.js bundle, built by a script and entry list that were not in this repository and had not been inventoried. It is now built here: `scripts/three-kernel/entry.mjs` exports the 23 three.js classes and helpers the part builder uses, and `scripts/three-kernel/build.mjs` bundles them with esbuild 0.28.1 from three.js 0.186.1 source modules (MIT; versions pinned in its package-lock.json). The bundle is reproducible (`npm run check`), 127 KB instead of 425 KB, and loads in about a third of the time. All 38 regression recipes build byte-identical geometry with the old and new bundle. `scripts/three_parts_tests.mjs` now fails if the slice and the builder's usage drift apart or if the committed bundle differs from its build. The three.js MIT notice is in THIRD_PARTY_NOTICES.md.

## Drawing pieces replacement — 2026-10-31

`HeyMate/mate-draw-pieces.js` was rewritten. It keeps every public piece and its signature (the calls CompanionPrompts.swift teaches the model, plus the welcome tour's pieces), the engine's `__card3d` hook, and the visual design values (colours, sizes, spacing), so drawings keep their look. The code is new: one scoped statement exposes only the pieces and `INK`, and the helpers and per-drawing state stay private. Before, about 70 helper names shared the program's scope, and a program declaring one of them silently changed how pills were placed. The comments that named the original authors are gone. Against the shipped original, 6.3% of substantive lines remain identical; all are public function signatures or icon names. Sequence similarity is 0.048.

Parity was measured by running 101 drawing programs (60 randomly generated) through the engine under 7 host setups: each cursor colour, 2x scaling, host-drawn pointers, buttons and windows, busy-screen maps, and invalid inputs. That is 707 runs and 26,912 marks; 448 runs are identical. Every one of the 525 differing marks is one of three deliberate fixes, each checked rendered: `trace({fill: true})` now draws its tint (the colour was dropped before, so nothing was filled); a sticky's folded corner turns with its sheet; pills, legends and credits are sized for East Asian and emoji characters, whose text was squeezed before. Inputs that used to stop a program now draw what they can: a labelled stroke with no points, a non-list receipt, a button anchored to something without a box. Lower-case ink colours are accepted. `scripts/draw_pieces_tests.mjs` (9 tests, including fingerprints of three representative drawings under three host setups) encodes this; the previous file fails 8 of them. The historical hash pin is kept under `replaced` in `scripts/recovered-port-hashes.json`. The replacement awaits source and behavior review; this is not publication clearance.

## Native drawing canvas replacement — 2026-10-31

`HeyMate/mate-draw-native.js` was rewritten. It keeps its contract with mate-host.js: the globals it installs (timers on the host clock, the DOM slice the engine paints into, `__drainRender`, `__mateMotion` and the host hooks), the `__host` calls it makes, the JSON ops it hands over, and every `mateCanvas` method with its arguments and results. The code is new. The drawing's state is one record replaced as a whole on reset (no field-by-field clearing to keep in step). Sounds, edits and actions are table-driven, statement progress and figure poses are computed instead of accumulated by hand, and the DOM is written in its own style. Comments naming the original authors are gone. Against the shipped original, 7.8% of substantive lines remain identical, mostly the host-facing names and signatures; sequence similarity is 0.070.

Parity was measured by driving six scripted sessions against a deterministic host with a hand-wound clock: a streamed drawing fed in seven chunks with subtitles, lines, buttons, card moves and zooms, a continued turn, dropPointing, keepNotesOnly and closeCard; an interrupted stream; a syntax error; a 3D figure whose tick functions run; renderWhole; and every method called with no drawing. Every host call, return value and paint drain was recorded. All six sessions are byte-identical to the previous file except one deliberate change: error messages now count lines from the program's own first line ("syntax error after line 1") instead of from the top of Mate's pieces ("line 727"). A runtime error's line still comes from the JavaScript engine's stack text, so that one is only rebased when it falls inside the program. `scripts/draw_native_tests.mjs` (8 tests, including fingerprints of a full streamed session and a whole render) encodes this; the previous file passes all but the error-line test. The explainer's real page boots it and draws the same 50 marks with no console errors. The historical hash pin is kept under `replaced` in `scripts/recovered-port-hashes.json`. The replacement awaits source and behavior review; this is not publication clearance.
