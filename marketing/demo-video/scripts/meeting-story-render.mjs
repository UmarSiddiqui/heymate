// Render "Biryani night" stills or final films.
//   node scripts/askdraws-render.mjs stills <frame...>   |   node scripts/askdraws-render.mjs film
import path from 'node:path';
import fs from 'node:fs';
import {bundle} from '@remotion/bundler';
import {renderStill, renderMedia, selectComposition} from '@remotion/renderer';

const mode = process.argv[2] || 'stills';
const out = path.resolve('out/meeting-story');
fs.mkdirSync(out, {recursive: true});
const serveUrl = await bundle({entryPoint: path.resolve('src/meeting-story/index.tsx')});
for (const id of ['MeetingStory', 'MeetingStoryVertical']) {
	const composition = await selectComposition({serveUrl, id});
	if (mode === 'stills') {
		for (const frame of process.argv.slice(3).map(Number)) {
			await renderStill({serveUrl, composition, frame, output: path.join(out, `${id}-${String(frame).padStart(4, '0')}.jpg`), imageFormat: 'jpeg', jpegQuality: 90});
		}
		console.log('stills', id);
	} else {
		await renderMedia({serveUrl, composition, outputLocation: path.join(out, `${id}.mp4`), codec: 'h264', crf: 16, pixelFormat: 'yuv420p', audioCodec: 'aac', audioBitrate: '320k', concurrency: 4});
		console.log('film', id);
	}
}
