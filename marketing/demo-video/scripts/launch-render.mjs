import path from 'node:path';
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
import {bundle} from '@remotion/bundler';
import {renderStill,renderMedia,selectComposition} from '@remotion/renderer';
const mode=process.argv[2]||'stills';
const out=path.resolve('out/launch');
fs.mkdirSync(out,{recursive:true});
const serveUrl=await bundle({entryPoint:path.resolve('src/launch/index.tsx')});
const composition=await selectComposition({serveUrl,id:'HeyMateLaunch60'});
console.log('Composition ready',composition.width,composition.height,composition.durationInFrames,composition.fps);
if(mode==='stills') {
 const frames=process.argv.slice(3).length?process.argv.slice(3).map(Number):[52,130,340,620,825,995,1180,1370,1590,1815,2050,2310,2540,2770,3060,3310,3480];
 for(const frame of frames){await renderStill({serveUrl,composition,frame,output:path.join(out,`frame-${String(frame).padStart(4,'0')}.jpg`),imageFormat:'jpeg',jpegQuality:95});console.log('Still',frame);}
} else {
 let logged=-1;
 await renderMedia({serveUrl,composition,outputLocation:path.join(out,'HeyMate-render-master.mp4'),codec:'h264',crf:17,pixelFormat:'yuv420p',audioCodec:'aac',audioBitrate:'320k',concurrency:4,onProgress:({progress})=>{const p=Math.floor(progress*100);if(p>=logged+5){logged=p;console.log(`Render ${p}%`);}}});
 execFileSync('ffmpeg',['-v','error','-y','-i',path.join(out,'HeyMate-render-master.mp4'),'-map','0:v:0','-map','0:a:0','-c:v','libx264','-preset','medium','-crf','17','-vf','scale=in_range=full:out_range=tv:in_color_matrix=bt601:out_color_matrix=bt709,format=yuv420p','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-color_range','tv','-map_metadata','-1','-af','atrim=duration=60,asetpts=PTS-STARTPTS','-c:a','aac','-b:a','320k','-ar','48000','-t','60','-movflags','+faststart',path.join(out,'HeyMate-60s-1080p60.mp4')],{stdio:'inherit'});
 console.log('Final render complete');
}
