# Native Metal drawing renderer — 2026-10-29

HeyMate's installed explanation host now renders both `scene3d()` and `figure()` through Metal. `Explainer.swift` initializes `DaVinciMetalOverlay` and injects the native bridge before loading the drawing stage. Native initialization failure is logged and stops the explanation rather than silently switching its 3D stages to WebGL. The standalone browser fixtures retain their WebGL renderer for web-only development.

## Rendering path

The recovered drawing VM still generates geometry, manages timed speech beats, computes hierarchical transforms, camera framing, motion/tick poses, card rectangles, label placement and ray picking. Three.js supplies CPU geometry/math and material values; the native path never creates `WebGLRenderer` or a PMREM generator. The WebKit message bridge sends each mesh once, then sends current matrices, colors, bands, clipping planes and label anchors. One outstanding GPU command per stage bounds the frame queue. GPU completion acknowledges the frame. Hidden stages retain their geometry, removed stages release their views and renderer, and a new explanation receives a unique session token.

`DaVinciMetalRenderer.swift` owns native buffers, pipeline states, MSAA/depth targets, sorting and draw encoding. Its passes are:

1. Opaque part IDs, with the recovered cut-aware ID fragment.
2. Transparent part IDs, depth-tested against a copy of opaque depth.
3. Opaque color followed by transparent color, sorted back-to-front; 4× MSAA where supported.
4. Recovered dual-source ink/seam composition, using the two ID grids.

Clip depth converts from Three.js `[-1,1]` to Metal `[0,1]`; normal columns use inverse-transpose world matrices. The packed vertex stride is 48 bytes. Frame uniforms are 96 bytes; object uniforms are 448 bytes. Color output uses BGRA8Unorm with sRGB display metadata because the recovered fragment already encodes linear values to sRGB. Alpha is composited as premultiplied output on the transparent native surface.

`DaVinciMetalOverlay.swift` presents each stage with an event-driven `MTKView`; drawable acquisition and presentation occur inside its draw delegate. A native label layer preserves label positions above the mesh. The overlay returns nil from hit testing, leaving card dragging and orbit/pick interactions in the existing web host. Cut-away surfaces are excluded from ray picking. Drawable dimensions are bounded to 4096 per axis and 4,194,304 pixels.

## Source fidelity and remaining calibration

`HeyMate/DaVinciShaders.txt` is byte-identical to `scripts/native-shaders/davinci.metal`. As of 2026-10-31 those files are a rewrite; the recovered literal's SHA-256 `1162dd2d8f94e1e929a68c7bde0f521917121e1d928a406c29503c36b9d938ba` (12,203 bytes) stays in `scripts/native-shaders/provenance.json`. The resource is compiled on the native Metal device. `mate_shade` is already callable, so the host no longer rewrites the fragment signature. An added fragment adapter applies cut-plane coverage consistently to color and ID passes and shades interior back faces with diagonal hatching.

The Swift rendering host is newly implemented. The shader it compiles was rewritten on 2026-10-31; it is not the recovered literal. Illustrated light direction `(3,5,4)`, pen widths/strength, hatch pattern, material preset values and label styling are adapter choices, not recovered original host constants. Studio selects the shader's physical GGX/Lambert branch; it does not reproduce the previous Three.js environment-map/floor-shadow setup, nor establish equivalence to ReferenceRenderer's complete studio host. Exact original material tables, lighting defaults, studio reflection/shadow composition, transparent intersection sorting, overlapping web-card/native-stage stacking and pixel parity still require reference comparison. Metal alone does not establish a quality match.

## Verification

Run without installing or launching HeyMate:

```bash
./scripts/verify_native_metal.sh
./scripts/typecheck.sh --tests
```

The first command runs bridge/math regressions, typechecks native overlay code and executes the production renderer on the real GPU with Metal API validation. It checks mesh coverage, transparent background, illustrated versus physical lighting, alpha blending, cut coverage, ID outlines, seam shading and rejection of invalid indices. It also renders recovered-kernel geometry through the actual JS bridge and native renderer. PNGs are saved under `../output/metal/`, including `gallery-illustrated.png` and `gallery-physical.png`.

Use `./script/build_and_run.sh --verify` for local installation, preserving the installed signing identity and compatible designated requirements. If the shell selects Homebrew Node, set `HEYMATE_NODE_BINARY` to an existing self-contained official distribution as described in `local-development.md`. No ad-hoc signing or privacy reset is part of this work.

## Installed verification and airplane fixture — 2026-10-29

Verified local installation preserves the installed Apple Development identity and mutually compatible designated requirements. The installed engine/shader/bridge resources pass `verify_recovered_ports.py --installed`; ten bridge/math/streaming regressions and the GPU fixture pass with Metal API validation on Apple M5.

A live explanation in `/Applications/HeyMate.app` renders illustrated and studio stages, animates poses, responds to orbit dragging, draws native labels and clears both stages. The app's screenshot endpoint deliberately excludes its own windows; use an app-window capture for visual inspection of this overlay.

`scripts/airplane-metal-test.js` is a reusable `/explain` program. Its recovered engine output contains 52 mesh parts, three groups, three labels and three motion commands. All recovered mesh recipes build successfully (34,601 vertices), without engine warnings. It exercises mirrored geometry, nonuniform scale, transparent cockpit glass, nested rotor groups and spinning turbofans in the installed native renderer.

The drawing overlay now exposes an accessible **Clear** button (`drawing-clear`) at the top right. It dismisses the complete drawing overlay, releases native stages, cancels its pending drawing work and clears the pointing target. The native control lives in a small child panel above the Metal surface; other screen regions remain click-through.


## Streaming and dismissal follow-up — 2026-10-29

The original airplane demo sent a complete program with one speech beat; it did not validate token streaming. The fixture now has four speech beats. `POST /explain` with `stream: true` replays cumulative 120-character prefixes through the same `streamExplainer` controller used by model deltas. `GET /explain/state` reports current visual state and actual completed native frame/mesh counts. These are local diagnostics under the existing loopback/authentication policy, not a model-network integration test.

Live replay reached 52 mesh parts progressively (recorded counts include 7, 10, 20, 36 and 52), with 661 completed native frames at the final sampled count. `output/metal/stream-progress.json` retains the samples. A coordinate click on Clear during another replay dismissed the overlay; eight seconds of subsequent polling confirmed later chunks did not reopen it (`output/metal/clear-stream-check.json`). Paths are relative to the repository root.

Silent Mode previously guarded both drawing-stream callbacks and final drawing playback, suppressing visuals with speech. Drawing callbacks now run regardless of Silent Mode; the narration loop skips speech while muted and uses reading time for beat progression. Final muted replies also close the stream when the model omits its fence. Clear records the dismissed response owner, so its subsequent chunks and final replay stay dismissed; a new response resets that dismissal.

Labels now use geometry bounding-box centers transformed through their parents, rather than assuming each mesh origin is its visual center. Studio outer ink is thinner than illustrated ink. These remain adapter choices; source reference calibration is still outstanding for lighting/material presets, studio reflections/shadows, outline widths and callout placement. Compile/GPU checks and a successful live airplane test do not establish ReferenceRenderer visual parity.
