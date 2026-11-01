import React from 'react';
import {AbsoluteFill, Audio, Img, OffthreadVideo, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {VO_WORDS} from './voWords';

// "Ask. It draws." — 30 s premium film. Real HeyMate captures (sped up, labelled),
// the Tide mate rendered in Blender, ElevenLabs VO, original synthesized score.
export const FPS = 30;
export const TOTAL = 900;
const VO_AT = 12; // frames of air before the first word

const C = {ink: '#06080c', paper: '#F3F4F1', mute: '#8a93a3', blue: '#A8CBFA', tide: '#9FD0C8'};
const font = 'Figtree, "Avenir Next", sans-serif';
const src = (n: string) => staticFile(`askdraws/${n}`);
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const ease = (f: number, start: number, dur = 24) => {
	const x = Math.max(0, Math.min(1, (f - start) / dur));
	return 1 - Math.pow(1 - x, 4);
};
const at = (seconds: number) => Math.round(seconds * FPS) + VO_AT;
const useV = () => {
	const {width, height} = useVideoConfig();
	return height > width;
};

const Backdrop: React.FC<{glow?: string}> = ({glow = '#16243a'}) => {
	const f = useCurrentFrame();
	return (
		<AbsoluteFill style={{background: C.ink, overflow: 'hidden'}}>
			<div style={{position: 'absolute', inset: '-30%', background: `radial-gradient(ellipse at ${50 + Math.sin(f / 90) * 4}% 38%, ${glow}cc 0%, transparent 55%)`}} />
			<div style={{position: 'absolute', inset: 0, background: 'radial-gradient(ellipse at 50% 50%, transparent 55%, #000a 100%)'}} />
			<Grain />
		</AbsoluteFill>
	);
};

const Grain: React.FC = () => {
	const f = useCurrentFrame();
	return (
		<svg style={{position: 'absolute', inset: 0, width: '100%', height: '100%', opacity: 0.07, mixBlendMode: 'overlay'}}>
			<filter id="g"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed={f % 12} /></filter>
			<rect width="100%" height="100%" filter="url(#g)" />
		</svg>
	);
};

// Words reveal in time with the VO, softly, one by one.
const Line: React.FC<{text: string; start: number; size?: number; color?: string; weight?: number; stagger?: number; style?: React.CSSProperties}> = ({text, start, size = 96, color = C.paper, weight = 700, stagger = 3, style}) => {
	const f = useCurrentFrame();
	return (
		<div style={{fontSize: size, fontWeight: weight, letterSpacing: -size * 0.035, lineHeight: 1.04, color, ...style}}>
			{text.split(' ').map((w, i) => {
				const p = ease(f, start + i * stagger, 18);
				return (
					<span key={i} style={{display: 'inline-block', opacity: p, transform: `translateY(${(1 - p) * 0.35}em)`, filter: `blur(${(1 - p) * 8}px)`, marginRight: '0.24em'}}>
						{w}
					</span>
				);
			})}
		</div>
	);
};

// Tide mate: Blender PNG sequence, frames 1..300.
const Mate: React.FC<{from: number; to: number; size: number; x: number; y: number; delay?: number}> = ({from, to, size, x, y, delay = 0}) => {
	const f = useCurrentFrame();
	const n = Math.round(interpolate(f - delay, [0, to - from], [from, to], clamp));
	return <Img src={src(`mate/mate-${String(n).padStart(4, '0')}.png`)} style={{position: 'absolute', left: x - size / 2, top: y - size / 2, width: size, height: size, opacity: f < delay ? 0 : 1}} />;
};

const Tag: React.FC<{children: React.ReactNode}> = ({children}) => (
	<div style={{position: 'absolute', right: 44, bottom: 36, fontSize: 18, letterSpacing: 0.4, color: '#9aa3b2', padding: '8px 13px', borderRadius: 8, background: '#06080ccc', border: '1px solid #ffffff12', zIndex: 50}}>{children}</div>
);

// A recording framed like a floating window, cropped to a region of interest.
type Roi = {x: number; y: number; w: number; h: number};
const Footage: React.FC<{clip: string; startFrom: number; rate: number; roi: Roi; panel: {x: number; y: number; w: number; h: number}; push?: number}> = ({clip, startFrom, rate, roi, panel, push = 0.04}) => {
	const f = useCurrentFrame();
	const p = ease(f, 0, 22);
	const s = (Math.min(panel.w / roi.w, panel.h / roi.h)) * (1 + ease(f, 0, 200) * push);
	const cx = roi.x + roi.w / 2;
	const cy = roi.y + roi.h / 2;
	return (
		<div style={{position: 'absolute', left: panel.x, top: panel.y, width: panel.w, height: panel.h, borderRadius: 28, overflow: 'hidden', boxShadow: '0 50px 120px #000c, 0 0 0 1px #ffffff1c', opacity: p, transform: `translateY(${(1 - p) * 40}px) scale(${0.97 + 0.03 * p})`}}>
			<OffthreadVideo src={src(clip)} startFrom={Math.round(startFrom * FPS)} playbackRate={rate} muted style={{position: 'absolute', width: 1920 * s, height: 1260 * s, left: panel.w / 2 - cx * s, top: panel.h / 2 - cy * s, maxWidth: 'none'}} />
		</div>
	);
};

const usePanel = () => {
	const v = useV();
	return v ? {x: 50, y: 640, w: 980, h: 780} : {x: 800, y: 160, w: 1020, h: 760};
};
const useTextBox = (): React.CSSProperties => (useV() ? {position: 'absolute', left: 70, right: 70, top: 250} : {position: 'absolute', left: 110, top: 380, width: 640, zoom: 0.82});

// ---------- scenes
const Opener: React.FC = () => {
	const f = useCurrentFrame();
	const v = useV();
	return (
		<AbsoluteFill>
			<Backdrop />
			<OffthreadVideo src={src('opener.mp4')} muted style={{position: 'absolute', width: '100%', height: '100%', objectFit: 'cover', opacity: 0.85 * ease(f, 0, 30), transform: `scale(${1.04 + f / 2400})`}} />
			<AbsoluteFill style={{background: 'linear-gradient(180deg,#06080c55,#06080c00 40%,#06080cdd)'}} />
			<div style={{position: 'absolute', left: 0, right: 0, bottom: v ? 520 : 150, textAlign: 'center'}}>
				<Line text="You've got a question." start={VO_AT} size={v ? 92 : 104} />
				<Line text="About what's on your screen." start={at(1.56)} size={v ? 52 : 46} weight={500} color="#c9d0db" style={{marginTop: 22, letterSpacing: -0.5}} />
			</div>
			<Grain />
		</AbsoluteFill>
	);
};

const Keys: React.FC = () => {
	const f = useCurrentFrame();
	const v = useV();
	const press = f > 12 && f < 70;
	return (
		<AbsoluteFill>
			<Backdrop glow="#14303a" />
			<div style={{position: 'absolute', left: 0, right: 0, top: v ? 360 : 170, textAlign: 'center'}}>
				<Line text="Hold Control and Option." start={2} size={v ? 78 : 84} />
				<Line text="Just ask." start={at(5.31) - at(3.3) + 4} size={v ? 78 : 84} color={C.tide} />
			</div>
			<div style={{position: 'absolute', left: v ? 345 : 520, top: v ? 820 : 470, display: 'flex', gap: 30, perspective: 900}}>
				{['⌃', '⌥'].map((k, i) => {
					const p = spring({frame: f - i * 4, fps: FPS, config: {damping: 16, stiffness: 140}});
					return (
						<div key={k} style={{width: 180, height: 180, borderRadius: 34, display: 'grid', placeItems: 'center', fontFamily: '"SF Pro Display","Avenir Next",sans-serif', fontSize: 86, color: '#dfe7f2', background: 'linear-gradient(160deg,#20262f,#0d1015)', border: '1px solid #ffffff1f', boxShadow: `0 ${press ? 6 : 14}px 0 #050608, 0 30px 60px #000a, inset 0 1px 0 #ffffff26`, transform: `rotateX(18deg) translateY(${(press ? 8 : 0) + (1 - p) * 120}px)`, opacity: p}}>
							{k}
						</div>
					);
				})}
			</div>
			<Mate from={1} to={100} size={v ? 620 : 640} x={v ? 540 : 1320} y={v ? 1400 : 560} delay={6} />
		</AbsoluteFill>
	);
};

const Wall: React.FC = () => {
	const f = useCurrentFrame();
	const v = useV();
	const fade = interpolate(f, [30, 62], [1, 0], clamp);
	return (
		<AbsoluteFill>
			<Backdrop />
			<div style={{position: 'absolute', left: v ? 70 : 140, top: v ? 640 : 170, width: v ? 940 : 980, opacity: fade, filter: `blur(${(1 - fade) * 10}px)`}}>
				{Array.from({length: 14}, (_, i) => (
					<div key={i} style={{height: 18, borderRadius: 9, margin: '22px 0', width: `${68 + ((i * 37) % 30)}%`, background: '#ffffff14', opacity: ease(f, i, 10)}} />
				))}
			</div>
			<div style={{position: 'absolute', left: v ? 70 : 140, right: v ? 70 : undefined, top: v ? 300 : 790}}>
				<Line text="Not a wall of text." start={4} size={v ? 92 : 96} />
			</div>
			<Mate from={120} to={200} size={v ? 560 : 640} x={v ? 760 : 1460} y={v ? 1500 : 560} />
		</AbsoluteFill>
	);
};

const Draws: React.FC = () => {
	const panel = usePanel();
	const box = useTextBox();
	const base = at(9.24);
	return (
		<AbsoluteFill>
			<Backdrop glow="#1d2a20" />
			<div style={box}>
				<Line text="It draws the answer." start={0} size={88} />
				<Line text="Step by step." start={at(11.37) - base} size={88} color={C.tide} />
				<Line text="Right where you're looking." start={at(13.22) - base} size={40} weight={500} color="#c9d0db" style={{marginTop: 26, letterSpacing: -0.4}} />
			</div>
			<Footage clip="biryani.mp4" startFrom={25} rate={4.4} roi={{x: 560, y: 340, w: 830, h: 650}} panel={panel} />
			<Tag>Real HeyMate capture · sped up 4.4×</Tag>
		</AbsoluteFill>
	);
};

const Recipe: React.FC = () => {
	const panel = usePanel();
	const box = useTextBox();
	return (
		<AbsoluteFill>
			<Backdrop glow="#1d2a20" />
			<div style={box}>
				<Line text="A recipe" start={0} size={96} />
				<Line text="becomes a plan." start={6} size={96} color={C.tide} />
			</div>
			<Footage clip="biryani.mp4" startFrom={56} rate={1} roi={{x: 600, y: 380, w: 760, h: 590}} panel={panel} push={0.08} />
			<Tag>Real HeyMate capture</Tag>
		</AbsoluteFill>
	);
};

const MapScene: React.FC = () => {
	const panel = usePanel();
	const box = useTextBox();
	return (
		<AbsoluteFill>
			<Backdrop glow="#182638" />
			<div style={box}>
				<Line text="A circuit board" start={0} size={96} />
				<Line text="becomes a map." start={6} size={96} color={C.blue} />
			</div>
			<Footage clip="pi2d.mp4" startFrom={40} rate={4.2} roi={{x: 560, y: 340, w: 830, h: 650}} panel={panel} />
			<Tag>Real HeyMate capture · sped up 4.2×</Tag>
		</AbsoluteFill>
	);
};

const ThreeD: React.FC = () => {
	const panel = usePanel();
	const box = useTextBox();
	const base = at(19.59);
	return (
		<AbsoluteFill>
			<Backdrop glow="#182638" />
			<div style={box}>
				<Line text="And when flat isn't enough…" start={0} size={56} weight={600} color="#c9d0db" />
				<Line text="it goes 3D." start={at(21.59) - base} size={120} color={C.blue} style={{marginTop: 18}} />
			</div>
			<Footage clip="pi3d.mp4" startFrom={6} rate={2.4} roi={{x: 560, y: 400, w: 860, h: 620}} panel={panel} push={0.06} />
			<Tag>Real HeyMate capture · sped up 2.4×</Tag>
		</AbsoluteFill>
	);
};

const Anything: React.FC = () => {
	const v = useV();
	return (
		<AbsoluteFill>
			<Backdrop glow="#14303a" />
			<Mate from={206} to={262} size={v ? 820 : 760} x={v ? 540 : 960} y={v ? 1180 : 610} />
			<div style={{position: 'absolute', left: 0, right: 0, top: v ? 330 : 120, textAlign: 'center'}}>
				<Line text="Ask about anything" start={2} size={v ? 96 : 104} />
				<Line text="on your screen." start={8} size={v ? 96 : 104} color={C.tide} />
			</div>
		</AbsoluteFill>
	);
};

const EndCard: React.FC = () => {
	const f = useCurrentFrame();
	const v = useV();
	const base = at(25.25);
	return (
		<AbsoluteFill>
			<Backdrop glow="#14303a" />
			<Mate from={262} to={300} size={v ? 440 : 400} x={v ? 540 : 960} y={v ? 640 : 300} />
			<div style={{position: 'absolute', left: 0, right: 0, top: v ? 900 : 530, textAlign: 'center'}}>
				<Line text="HeyMate." start={0} size={v ? 150 : 150} style={{letterSpacing: -7}} />
				<Line text="Free and open source. For your Mac." start={at(26.32) - base} size={v ? 42 : 40} weight={500} color="#c9d0db" stagger={2} style={{marginTop: 26, letterSpacing: -0.3}} />
				<div style={{marginTop: 46, display: 'inline-block', padding: '20px 34px', borderRadius: 40, fontSize: 30, fontWeight: 600, color: C.ink, background: C.paper, opacity: ease(f, 50, 20), transform: `translateY(${(1 - ease(f, 50, 20)) * 20}px)`}}>getheymate.vercel.app</div>
			</div>
		</AbsoluteFill>
	);
};

export const SCENES: [React.FC, number, number][] = [
	[Opener, 0, at(3.3)],
	[Keys, at(3.3), at(6.63)],
	[Wall, at(6.63), at(9.24)],
	[Draws, at(9.24), at(14.86)],
	[Recipe, at(14.86), at(17.07)],
	[MapScene, at(17.07), at(19.59)],
	[ThreeD, at(19.59), at(23.15)],
	[Anything, at(23.15), at(25.25)],
	[EndCard, at(25.25), TOTAL],
];

export const AskDraws: React.FC = () => {
	const f = useCurrentFrame();
	const musicVol = (fr: number) => interpolate(fr, [0, 20, TOTAL - 45, TOTAL], [0, 0.32, 0.32, 0], clamp);
	return (
		<AbsoluteFill style={{fontFamily: font, background: C.ink, color: C.paper}}>
			<style>{`@font-face{font-family:Figtree;src:url('${staticFile('launch/Figtree.woff2')}') format('woff2');font-weight:300 900}*{box-sizing:border-box}`}</style>
			<Audio src={staticFile('launch/score.wav')} volume={musicVol} />
			<Sequence from={VO_AT}><Audio src={src('vo.mp3')} /></Sequence>
			{SCENES.map(([Scene, from, to], i) => (
				<Sequence key={i} from={from} durationInFrames={to - from}>
					<Scene />
				</Sequence>
			))}
			{/* soft dip between scenes */}
			{SCENES.slice(1).map(([, from], i) => (
				<AbsoluteFill key={i} style={{background: C.ink, pointerEvents: 'none', opacity: interpolate(f, [from - 4, from, from + 6], [0, 0.55, 0], clamp)}} />
			))}
		</AbsoluteFill>
	);
};

export const WORDS = VO_WORDS;
