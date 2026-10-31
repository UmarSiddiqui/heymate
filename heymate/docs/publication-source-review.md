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

## Telemetry replacement — 2026-10-30

The recovered telemetry module was removed. `agent-runtime/src/telemetry.mjs` now implements aggregation and compact logging from observed behavior and existing tests. The previous telemetry provenance manifest remains as historical evidence. The replacement awaits source and behavior review; its removal from the recovered-file inventory is not publication clearance for this file or the remaining sources.

The recovered early-read module was also removed. `agent-runtime/src/early-reads.mjs` now starts eligible reads using a newly written adapter; it retains argument identity, cancellation checks and result reuse. Its historical provenance entry is retained, and the replacement awaits source and behavior review.

The recovered step-journal module was removed. `agent-runtime/src/step-journal.mjs` now implements durable replay, read retries and uncertain-write refusal. Historical provenance is retained; the replacement requires source, compatibility and behavior review.

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

## Note tools replacement — 2026-10-31

`agent-runtime/src/notes.mjs` was rewritten. It keeps its contract with the harness and the session prompt: `noteEdits` (the six edits, each taking the note's markdown and the call's arguments and returning `{ md }`, an optional `note`, or an unchanged `md` with an `error`), `noteToolDefinitions` (the same tool names, arguments and required lists) and `noteInstructions`. The code is new: one pass reads the note's shape (code blocks, `:::` blocks, page levels), and the edits share a line finder that tries the exact line, then its words without markdown, then a part of it, then word overlap. The tool descriptions and instructions are rewritten in HeyMate's own words; they now describe what NoteMarkdownView actually shows, not the original's paper renderer. The unused closing instruction is gone. No substantive line is identical to the shipped original. Sequence similarity is 0.40, of which the code is 0.37 (mostly the regular expressions that define the note language and must match) and the text 0.47 (tool names and argument signatures).

Parity was measured on 70,353 edits: 6,000 random notes built from titles, pages, plan boxes, lists with details, tables, answer lines, quotes, code blocks and `:::` blocks, with CRLF and blank-line runs, each with a random edit and every streamed prefix of its last argument (as the live preview runs them). 60,894 are identical. Every one of the other 9,459 involves a code block or a `$` pattern in replacement text, and with those two fixes switched off the rewrite matches the old file on all 70,353. The fixes: code blocks keep their blank lines, and a `# comment` or `## heading` inside one is no longer read as a page (before, adding to a `## Setup` page put the new text inside its bash block, and an answer line could land inside a code block); `note_replace` puts `$$`, `$&` and `` $` `` in as typed instead of expanding them as `String.replace` patterns. Also fixed: a number or other non-string argument crashed four of the six edits, and a blank answer line wrote an empty answer card. `agent-runtime/test/notes.test.mjs` (9 tests) encodes this; the previous file fails 4 of them. The agent runtime's 74 tests pass. The historical block pin is kept under `replaced` in `scripts/recovered-port-hashes.json`. The replacement awaits source and behavior review; this is not publication clearance.

## Drawing engine replacement, in progress — 2026-10-31

`HeyMate/mate-draw-engine.js` (3,260 lines) is being rewritten one section at a time; each section ships only once it draws at least as well as before. The rest of the file is still the recovered code, so its status stays unchanged until the last section is done.

Done: the pen geometry (seeded noise, smooth curves, dashes, hand-drawn segments and ellipses, stroke outlines). The noise sequence is unchanged, so every wobble lands where it did. Smooth lines are now centripetal Catmull-Rom curves, which no longer loop or swing past unevenly spaced points (a long run into a short turn overshot by 10 units, now 3). Stroke outlines join their corners: a box's corners keep the line's full width instead of thinning to 70%, a bend over 100 degrees gets a round outer edge like a round nib, and the small loops an edge tied where the line turns tighter than the pen is wide (spikes past hairpins, notches in inner corners) are cut out. Dashes are cut to their exact lengths. Against the old engine's six scripted native sessions, the only changes are path outlines and the pen times that follow a curve's length (at most 0.01 s). Regression tests: `scripts/draw_engine_tests.mjs`; five of its six tests fail on the old geometry.

Done: the program runner's core (where statements end, the rewrite that keeps declarations alive between streamed statements, whole and streamed runs, statement spans, code fragments). It still runs inside the Worker sandbox on its own. Statement ends now skip regular expressions and template literals with `${}` nested to any depth (a regex like `/[;}]/` used to hide every later statement end, and nested templates split mid-string), keep arrow functions, comparisons and destructuring patterns that run onto the next line in one piece (`const { a } = o` across lines was split before the `=`, also inside Mate's own pieces), join `} catch` and `} finally` like `} else`, and a stray closing bracket no longer stops the scan. A `class` declared while streaming stays defined for later statements (it used to force the slow full re-run), and a line opening with `(`, `[` or a template starts a new statement as the model means it (run whole, `foo()` followed by `[1, 2].forEach(...)` crashed the drawing). Runtime errors name the program's own line: before, V8 counted one line off (or took a line of the engine file) and JavaScriptCore, the app's engine, never gave one; now V8 names the line of the program's innermost frame, and JavaScriptCore gives it whenever the program's own top-level code threw, and otherwise no line rather than a wrong one. A thrown value that is not an Error now shows its text. On a corpus of 15 programs (whole, streamed in 37-character chunks, spans and fragments), every difference from the old runner is one of these; the six scripted native sessions are byte-identical. Four of the six runner tests in `scripts/draw_engine_tests.mjs` fail on the old runner.

Done: the drawing calls (`line`, `graph`, `timeline`, `scene3d`, `figure` and the edits). A corpus of 16 programs — plain marks, a full graph, clipped series, both timelines, edits, a scene, a figure with copies, mirrors, cuts and turns, a hosted window, seeded `random()`, ink boxes and the warnings for bad calls — produces the same marks as before. The six scripted native sessions and the pieces' fingerprint drawings are unchanged.

What changed, each checked: a segment that crosses the graph with both ends outside is drawn across the frame (it used to vanish, with a warning that the line was outside); a non-finite sample splits the stroke instead of bridging the hole with a chord; East Asian characters and emoji count as an em when a label or an ink box is sized (a Japanese label was measured as Latin and could sit on the axis or under a later piece); the period after a URL stays in the sentence and out of the click target; a surface function that throws no longer gives its name to the next part. In the sandbox, `scene3d` and `figure` used to stop on the first call (`global is not defined`, and colour names had no table). They now draw, and `color: 'red'` is the same hex the page uses. Three new tests in `scripts/draw_engine_tests.mjs` cover the frame crossing, the wide letters and the link, and a coloured sphere in the sandbox.
