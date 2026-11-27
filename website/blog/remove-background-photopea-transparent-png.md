# Remove a logo background in Photopea and export a transparent PNG

Use Photopea’s Magic Wand to remove a solid logo background, clear enclosed white areas, and export a transparent PNG. Includes a free sample.

By the HeyMate project. Published 2026-11-27. Category: Workflows.

> Open the logo in Photopea. Select its solid background with Magic Wand, clear the selection, and repeat for any enclosed background. Choose File > Export as > PNG and check the downloaded image on a colored background.

## Open a sample logo

Use the [sample logo](https://sayheymate.com/assets/img/guides/photopea/sample-logo-a.png) to follow along. It has a teal hexagon, an orange square, and two separate white regions. Open it in [Photopea](https://www.photopea.com/) with File > Open. Keep a copy of the original so you can compare your export.

Magic Wand selects pixels with similar colors. It works well for this flat white background. For hair, shadows, or a subject with colors that blend into the background, try [Photopea’s Magic Cut guide](https://www.photopea.com/tuts/magic-cut-remove-image-background-online/) and inspect the edges before exporting.

## Clear the white background

1. Choose Magic Wand from the left toolbar. If Quick Selection is showing, open that tool group and choose Magic Wand.
2. For this sample, use Replace, Tolerance 16, and Feather 0 px. Leave Anti-alias and Contiguous on, and Sample All Layers off.
3. Click the white area outside the teal logo. Check that the selection skips the colored shapes, then choose Edit > Clear or press Delete. The cleared area shows a checkerboard.
4. The white hole inside the hexagon is disconnected from the outside. Use View > Zoom In if needed. Click inside the white hole, away from the orange square, and clear that selection too.

If clearing leaves white pixels, check whether you selected the right layer and whether another layer sits underneath it. A locked layer may need to be unlocked. If Magic Wand grabs part of your logo, undo, lower the tolerance, and inspect the selection again. [Photopea’s Magic Wand walkthrough](https://www.photopea.com/tuts/remove-background-from-photo/)

## Export and check the transparent PNG

1. Choose File > Export as > PNG and keep the original size. Check for checkerboard around the logo and in the hole in the export preview.
2. Click Save. Reopen the downloaded PNG over a colored layer, or drop it onto a colored Keynote slide. The color should show through both cleared regions.

![Teal hexagon and orange square on a transparent background.](https://sayheymate.com/assets/img/guides/photopea/sample-logo-a-transparent.png)

Actual 320 × 240 export from the guided Photopea run.

Use PNG for the final export because JPEG cannot store transparency. Our pixel check confirmed that both cleared regions were fully transparent and the original logo colors were intact. [Download the verified PNG](https://sayheymate.com/assets/img/guides/photopea/sample-logo-a-transparent.png)

## Ask for one step while you work

If you want help finding a tool, bring Photopea to the front and ask HeyMate with a [vision-capable provider](https://sayheymate.com/connect-claude-codex). Hold Control + Option to ask by voice, or use your configured typed shortcut.

Try this prompt:

> Show me how to remove this logo’s background in Photopea, one step at a time. Explain where to look and wait while I try each step.

During our guided run, the toolbar was too small for HeyMate to point confidently. Selecting Magic Wand by name and enlarging the image through View > Zoom In got the task moving again. The guided run used typed prompts, and the separate repeat was done without further HeyMate guidance. [See the test transcript and pixel checks](https://github.com/UmarSiddiqui/heymate/blob/main/docs/walkthroughs/photopea-background-removal.md)

## Related reading

- [Learn a Mac app with AI guidance, one step at a time](https://sayheymate.com/blog/learn-mac-apps-with-ai)
- [How to animate text in Keynote on Mac](https://sayheymate.com/blog/animate-text-keynote-mac)
- [Use HeyMate for a focused Figma or website design review](https://sayheymate.com/blog/ai-design-review-figma)

[Set up HeyMate](https://sayheymate.com/connect-claude-codex) · [Privacy](https://sayheymate.com/privacy) · [Permissions](https://sayheymate.com/permissions)
