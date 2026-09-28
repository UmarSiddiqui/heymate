// Renders specific frames of a full composition into out/frames/.
// Usage: node scripts/frames.mjs <compositionId> <frame> [frame...]
import path from 'node:path';
import fs from 'node:fs';
import {bundle} from '@remotion/bundler';
import {renderStill, selectComposition} from '@remotion/renderer';

const [, , id, ...frames] = process.argv;
const outDir = path.resolve('out/frames');
fs.mkdirSync(outDir, {recursive: true});
const serveUrl = await bundle({entryPoint: path.resolve('src/index.ts')});
const composition = await selectComposition({serveUrl, id});
console.log(`${id}: ${composition.durationInFrames} frames @ ${composition.fps}fps`);
for (const f of frames.map(Number)) {
  const output = path.join(outDir, `${id}-${f}.png`);
  await renderStill({composition, serveUrl, output, frame: f, imageFormat: 'png'});
  console.log(output);
}
