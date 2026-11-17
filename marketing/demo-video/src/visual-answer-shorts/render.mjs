import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {mkdir} from 'node:fs/promises';
import {bundle} from '@remotion/bundler';
import {getCompositions, renderMedia} from '@remotion/renderer';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const output = path.join(root, 'out/visual-answers-2026-11-12');
await mkdir(output, {recursive: true});
const serveUrl = await bundle({entryPoint: path.join(root, 'src/visual-answer-shorts/index.tsx'), publicDir: path.join(root, 'public')});
const compositions = await getCompositions(serveUrl);
for (const composition of compositions) {
  const name = composition.id.replace('Short-', '');
  if (process.argv[2] && name !== process.argv[2]) continue;
  await renderMedia({composition, serveUrl, codec: 'h264', audioCodec: 'aac', audioBitrate: '192k', crf: 17, pixelFormat: 'yuv420p', concurrency: 4, outputLocation: path.join(output, `heymate-${name}-real-notch-9.5s.mp4`)});
  console.log(`Rendered ${name}: 1440×944, 30 fps, 9.5 seconds, full recording with real notch.`);
}
