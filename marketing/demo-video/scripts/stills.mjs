// Renders review stills for every scene (landscape + vertical) into out/stills/.
// Usage: node scripts/stills.mjs [landscape|vertical] [sceneId]
import path from 'node:path';
import fs from 'node:fs';
import {bundle} from '@remotion/bundler';
import {renderStill, selectComposition} from '@remotion/renderer';

const [, , orientationArg, onlyScene] = process.argv;
const orientations = orientationArg ? [orientationArg] : ['landscape', 'vertical'];

// Seconds into each scene worth checking.
const MOMENTS = {
  hook: [0.6, 2.2, 3.8],
  logo: [0.5, 2.5],
  notch: [0.5, 2.6, 4.8],
  vision: [2.2, 4.1, 6.5],
  agents: [2.2, 4.3, 6.8],
  mates: [1.0, 5.8],
  close: [0.4, 3.5],
};

const outDir = path.resolve('out/stills');
fs.mkdirSync(outDir, {recursive: true});
const serveUrl = await bundle({entryPoint: path.resolve('src/index.ts')});

for (const o of orientations) {
  for (const [scene, times] of Object.entries(MOMENTS)) {
    if (onlyScene && scene !== onlyScene) continue;
    const id = `${o === 'vertical' ? 'vscene' : 'scene'}-${scene}`;
    const composition = await selectComposition({serveUrl, id});
    for (const s of times) {
      const frame = Math.min(composition.durationInFrames - 1, Math.round(s * composition.fps));
      const output = path.join(outDir, `${o}-${scene}-${s.toFixed(1)}s.png`);
      await renderStill({composition, serveUrl, output, frame, imageFormat: 'png'});
      console.log(output);
    }
  }
}
