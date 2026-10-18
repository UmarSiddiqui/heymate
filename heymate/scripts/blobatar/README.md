# Blobatar native adapter

HeyMate uses [Blobatar](https://github.com/Alain00/blobatar) 2.7.0,
MIT licensed by Alain, pinned to commit
`a7fd546ebede49d0a9fa638945b9e534489782a2`.

`runtime.ts` adapts upstream drawing primitives, seeded idle loops, expression
poses and gaze projection to native drawing. `build-runtime.ts` bundles those
modules into the app's offline `BlobatarRuntime.js`. One shared JavaScriptCore
context computes geometry and numeric transforms; SwiftUI Canvas draws vectors.
There are no web views, remote dependencies or bitmap animation frames.

Characters breathe, bob and blink, smoothly morph between expressions, and
follow the cursor with independent eye transforms. Cursor tracking uses pointer
position only. Hidden views stop their timeline and release per-view motion
state. Reduce Motion and the existing idle-animation preference take precedence.

New bots use `blobatar:auto`, seeded from their persistent ID. Renaming never
changes the face. “New look” saves a fresh UUID seed; “Use bot identity” restores
the original. Older named presets and saved Milo, Nova and photo choices remain
supported.

Rebuild from this directory:

```sh
git clone https://github.com/Alain00/blobatar.git /tmp/heymate-blobatar
git -C /tmp/heymate-blobatar checkout a7fd546ebede49d0a9fa638945b9e534489782a2
bun build-runtime.ts /tmp/heymate-blobatar
```

`generate.ts` and its pinned resvg dependency reproduce the original PNG
reference artwork for the six named presets. Live rendering uses vectors.

Attribution is in `THIRD_PARTY_NOTICES.md` and bundled `Blobatar-LICENSE.txt`.
