import React from 'react';
import {AbsoluteFill, Audio, Img, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {VO_WORDS} from './voWords';

// "Biryani night" — first-person story film. Human scenes are AI-generated (Google Flow) and
// labelled as a dramatization; the HeyMate parts are real screen captures, labelled.
export const FPS = 30;
const VO_AT = 6;
export const TOTAL = Math.ceil((VO_WORDS[VO_WORDS.length - 1].end + 1.3) * FPS) + VO_AT;

const C = {ink: '#06080c', paper: '#F3F4F1', tide: '#9FD0C8'};
const font = 'Figtree, "Avenir Next", sans-serif';
const src = (n: string) => staticFile(`biryani-story/${n}`);
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const ease = (f: number, start: number, dur = 20) => {
	const x = Math.max(0, Math.min(1, (f - start) / dur));
	return 1 - Math.pow(1 - x, 4);
};
const at = (s: number) => Math.round(s * FPS) + VO_AT;
const wordAt = (w: string) => VO_WORDS.find((x) => x.w.replace(/[^\w']/g, '') === w)!.start;
const useV = () => {
	const {width, height} = useVideoConfig();
	return height > width;
};

const Grade: React.FC = () => (
	<>
		<AbsoluteFill style={{background: 'radial-gradient(ellipse at 50% 45%, transparent 55%, #000b 100%)'}} />
		<AbsoluteFill style={{background: 'linear-gradient(180deg, transparent 55%, #000a 100%)'}} />
	</>
);

const Tag: React.FC<{children: React.ReactNode}> = ({children}) => {
	const v = useV();
	return <div style={{position: 'absolute', right: 36, top: v ? 60 : 32, fontSize: 17, letterSpacing: 0.3, color: '#d3d8e0', padding: '7px 12px', borderRadius: 8, background: '#06080c99', border: '1px solid #ffffff18'}}>{children}</div>;
};

// Human scene from Flow, full-bleed with slow drift.
const Shot: React.FC<{clip: string; startFrom?: number; rate?: number; focusX?: number}> = ({clip, startFrom = 0, rate = 1, focusX = 50}) => {
	const f = useCurrentFrame();
	return (
		<AbsoluteFill style={{background: C.ink}}>
			{clip.endsWith('.jpg') || clip.endsWith('.png') ? (
				<Img src={src(clip)} style={{width: '100%', height: '100%', objectFit: 'cover', objectPosition: `${focusX}% 50%`, transform: `scale(${1.04 + f / 900}) translateX(${-f / 40}px)`}} />
			) : (
				<OffthreadVideo src={src(clip)} startFrom={Math.round(startFrom * FPS)} playbackRate={rate} muted style={{width: '100%', height: '100%', objectFit: 'cover', objectPosition: `${focusX}% 50%`, transform: `scale(${1.03 + f / 3000})`}} />
			)}
			<Grade />
			<Tag>Dramatization · AI-generated scene</Tag>
		</AbsoluteFill>
	);
};

// Real recording (1920×1260), cropped to a region of interest, floating over a blurred copy.
type Roi = {x: number; y: number; w: number; h: number};
const Capture: React.FC<{clip: string; startFrom: number; rate: number; roi: Roi; label: string}> = ({clip, startFrom, rate, roi, label}) => {
	const f = useCurrentFrame();
	const {width, height} = useVideoConfig();
	const v = height > width;
	const panel = v ? {w: 1000, h: 1000 * (roi.h / roi.w)} : {w: 1500, h: 1500 * (roi.h / roi.w)};
	if (!v && panel.h > 860) Object.assign(panel, {h: 860, w: 860 * (roi.w / roi.h)});
	const s = panel.w / roi.w * (1 + ease(f, 0, 240) * 0.04);
	const p = ease(f, 0, 18);
	const video = (style: React.CSSProperties) => <OffthreadVideo src={staticFile(`askdraws/${clip}`)} startFrom={Math.round(startFrom * FPS)} playbackRate={rate} muted style={style} />;
	return (
		<AbsoluteFill style={{background: C.ink}}>
			{video({position: 'absolute', width: '100%', height: '100%', objectFit: 'cover', filter: 'blur(40px) brightness(0.45) saturate(1.2)', transform: 'scale(1.2)'})}
			<div style={{position: 'absolute', left: (width - panel.w) / 2, top: (height - panel.h) / 2 - (v ? 80 : 30), width: panel.w, height: panel.h, borderRadius: 26, overflow: 'hidden', boxShadow: '0 40px 110px #000c, 0 0 0 1px #ffffff22', opacity: p, transform: `scale(${0.96 + 0.04 * p})`}}>
				{video({position: 'absolute', width: 1920 * s, height: 1260 * s, left: panel.w / 2 - (roi.x + roi.w / 2) * s, top: panel.h / 2 - (roi.y + roi.h / 2) * s, maxWidth: 'none'})}
			</div>
			<Tag>{label}</Tag>
		</AbsoluteFill>
	);
};

const Steps: React.FC = () => {
	const f = useCurrentFrame();
	const v = useV();
	const base = at(wordAt('Marinate'));
	return (
		<div style={{position: 'absolute', left: 0, right: 0, top: v ? 300 : 90, display: 'flex', justifyContent: 'center', gap: 16, flexWrap: 'wrap'}}>
			{[['Marinate', '#F6D66B'], ['Boil', '#A6DFAE'], ['Fry', '#F5B39A'], ['Layer', '#AFCDF5']].map(([w, c]) => {
				const p = ease(f, at(wordAt(w)) - base, 14);
				return <div key={w} style={{fontSize: v ? 44 : 40, fontWeight: 800, color: '#1b1b1b', background: c, padding: '14px 26px', borderRadius: 14, transform: `translateY(${(1 - p) * 30}px) rotate(${(w.length % 3) - 1}deg)`, opacity: p, boxShadow: '0 16px 40px #0007'}}>{w}</div>;
			})}
		</div>
	);
};

// Word-synced captions: the current sentence, active word in tide.
const Captions: React.FC = () => {
	const f = useCurrentFrame();
	const v = useV();
	const t = (f - VO_AT) / FPS;
	const sentences: (typeof VO_WORDS)[number][][] = [];
	let cur: (typeof VO_WORDS)[number][] = [];
	VO_WORDS.forEach((w) => {
		cur.push(w);
		if (/[.?!,]$/.test(w.w) && cur.length >= 2 || /[.?!]$/.test(w.w)) {
			sentences.push(cur);
			cur = [];
		}
	});
	if (cur.length) sentences.push(cur);
	const s = sentences.find((g, i) => t >= g[0].start - 0.05 && t < (sentences[i + 1]?.[0].start ?? g[g.length - 1].end + 0.6) - 0.05);
	if (!s) return null;
	return (
		<div style={{position: 'absolute', left: 60, right: 60, bottom: v ? 330 : 70, textAlign: 'center', fontSize: v ? 64 : 54, fontWeight: 800, letterSpacing: -1, lineHeight: 1.15, textShadow: '0 4px 24px #000c'}}>
			{s.map((w, i) => (
				<span key={i} style={{color: t >= w.start ? (t < w.end + 0.15 ? C.tide : C.paper) : '#ffffff55', marginRight: '0.25em'}}>{w.w}</span>
			))}
		</div>
	);
};

const EndCard: React.FC = () => {
	const f = useCurrentFrame();
	const v = useV();
	const n = Math.round(interpolate(f, [0, 38], [262, 300], clamp));
	return (
		<AbsoluteFill style={{background: `radial-gradient(ellipse at 50% 35%, #14303a 0%, ${C.ink} 60%)`}}>
			<Img src={staticFile(`askdraws/mate/mate-${String(n).padStart(4, '0')}.png`)} style={{position: 'absolute', width: v ? 460 : 400, left: '50%', top: v ? 420 : 70, transform: 'translateX(-50%)'}} />
			<div style={{position: 'absolute', left: 0, right: 0, top: v ? 900 : 480, textAlign: 'center', opacity: ease(f, 4), transform: `translateY(${(1 - ease(f, 4)) * 30}px)`}}>
				<div style={{fontSize: v ? 56 : 52, fontWeight: 600, color: '#c9d0db', letterSpacing: -1}}>Ask about anything on your screen.</div>
				<div style={{fontSize: 150, fontWeight: 800, letterSpacing: -7, marginTop: 14}}>HeyMate.</div>
				<div style={{marginTop: 30, display: 'inline-block', padding: '18px 32px', borderRadius: 40, fontSize: 30, fontWeight: 600, color: C.ink, background: C.paper, opacity: ease(f, 30)}}>Free for Mac · getheymate.vercel.app</div>
			</div>
		</AbsoluteFill>
	);
};

export const SCENES: [React.ReactNode, number, number][] = [
	[<Shot clip="story1.mp4" rate={0.95} />, 0, at(wordAt('So'))],
	[<Shot clip="story2.mp4" focusX={22} />, at(wordAt('So')), at(wordAt('How'))],
	[<Capture clip="biryani.mp4" startFrom={9} rate={3.5} roi={{x: 690, y: 0, w: 560, h: 170}} label="Real HeyMate capture · sped up 3.5×" />, at(wordAt('How')), at(wordAt('And'))],
	[<Capture clip="biryani.mp4" startFrom={25} rate={3.2} roi={{x: 560, y: 340, w: 830, h: 650}} label="Real HeyMate capture · sped up 3.2×" />, at(wordAt('And')), at(wordAt('Marinate'))],
	[<><Shot clip="story3.mp4" startFrom={1} /><Steps /></>, at(wordAt('Marinate')), at(wordAt('Honestly'))],
	[<Shot clip="story4.jpg" focusX={30} />, at(wordAt('Honestly')), at(wordAt('Ask'))],
	[<EndCard />, at(wordAt('Ask')), TOTAL],
];

export const BiryaniStory: React.FC = () => {
	const f = useCurrentFrame();
	return (
		<AbsoluteFill style={{fontFamily: font, background: C.ink, color: C.paper}}>
			<style>{`@font-face{font-family:Figtree;src:url('${staticFile('launch/Figtree.woff2')}') format('woff2');font-weight:300 900}*{box-sizing:border-box}`}</style>
			<Audio src={staticFile('launch/score.wav')} volume={(fr) => interpolate(fr, [0, 20, TOTAL - 40, TOTAL], [0, 0.18, 0.18, 0], clamp)} />
			<Sequence from={VO_AT}><Audio src={src('vo.mp3')} /></Sequence>
			{SCENES.map(([node, from, to], i) => (
				<Sequence key={i} from={from} durationInFrames={to - from}>{node}</Sequence>
			))}
			{f < at(wordAt('Ask')) && <Captions />}
		</AbsoluteFill>
	);
};
