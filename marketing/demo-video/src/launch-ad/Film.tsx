import React from 'react';
import {AbsoluteFill, Audio, Img, OffthreadVideo, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';

// HeyMate launch ad — bright, airy four-beat structure (intro → problem → logo → use cases → CTA),
// kinetic type over matte cream. Real HeyMate captures are composited into AI-generated (Google Flow)
// room photos; both are labelled on screen.
export const FPS = 30;
export const TOTAL = 1260;

const C = {cream: '#F5F4EF', ink: '#0E1116', mute: '#6B7280', tide: '#7FBDB3', blue: '#7FA8E6', line: '#0E111614'};
const font = 'Figtree, "Avenir Next", sans-serif';
const ad = (n: string) => staticFile(`launch-ad/${n}`);
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const ease = (f: number, start: number, dur = 18) => {
	const x = Math.max(0, Math.min(1, (f - start) / dur));
	return 1 - Math.pow(1 - x, 4);
};
const useV = () => {
	const {width, height} = useVideoConfig();
	return height > width;
};

// Airy cream backdrop with slow drifting tide/blue light.
const Air: React.FC<{dim?: number}> = ({dim = 1}) => {
	const f = useCurrentFrame();
	return (
		<AbsoluteFill style={{background: C.cream, overflow: 'hidden'}}>
			<div style={{position: 'absolute', width: 1300, height: 1300, borderRadius: '50%', left: -300 + Math.sin(f / 80) * 60, bottom: -760, background: `radial-gradient(circle, ${C.tide}66, transparent 65%)`, opacity: dim}} />
			<div style={{position: 'absolute', width: 1200, height: 1200, borderRadius: '50%', right: -360 + Math.cos(f / 90) * 60, bottom: -700, background: `radial-gradient(circle, ${C.blue}55, transparent 65%)`, opacity: dim}} />
			<div style={{position: 'absolute', width: 900, height: 900, borderRadius: '50%', left: '35%', bottom: -620, background: 'radial-gradient(circle, #ffd9b866, transparent 65%)', opacity: dim}} />
		</AbsoluteFill>
	);
};

const Mark: React.FC<{size: number; color?: string; draw?: number}> = ({size, color = C.ink, draw = 1}) => (
	<svg width={size} height={size} viewBox="0 0 128 128" fill="none">
		<g stroke={color} strokeWidth="9" strokeLinecap="round" strokeLinejoin="round" style={{strokeDasharray: 120, strokeDashoffset: 120 * (1 - draw)}}>
			<path d="M18 40 L42 24 L56 41" />
			<path d="M86 48 L114 53" />
			<path d="M70 58 L65 72 L74 75" />
			<path d="M65 99 C78 99 94 97 102 88" />
		</g>
	</svg>
);

// Small inline glyph chips that pop between words.
const Glyph: React.FC<{kind: 'chart' | 'code' | 'pan' | 'cube'; at: number}> = ({kind, at}) => {
	const f = useCurrentFrame();
	const p = spring({frame: f - at, fps: FPS, config: {damping: 13, stiffness: 180}});
	const paths = {
		chart: <path d="M10 34 V22 M20 34 V12 M30 34 V18" />,
		code: <path d="M15 14 L7 22 L15 30 M29 14 L37 22 L29 30" />,
		pan: <><circle cx="20" cy="22" r="10" /><path d="M30 22 H40" /></>,
		cube: <path d="M22 8 L36 15 V30 L22 37 L8 30 V15 Z M8 15 L22 22 L36 15 M22 22 V37" />,
	}[kind];
	return (
		<span style={{display: 'inline-grid', placeItems: 'center', width: '1.05em', height: '1.05em', borderRadius: '0.28em', background: '#fff', boxShadow: '0 10px 24px #0e111618, inset 0 0 0 1px #0e111612', margin: '0 0.18em', verticalAlign: '-0.12em', transform: `scale(${p}) rotate(${(1 - p) * -20}deg)`}}>
			<svg width="62%" height="62%" viewBox="0 0 44 44" fill="none" stroke={C.ink} strokeWidth="3.4" strokeLinecap="round" strokeLinejoin="round">{paths}</svg>
		</span>
	);
};

const Words: React.FC<{items: (string | React.ReactNode)[]; start: number; size: number; color?: string; stagger?: number; weight?: number; style?: React.CSSProperties}> = ({items, start, size, color = C.ink, stagger = 4, weight = 600, style}) => {
	const f = useCurrentFrame();
	return (
		<div style={{fontSize: size, fontWeight: weight, letterSpacing: -size * 0.035, lineHeight: 1.12, color, ...style}}>
			{items.map((w, i) => {
				if (typeof w !== 'string') return <React.Fragment key={i}>{w}</React.Fragment>;
				const p = ease(f, start + i * stagger, 16);
				return <span key={i} style={{display: 'inline-block', opacity: p, filter: `blur(${(1 - p) * 10}px)`, transform: `translateY(${(1 - p) * 0.3}em)`, marginRight: '0.22em'}}>{w}</span>;
			})}
		</div>
	);
};

const Tag: React.FC<{children: React.ReactNode; dark?: boolean}> = ({children, dark}) => (
	<div style={{position: 'absolute', right: 32, bottom: 28, fontSize: 16, color: dark ? '#e6e9ee' : '#4b5563', padding: '7px 12px', borderRadius: 8, background: dark ? '#0e1116aa' : '#ffffffcc', border: '1px solid #0e111612', zIndex: 60}}>{children}</div>
);

// ---------- beats
const Intro: React.FC = () => {
	const v = useV();
	return (
		<AbsoluteFill>
			<Air />
			<AbsoluteFill style={{display: 'grid', placeItems: 'center', textAlign: 'center', padding: v ? 70 : 160}}>
				<div>
					<Words items={['Every', 'day,']} start={4} size={v ? 84 : 104} />
					<Words items={["there's", <Glyph key="a" kind="chart" at={28} />, 'something', <Glyph key="b" kind="code" at={44} />, 'new']} start={22} size={v ? 84 : 104} />
					<Words items={['on', 'your', 'screen.', <Glyph key="c" kind="cube" at={84} />]} start={62} size={v ? 84 : 104} color={C.mute} />
				</div>
			</AbsoluteFill>
		</AbsoluteFill>
	);
};

const COLLAGE = ['c-m1.jpg', 'c-vector.jpg', 'c-story4.jpg', 'c-pi3d.jpg', 'c-m3.jpg', 'c-biryani.jpg', 'c-story3.jpg', 'c-pi2d.jpg', 'c-m4.jpg'];
const Problem: React.FC = () => {
	const f = useCurrentFrame();
	const {width, height} = useVideoConfig();
	const v = height > width;
	const second = f >= 105;
	return (
		<AbsoluteFill>
			<Air dim={0.7} />
			{COLLAGE.map((img, i) => {
				const a = (i / COLLAGE.length) * Math.PI * 2 + f / 90;
				const rx = v ? 420 : 760;
				const ry = v ? 700 : 330;
				const z = Math.sin(a);
				const p = ease(f, i * 3, 22);
				const w = (v ? 300 : 300) * (0.78 + 0.22 * (z + 1) / 2);
				return (
					<Img key={img} src={ad(img)} style={{position: 'absolute', left: width / 2 + Math.cos(a) * rx * p - w / 2, top: height / 2 + z * ry * p - w * 0.35, width: w, height: w * 0.7, objectFit: 'cover', borderRadius: 18, boxShadow: '0 24px 60px #0e111626', zIndex: Math.round(z * 10) + 10, opacity: p * (0.55 + 0.45 * (z + 1) / 2), filter: `blur(${(1 - (z + 1) / 2) * 2.5}px)`, transform: `rotate(${Math.cos(a) * 6}deg)`}} />
				);
			})}
			<AbsoluteFill style={{display: 'grid', placeItems: 'center', textAlign: 'center', zIndex: 15, padding: 80}}>
				<div style={{background: '#f5f4efd9', borderRadius: 30, padding: '26px 40px', backdropFilter: 'blur(6px)'}}>
					{!second ? (
						<Words key="a" items={["You", "don't", 'want', 'a', '20-minute', 'tutorial.']} start={6} size={v ? 70 : 74} />
					) : (
						<Words key="b" items={['You', 'want', 'the', 'answer.']} start={105} size={v ? 92 : 98} />
					)}
				</div>
			</AbsoluteFill>
			<Tag>Includes AI-generated scenes</Tag>
		</AbsoluteFill>
	);
};

const Logo: React.FC = () => {
	const f = useCurrentFrame();
	const v = useV();
	const ring = ease(f, 0, 30);
	const slide = ease(f, 34, 22);
	return (
		<AbsoluteFill>
			<Air />
			<AbsoluteFill style={{display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 34 * slide}}>
				<div style={{position: 'relative', width: 190, height: 190, transform: `scale(${0.8 + 0.2 * ring})`}}>
					<svg width="190" height="190" style={{position: 'absolute'}}>
						<circle cx="95" cy="95" r="86" fill="none" stroke={C.tide} strokeWidth="10" strokeLinecap="round" strokeDasharray={540} strokeDashoffset={540 * (1 - ring)} transform="rotate(-90 95 95)" opacity={1 - slide * 0.9} />
					</svg>
					<div style={{position: 'absolute', inset: 30, display: 'grid', placeItems: 'center'}}><Mark size={130} draw={ease(f, 16, 26)} /></div>
				</div>
				<div style={{overflow: 'hidden', width: (v ? 470 : 560) * slide, whiteSpace: 'nowrap'}}>
					<div style={{fontSize: v ? 120 : 140, fontWeight: 700, letterSpacing: -6, color: C.ink, transform: `translateX(${(1 - slide) * -80}px)`}}>HeyMate</div>
				</div>
			</AbsoluteFill>
		</AbsoluteFill>
	);
};

// Homography: map a W×H element onto quad [tl,tr,br,bl] (CSS matrix3d).
function quadMatrix(W: number, H: number, q: number[][]) {
	const [[x0, y0], [x1, y1], [x2, y2], [x3, y3]] = q;
	const dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2;
	const sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3;
	const den = dx1 * dy2 - dx2 * dy1;
	const g = (sx * dy2 - dx2 * sy) / den, h = (dx1 * sy - sx * dy1) / den;
	const a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, c = x0;
	const d = y1 - y0 + g * y1, e = y3 - y0 + h * y3, ff = y0;
	// unit square → quad, then scale element W×H into unit square
	const m = [a / W, d / W, 0, g / W, b / H, e / H, 0, h / H, 0, 0, 1, 0, c, ff, 0, 1];
	return `matrix3d(${m.join(',')})`;
}

type Roi = {x: number; y: number; w: number; h: number};
const ScreenClip: React.FC<{clip: string; size: [number, number]; roi: Roi; startFrom: number; rate: number; W: number; H: number}> = ({clip, size, roi, startFrom, rate, W, H}) => {
	const s = Math.max(W / roi.w, H / roi.h);
	return (
		<div style={{position: 'absolute', width: W, height: H, overflow: 'hidden', background: '#eef1f4'}}>
			<OffthreadVideo src={staticFile(clip)} startFrom={Math.round(startFrom * FPS)} playbackRate={rate} muted style={{position: 'absolute', width: size[0] * s, height: size[1] * s, left: W / 2 - (roi.x + roi.w / 2) * s, top: H / 2 - (roi.y + roi.h / 2) * s, maxWidth: 'none'}} />
		</div>
	);
};

// Room photo (2752×1536) with a capture composited onto its screen quad.
const Room: React.FC<{photo: string; quad: number[][]; clip: React.ComponentProps<typeof ScreenClip>; caption: string; label: string; focus: [number, number]}> = ({photo, quad, clip, caption, label, focus}) => {
	const f = useCurrentFrame();
	const {width, height} = useVideoConfig();
	const v = height > width;
	const PW = 2752, PH = 1536;
	const base = Math.max(width / PW, height / PH);
	const zoom = (v ? 0.8 : base) * (1.02 + ease(f, 0, 150) * 0.06);
	const fit = (o: number, view: number, size: number) => (v ? o : Math.min(0, Math.max(view - size * zoom, o)));
	const ox = fit(width / 2 - focus[0] * zoom, width, PW), oy = fit(height / 2 - focus[1] * zoom, height, PH);
	const capP = ease(f, 0, 16);
	return (
		<AbsoluteFill style={{background: C.cream, overflow: 'hidden'}}>
			{v && <Img src={ad(photo)} style={{position: 'absolute', width: '100%', height: '100%', objectFit: 'cover', filter: 'blur(36px) brightness(1.05)', transform: 'scale(1.15)'}} />}
			<div style={{position: 'absolute', left: ox, top: oy, width: PW, height: PH, transform: `scale(${zoom})`, transformOrigin: '0 0'}}>
				<Img src={ad(photo)} style={{position: 'absolute', width: PW, height: PH}} />
				<div style={{position: 'absolute', left: 0, top: 0, transformOrigin: '0 0', transform: quadMatrix(clip.W, clip.H, quad), opacity: capP}}>
					<ScreenClip {...clip} />
				</div>
			</div>
			<div style={{position: 'absolute', left: 0, right: 0, bottom: v ? 260 : 64, display: 'flex', justifyContent: 'center'}}>
				<div style={{padding: '18px 30px', borderRadius: 999, background: '#ffffffe6', boxShadow: '0 18px 50px #0e111622', fontSize: v ? 44 : 40, fontWeight: 600, letterSpacing: -1, color: C.ink, opacity: ease(f, 8), transform: `translateY(${(1 - ease(f, 8)) * 24}px)`}}>{caption}</div>
			</div>
			<Tag>{label}</Tag>
		</AbsoluteFill>
	);
};

const STRAIGHT = [[885, 437], [1867, 437], [1867, 1008], [885, 1008]];
const ANGLED = [[2050, 395], [2732, 298], [2677, 1385], [2007, 1165]];

const Voice: React.FC = () => {
	const f = useCurrentFrame();
	const v = useV();
	return (
		<AbsoluteFill>
			<Air />
			<AbsoluteFill style={{display: 'grid', placeItems: 'center', textAlign: 'center'}}>
				<div>
					<div style={{display: 'flex', gap: 26, justifyContent: 'center', marginBottom: 50}}>
						{['⌃', '⌥'].map((k, i) => {
							const p = spring({frame: f - i * 5, fps: FPS, config: {damping: 14, stiffness: 150}});
							const down = f > 30 && f < 90;
							return <div key={k} style={{width: 150, height: 150, borderRadius: 30, display: 'grid', placeItems: 'center', fontSize: 70, color: C.ink, background: '#fff', boxShadow: `0 ${down ? 4 : 12}px 0 #d9dbd6, 0 24px 50px #0e111620`, transform: `translateY(${(down ? 8 : 0) + (1 - p) * 80}px)`, opacity: p}}>{k}</div>;
						})}
					</div>
					<div style={{display: 'flex', gap: 7, justifyContent: 'center', height: 70, alignItems: 'center', marginBottom: 40}}>
						{Array.from({length: 30}, (_, i) => <div key={i} style={{width: 7, borderRadius: 4, background: C.tide, height: 8 + Math.abs(Math.sin(f * 0.3 + i * 0.7)) * 56 * Math.sin(((i + 1) / 31) * Math.PI) * ease(f, 30, 10)}} />)}
					</div>
					<Words items={['Just', 'hold', 'two', 'keys', 'and', 'ask', 'out', 'loud.']} start={20} size={v ? 72 : 80} />
				</div>
			</AbsoluteFill>
		</AbsoluteFill>
	);
};

const Cta: React.FC = () => {
	const f = useCurrentFrame();
	const v = useV();
	const sky = ease(f, 70, 30);
	return (
		<AbsoluteFill>
			<Air />
			{f < 80 && (
				<AbsoluteFill style={{display: 'grid', placeItems: 'center', textAlign: 'center', padding: 80, opacity: 1 - ease(f, 66, 12)}}>
					<div>
						<Words items={['Whatever', "you're", 'doing,']} start={2} size={v ? 92 : 100} />
						<Words items={['just', 'ask.']} start={22} size={v ? 92 : 100} color={C.tide} weight={700} />
					</div>
				</AbsoluteFill>
			)}
			<AbsoluteFill style={{opacity: sky}}>
				<Img src={ad('clouds.jpg')} style={{width: '100%', height: '100%', objectFit: 'cover', transform: `scale(${1.08 - ease(f, 70, 110) * 0.06})`}} />
				<AbsoluteFill style={{background: 'radial-gradient(ellipse at 50% 50%, #ffffff55, transparent 60%)'}} />
				<AbsoluteFill style={{display: 'grid', placeItems: 'center', textAlign: 'center'}}>
					<div style={{transform: `translateY(${(1 - ease(f, 84, 24)) * 30}px)`, opacity: ease(f, 84, 24)}}>
						<div style={{display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 22}}>
							<Mark size={v ? 110 : 120} draw={ease(f, 84, 30)} />
							<div style={{fontSize: v ? 120 : 132, fontWeight: 700, letterSpacing: -6, color: C.ink}}>HeyMate</div>
						</div>
						<div style={{fontSize: v ? 38 : 36, color: '#3c4350', marginTop: 18, fontWeight: 500}}>Ask about anything on your screen.</div>
						<div style={{marginTop: 34, display: 'inline-block', padding: '18px 32px', borderRadius: 999, background: C.ink, color: C.cream, fontSize: 30, fontWeight: 600, opacity: ease(f, 110, 18)}}>Free & open source · getheymate.vercel.app</div>
					</div>
				</AbsoluteFill>
			</AbsoluteFill>
		</AbsoluteFill>
	);
};

const CHAPTERS = ['Intro', 'Problem', 'Use case', 'Get it'];
const Chapters: React.FC = () => {
	const f = useCurrentFrame();
	const v = useV();
	const active = f < 150 ? 0 : f < 360 ? 1 : f < 1080 ? 2 : 3;
	return (
		<div style={{position: 'absolute', top: v ? 70 : 34, left: 0, right: 0, display: 'flex', justifyContent: 'center', gap: 8, zIndex: 70, opacity: f > 1230 ? 0 : 1}}>
			{CHAPTERS.map((c, i) => (
				<div key={c} style={{fontSize: 17, fontWeight: 600, padding: '9px 16px', borderRadius: 999, color: i === active ? C.cream : '#4b5563', background: i === active ? C.ink : '#ffffffb3', border: '1px solid #0e111612'}}>{c}</div>
			))}
		</div>
	);
};

export const LaunchAd: React.FC = () => {
	const f = useCurrentFrame();
	const scenes: [React.ReactNode, number, number][] = [
		[<Intro />, 0, 150],
		[<Problem />, 150, 360],
		[<Logo />, 360, 480],
		[<Room photo="monitor.jpg" quad={STRAIGHT} focus={[1376, 760]} caption="Cram a concept before the meeting." label="Real HeyMate capture, composited · AI-generated room" clip={{clip: 'meeting-story/vector.mp4', size: [1600, 1264], roi: {x: 0, y: 40, w: 1600, h: 930}, startFrom: 6, rate: 2.6, W: 982, H: 571}} />, 480, 600],
		[<Room photo="priya-monitor.jpg" quad={ANGLED} focus={[1900, 820]} caption="Turn a recipe into a plan." label="Real HeyMate capture, composited · AI-generated scene" clip={{clip: 'askdraws/biryani.mp4', size: [1920, 1260], roi: {x: 600, y: 380, w: 760, h: 590}, startFrom: 30, rate: 3, W: 982, H: 571}} />, 600, 720],
		[<Room photo="monitor.jpg" quad={STRAIGHT} focus={[1376, 720]} caption="See it in 3D." label="Real HeyMate capture, composited · AI-generated room" clip={{clip: 'askdraws/pi3d.mp4', size: [1920, 1260], roi: {x: 520, y: 380, w: 940, h: 547}, startFrom: 8, rate: 2, W: 982, H: 571}} />, 720, 840],
		[<Room photo="monitor.jpg" quad={STRAIGHT} focus={[1376, 700]} caption="Find the exact button." label="Real HeyMate capture, composited · AI-generated room" clip={{clip: 'launch/keynote-effect.mp4', size: [2560, 1440], roi: {x: 1300, y: 0, w: 1260, h: 733}, startFrom: 0, rate: 0.85, W: 982, H: 571}} />, 840, 960],
		[<Voice />, 960, 1080],
		[<Cta />, 1080, TOTAL],
	];
	return (
		<AbsoluteFill style={{fontFamily: font, background: C.cream}}>
			<style>{`@font-face{font-family:Figtree;src:url('${staticFile('launch/Figtree.woff2')}') format('woff2');font-weight:300 900}*{box-sizing:border-box}`}</style>
			<Audio src={staticFile('launch/score.wav')} volume={(fr) => interpolate(fr, [0, 15, TOTAL - 40, TOTAL], [0, 0.5, 0.5, 0], clamp)} />
			{scenes.map(([node, from, to], i) => (
				<Sequence key={i} from={from} durationInFrames={to - from}>{node}</Sequence>
			))}
			{/* soft white flash between beats */}
			{scenes.slice(1).map(([, from], i) => (
				<AbsoluteFill key={i} style={{background: '#fff', pointerEvents: 'none', opacity: interpolate(f, [from - 3, from, from + 8], [0, 0.65, 0], clamp)}} />
			))}
			<Chapters />
		</AbsoluteFill>
	);
};
