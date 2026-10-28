# Native drawing ports — 2026-10-29

These changes port source-backed implementation into HeyMate's existing host. They do not recover original Swift syntax or claim complete native rendering parity.

## Screen statistics: translated native algorithm

Source: ReferenceRenderer 1.1.1 (66) arm64 slice SHA-256 `bb98afe140170240037589647cbfe00099079655e9223ec87f7f702db3fb7911`. The byte-verified assembly bank is retained under `references/reference-renderer/native-1.1.1/offline-assembly/`; exact selected-window hashes are recorded in `../scripts/native-shaders/provenance.json`.

- Host registration at `0x101781e30` binds the literal `inkFor`, `busyFor` and `lumFor` keys to the reviewed callback chain.
- Ink (`0x10178cce8`) selects `#15171C` when dominant luminance exceeds `0.58`, otherwise `#FFFFFF`.
- Luminance (`0x10178dff4`) clips floor/ceil bounds to screenshot edges, samples with `max(1,floor(sqrt(area/400)))`, groups RGB luminance into twenty bins, and averages only the most populated bin. Equal counts retain the first, darker bin. RGB weights are `0.2126`, `0.7152`, `0.0722`, divided by `255`; alpha is not read.
- Busyness (`0x10178d124`, `0x1017933b0`, RGB helper `0x101793d10`) averages absolute adjacent-pixel luminance differences along horizontal and vertical scanlines. Scanline spacing is `max(1, regionDimension/160)` using integer division. Within each selected line, adjacent pixels are sampled without skipping. Bounds leave the native two-pixel edge margin.
- Invalid/empty regions retain the native unavailable/default results. Additional finite-input, pixel-count and transport validation are HeyMate adapter guards, not attributed to the target.

`mate-host.js` carries these translated routines. `Explainer.swift` converts the same image already supplied to the model into RGBA; `CompanionManager+Guidance.swift` passes that capture through both streaming and complete-program paths. No extra capture is taken. A missing/mismatched capture or screen change clears the previous pixels. A continued drawing receives the new capture before its next program executes.

Validation: eight Node tests cover channel weights, bright/dark backgrounds, histogram versus global mean, histogram ties, horizontal/vertical gradients, large-region scanline strides, clipping, invalid replacement and screen-change invalidation. A standalone compilation of the actual Swift adapter confirmed RGBA channels, top-left row order, missing-capture and dimension-mismatch handling. Two Swift test methods were added to `ExplainerParserTests.swift`; execution of the full test target is a separate check.

## Illustrated 3D: recovered shader source, GLSL ABI port

The complete 12,203-byte Metal source literal was recovered at arm64 slice offset `0x2eb4350`, ending immediately before its NUL terminator. `../scripts/native-shaders/davinci.metal` preserves those exact bytes; SHA-256 is `1162dd2d8f94e1e929a68c7bde0f521917121e1d928a406c29503c36b9d938ba`.

The retained source compiled through the local Metal device with all seven original shader entrypoints present. This validates the extracted source literal, not native host/render parity.

`mate-stage3d.js` ports `D_GGX`, `V_GGX_SmithCorrelated`, `F_Schlick`, `BRDF_GGX`, `sRGBFromLinear` and `davinci_fragment` through mechanical type/intrinsic/resource-signature substitutions. The original lighting, cool shadow, glossy highlight, roughness and sRGB function bodies are retained. The new vertex/uniform adapter supplies world coordinates, inverse-transpose normals, camera position, color, opacity, glow, flat/double flags and color bands. Shader output is already sRGB, so Three.js tone mapping is disabled for this material. Dynamic part color/glow changes update uniforms before each draw.

Recovered drawing source distinguishes `scene3d()` (absent look, illustrated) from `figure()` (`look: studio`). The host now preserves that distinction. Legacy `scene3d` shape parameters are serialized into the existing recovered mesh kernel; figure recipe strings remain intact. Unit tests compare every translated fragment body to the preserved original, exercise changing uniforms, and verify that studio figures retain their separate material path.

The real-browser regression in `render_port_check.js` additionally compiles the illustrated fragment, renders recovered sphere geometry, checks framebuffer alpha/color variation and GL errors, and saves `output/playwright/3d-illustrated-port.png`. Its execution results must be reported separately; the presence of the script is not a passing GPU test.

## Remaining native fidelity limits

The native Core Animation painter/Core Text shaper, native material preset tables, native illustrated light-uniform defaults, ID-buffer outline/seam passes and studio multipass renderer are not fully ported. The illustrated adapter uses the original shader's physical-key direction `(3,5,4)`; equivalence to the compiled native illustrated host's default is unproved. Existing figure studio rendering continues using HeyMate's Three.js adapter. Native card/text geometry, pixel parity, original native GPU frame pacing and audible speech/frame synchronization are not established by these ports.

The six previously recovered JavaScript engines and pinned note-editing block remain unchanged. No app signing, permission reset, original app execution or production deployment was performed by this scoped work.

## Native Metal host added — 2026-10-29

The installed explanation host now selects a native Metal renderer for both illustrated and studio stages. The earlier WebGL port remains for standalone browser fixtures. See [native-metal-renderer.md](native-metal-renderer.md) for the new bridge, native passes, GPU validation and explicit remaining fidelity/calibration limits. Earlier sections describe the previous port and its validation boundaries.
