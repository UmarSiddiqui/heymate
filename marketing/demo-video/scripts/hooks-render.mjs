// node scripts/hooks-render.mjs stills [frames...]   → out/hooks/<id>-<frame>.jpg
// node scripts/hooks-render.mjs render [ids...]       → out/hooks/<id>.mp4
import path from 'node:path';
import fs from 'node:fs';
import {bundle} from '@remotion/bundler';
import {renderStill, renderMedia, selectComposition} from '@remotion/renderer';

const [mode = 'stills', ...rest] = process.argv.slice(2);
const out = path.resolve('out/hooks');
fs.mkdirSync(out, {recursive: true});
const serveUrl = await bundle({entryPoint: path.resolve('src/hooks/index.tsx')});
const ids = ['HookAnger', 'HookInsider', 'HookLazy'];

if (mode === 'stills') {
	const frames = rest.length ? rest.map(Number) : [20, 100, 220, 305, 345, 420, 540, 660, 760, 850];
	for (const id of ids) {
		const composition = await selectComposition({serveUrl, id});
		for (const frame of frames) {
			await renderStill({serveUrl, composition, frame, output: path.join(out, `${id}-${String(frame).padStart(3, '0')}.jpg`), imageFormat: 'jpeg', jpegQuality: 80, scale: 0.4});
		}
		console.log('stills', id);
	}
} else {
	for (const id of rest.length ? rest : ids) {
		const composition = await selectComposition({serveUrl, id});
		let logged = -1;
		await renderMedia({serveUrl, composition, codec: 'h264', crf: 18, pixelFormat: 'yuv420p', audioCodec: 'aac', audioBitrate: '320k', outputLocation: path.join(out, `${id}.mp4`), concurrency: 6, onProgress: ({progress}) => {
			const p = Math.floor(progress * 100);
			if (p >= logged + 20) {
				logged = p;
				console.log(id, `${p}%`);
			}
		}});
	}
}
