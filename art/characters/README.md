# Milo and Nova source models

Original editable Blender models and authoring scripts for the bundled HeyMate characters live in `blender/`. Classic and Future outfits are preserved separately; the Milo accessories scene includes accessory geometry. Rendered runtime artwork lives in `heymate/HeyMate/Assets.xcassets`; appearance and gaze composition live in `MiloCharacter.swift` and `MiloGazeArtwork.swift`.

Open the `.blend` files in Blender to edit geometry and materials. The Python files preserve the October 15 modeling and layer-rendering workflow. They require Blender's `bpy` runtime and operate on the scenes in this folder. Create a `renders/` directory beside `blender/` before rendering. Scripts can replace scenes and produce hundreds of renders, so use a copy of this directory for experiments. The old session's render-resume list is deliberately not reused.

Script syntax has been checked; the full rendering pipeline has not been rerun during release integration. These files preserve editable source rather than packaged review apps, screen captures, or abandoned prototype studies.
