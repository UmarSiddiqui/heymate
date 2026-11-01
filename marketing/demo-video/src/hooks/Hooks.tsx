import React from 'react';
import {AbsoluteFill, Audio, Img, OffthreadVideo, Sequence, random, spring, staticFile, useCurrentFrame} from 'remotion';
import {VO, VO_BODY, VO_BODY_CLIPS, VoWord} from './voTimings';

// Three 9:16 hook shorts. 30 fps, 120 BPM: one beat = 15 frames, every cut lands on a beat.
// The hook runs as long as its ElevenLabs voiceover; the bass drops right after, and the
// 17 s body follows. Music dies on the last word and the video ends with it.
export const FPS = 30;
const BODY_LENGTH = 510;
export const lengthOf = (hook: Hook) => VO[hook].drop + BODY_LENGTH;
const W = 1080;
const H = 1920;
const src = (name: string) => staticFile(`hooks/${name}`);
const font = 'Figtree, "Avenir Next", sans-serif';
const mono = '"SF Mono", Menlo, monospace';
const C = {bg: '#050608', yellow: '#FFE600', green: '#39FF88', red: '#FF3B3B', blue: '#A8CBFA', paper: '#F5F5F0'};
const ease = (f: number, start: number, dur = 12) => {
	const x = Math.max(0, Math.min(1, (f - start) / dur));
	return 1 - Math.pow(1 - x, 4);
};
const pop = (f: number, delay = 0) => spring({frame: f - delay, fps: FPS, config: {damping: 12, stiffness: 180, mass: 0.6}});

// ---------- captions ----------
type Segment = {from: number; to: number; scene: React.FC};
const HI = /^(STOP|TWENTY|DOLLARS|NOTHING|BURNING|CASH|INSTEAD|HIDING|BREAKS|SECRET|1%|AI|CREW|PHYSICALLY|ALL|WEEK|TWO|KEYS|WHEEL|DRIVES|3D|ZERO|FEES|100%|OPEN|SOURCE|YOU)$/;
const clean = (w: string) => w.toUpperCase().replace(/[.,!?…]+$/g, '');

// One spoken word on screen at a time, held until the next word starts.
const Captions: React.FC<{words: VoWord[]}> = ({words}) => {
	const f = useCurrentFrame();
	const i = words.findIndex((w, k) => f >= w.from && f < (words[k + 1] ? Math.min(words[k + 1].from, w.to + 18) : w.to + 30));
	if (i < 0) return null;
	const c = words[i];
	const text = c.w.toUpperCase().replace(/[,.]$/, '');
	const p = pop(f, c.from);
	const size = Math.min(200, 1250 / Math.max(4, text.length * 0.95));
	const tilt = (random(text + c.from) - 0.5) * 6;
	const hi = HI.test(clean(c.w));
	return (
		<div style={{position: 'absolute', left: 40, right: 40, top: 960, transform: `translateY(-50%) scale(${0.55 + 0.45 * p}) rotate(${tilt}deg)`, textAlign: 'center', zIndex: 100}}>
			<span style={{fontSize: size, fontWeight: 900, lineHeight: 0.95, letterSpacing: -2, color: hi ? C.green : C.yellow, WebkitTextStroke: '14px #000', paintOrder: 'stroke fill', textShadow: `0 10px 0 #000, 0 0 60px ${hi ? '#39ff8866' : '#ffe60055'}`, fontFamily: font}}>{text}</span>
		</div>
	);
};

// ---------- transitions ----------
const Shot: React.FC<{children: React.ReactNode; seed: number; zoom?: number}> = ({children, seed, zoom = 0.0006}) => {
	const f = useCurrentFrame();
	const punch = 1 + 0.16 * (1 - ease(f, 0, 7));
	const amt = Math.max(0, 9 - f) * 4;
	const sx = (random(`${seed}x${f}`) - 0.5) * amt;
	const sy = (random(`${seed}y${f}`) - 0.5) * amt;
	return (
		<AbsoluteFill style={{background: C.bg, overflow: 'hidden'}}>
			<AbsoluteFill style={{transform: `translate(${sx}px,${sy}px) scale(${punch + f * zoom})`}}>{children}</AbsoluteFill>
			{f < 6 && <Glitch seed={seed} f={f} />}
			{f < 3 && <AbsoluteFill style={{background: '#fff', opacity: 0.55 - f * 0.18}} />}
		</AbsoluteFill>
	);
};

const Glitch: React.FC<{seed: number; f: number}> = ({seed, f}) => (
	<AbsoluteFill style={{mixBlendMode: 'screen'}}>
		{Array.from({length: 9}, (_, i) => {
			const r = random(`${seed}g${i}${f}`);
			return <div key={i} style={{position: 'absolute', left: (r - 0.5) * 200, top: random(`${seed}t${i}${f}`) * H, width: W + 200, height: 8 + r * 70, background: i % 3 === 0 ? '#ff004c55' : i % 3 === 1 ? '#00e5ff55' : '#ffffff33'}} />;
		})}
	</AbsoluteFill>
);

const Shake: React.FC<{at: number; power?: number; children: React.ReactNode}> = ({at, power = 40, children}) => {
	const f = useCurrentFrame();
	const k = f >= at ? Math.max(0, 1 - (f - at) / 16) : 0;
	return <AbsoluteFill style={{transform: `translate(${(random(`s${f}`) - 0.5) * power * k}px,${(random(`t${f}`) - 0.5) * power * k}px)`}}>{children}</AbsoluteFill>;
};

// ---------- shared bits ----------
const Mark: React.FC<{size?: number; color?: string}> = ({size = 60, color = C.blue}) => (
	<svg width={size} height={size} viewBox="0 0 128 128" fill="none">
		<g stroke={color} strokeWidth="9" strokeLinecap="round" strokeLinejoin="round"><path d="M18 40 L42 24 L56 41" /><path d="M86 48 L114 53" /><path d="M70 58 L65 72 L74 75" /><path d="M65 99 C78 99 94 97 102 88" /></g>
	</svg>
);

const Key: React.FC<{label: string; down: boolean; size?: number; glow?: boolean}> = ({label, down, size = 300, glow}) => (
	<div style={{width: size, height: size, borderRadius: size * 0.18, display: 'grid', placeItems: 'center', fontSize: size * 0.5, color: glow ? C.green : '#cfd8e6', fontFamily: '"Avenir Next",sans-serif', background: 'linear-gradient(150deg,#2a2f38,#0d0f14)', border: '2px solid #ffffff22', boxShadow: `0 ${down ? 4 : 22}px 0 #000, 0 40px 70px #000a, inset 0 2px 2px #ffffff30${glow ? ', 0 0 80px #39ff8855' : ''}`, transform: `translateY(${down ? 18 : 0}px)`}}>
		{label}
	</div>
);

const Logo: React.FC = () => {
	const f = useCurrentFrame();
	const split = Math.max(0, 14 - f * 1.4);
	return (
		<Shot seed={99}>
			<AbsoluteFill style={{background: '#000', alignItems: 'center', justifyContent: 'center'}}>
				{[
					['#ff004c', -split],
					['#00e5ff', split],
					[C.blue, 0],
				].map(([col, dx], i) => (
					<div key={i} style={{position: 'absolute', display: 'flex', alignItems: 'center', gap: 26, transform: `translateX(${dx}px)`, mixBlendMode: i < 2 ? 'screen' : 'normal', opacity: i < 2 ? 0.8 : 1, top: 520}}>
						<Mark size={170} color={col as string} />
						<span style={{fontSize: 150, fontWeight: 800, letterSpacing: -6, color: i < 2 ? (col as string) : C.paper}}>HeyMate</span>
					</div>
				))}
			</AbsoluteFill>
		</Shot>
	);
};

const CapCut: React.FC<{cursor?: boolean; auto?: boolean; top?: number; s?: number}> = ({cursor = true, auto = false, top = 0, s = 0.66}) => {
	const f = useCurrentFrame();
	// screenshot 3024x1964 scaled by s, centred on the preview; timeline spans x 1176–2520, y 1610
	const left = 540 - 1512 * s;
	const tlY = top + 1610 * s;
	const play = left + 1176 * s + ((f * 9) % (1344 * s));
	const path = [
		[520, top + 900],
		[300, tlY - 10],
		[640, tlY + 10],
		[880, top + 260],
		[430, tlY - 20],
	];
	const seg = Math.min(path.length - 2, Math.floor(f / 22));
	const k = ease(f - seg * 22, 0, 16);
	const cx = path[seg][0] + (path[seg + 1][0] - path[seg][0]) * k;
	const cy = path[seg][1] + (path[seg + 1][1] - path[seg][1]) * k;
	const clicking = (f % 22) > 16;
	return (
		<AbsoluteFill>
			<Img src={src('capcut-drive.png')} style={{position: 'absolute', left, top, width: 3024 * s, height: 1964 * s}} />
			<div style={{position: 'absolute', left: play, top: tlY - 90, width: 4, height: 170, background: '#fff', boxShadow: '0 0 20px #fff'}} />
			{auto &&
				[0, 1, 2, 3, 4].map((i) => {
					const p = pop(f, 6 + i * 7);
					return <div key={i} style={{position: 'absolute', top: tlY + 60, left: 30 + i * 205 + (1 - p) * 700, width: 195, height: 64, borderRadius: 8, background: ['#5b8cff', '#ff8a3d', '#39d98a', '#b26bff', '#ff4d8d'][i], opacity: Math.min(1, p), boxShadow: '0 0 30px #0008', border: '2px solid #ffffff55'}} />;
				})}
			{cursor && (
				<div style={{position: 'absolute', left: cx, top: cy}}>
					{clicking && <div style={{position: 'absolute', left: -40, top: -40, width: 80, height: 80, borderRadius: '50%', border: `5px solid ${C.green}`, transform: `scale(${1 + ((f % 22) - 16) * 0.15})`}} />}
					<svg width="70" height="90" viewBox="0 0 24 30"><path d="M2 2 L2 24 L8 18 L12 27 L16 25 L12 16 L20 16 Z" fill="#fff" stroke="#000" strokeWidth="1.6" strokeLinejoin="round" /></svg>
				</div>
			)}
			<div style={{position: 'absolute', left: 60, top: top + 40, padding: '14px 26px', borderRadius: 40, background: '#000c', color: C.green, fontSize: 34, fontWeight: 700, display: 'flex', alignItems: 'center', gap: 14, border: `2px solid ${C.green}66`}}>
				<span style={{width: 16, height: 16, borderRadius: '50%', background: C.green, opacity: f % 20 < 10 ? 1 : 0.3}} />
				HeyMate is driving · no hands
			</div>
		</AbsoluteFill>
	);
};

const Mates: React.FC = () => {
	const f = useCurrentFrame();
	return (
		<AbsoluteFill style={{background: '#0a0b0e'}}>
			<Img src={src('mates.webp')} style={{position: 'absolute', height: 1920, left: -260 - f * 1.2, top: 0, transform: 'scale(1.55)', transformOrigin: '22% 30%'}} />
			{(['tide', 'lilac', 'peach'] as const).map((b, i) => {
				const p = pop(f, 4 + i * 6);
				return <Img key={b} src={src(`${b}.png`)} style={{position: 'absolute', width: 260, left: 80 + i * 330, top: 1450 + Math.sin(f / 8 + i) * 14, transform: `scale(${p}) rotate(${(i - 1) * 12}deg)`, filter: 'drop-shadow(0 24px 30px #000a)'}} />;
			})}
		</AbsoluteFill>
	);
};

// ---------- body: master script 0:05 → 0:24 ----------
const Drive: React.FC = () => {
	const f = useCurrentFrame();
	const q = 'Can you edit this video?';
	const typed = q.slice(0, Math.floor(Math.max(0, f - 6) / 1.3));
	return (
		<Shot seed={1}>
			<AbsoluteFill style={{background: '#0b0c10'}}>
				<div style={{position: 'absolute', top: 0, height: 760, left: 0, right: 0, background: 'radial-gradient(circle at 50% 0%,#1d2a40,#07080b 70%)'}}>
					<div style={{position: 'absolute', left: 90, right: 90, top: 150, borderRadius: '0 0 60px 60px', background: '#000', padding: '120px 50px 50px', boxShadow: '0 40px 90px #000c, 0 0 0 2px #ffffff14'}}>
						<div style={{display: 'flex', alignItems: 'center', gap: 22, color: '#8fa0b8', fontSize: 34}}>
							<Mark size={64} />
							Ask HeyMate
						</div>
						<div style={{marginTop: 36, fontSize: 58, color: C.paper, fontWeight: 600, minHeight: 80}}>
							{typed}
							<span style={{opacity: f % 16 < 8 ? 1 : 0, color: C.blue}}>|</span>
						</div>
					</div>
				</div>
				<div style={{position: 'absolute', top: 760, left: 0, right: 0, height: 4, background: C.green, boxShadow: `0 0 30px ${C.green}`}} />
				<div style={{position: 'absolute', top: 764, left: 0, right: 0, bottom: 0, overflow: 'hidden'}}>
					<CapCut top={-180} />
				</div>
			</AbsoluteFill>
		</Shot>
	);
};

const Model3D: React.FC = () => (
	<Shot seed={2} zoom={0.0015}>
		<OffthreadVideo src={src('board.mp4')} startFrom={24} playbackRate={1.4} muted style={{position: 'absolute', height: 1920, width: 1920 * (1440 / 944), left: -(1920 * (1440 / 944) - W) / 2 - 60, top: 0, transform: 'scale(1.5)', transformOrigin: '55% 55%'}} />
		<AbsoluteFill style={{background: 'radial-gradient(circle at 50% 55%,transparent 40%,#000a 100%)'}} />
	</Shot>
);

const Fees: React.FC = () => {
	const f = useCurrentFrame();
	const on = ease(f, 14, 8);
	const ban = pop(f, 48);
	return (
		<Shot seed={3}>
			<Shake at={48} power={50}>
				<AbsoluteFill style={{background: 'radial-gradient(circle at 50% 30%,#1f1712,#050608 70%)'}}>
					<div style={{position: 'absolute', top: 230, left: 0, right: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 50}}>
						<Img src={src('claude.svg')} style={{width: 170}} />
						<span style={{fontSize: 120, fontWeight: 800, color: C.paper, letterSpacing: -4}}>Claude</span>
					</div>
					<div style={{position: 'absolute', top: 470, left: 190, width: 700, height: 340, borderRadius: 200, background: on > 0.5 ? '#34c759' : '#3a3d44', boxShadow: `inset 0 6px 20px #0006${on > 0.5 ? ', 0 0 120px #34c75966' : ''}`}}>
						<div style={{position: 'absolute', top: 20, left: 20 + on * 360, width: 300, height: 300, borderRadius: '50%', background: '#fff', boxShadow: '0 12px 30px #0008'}} />
					</div>
					<div style={{position: 'absolute', top: 1330, left: 0, right: 0, textAlign: 'center'}}>
						<span style={{fontSize: 150, fontWeight: 900, letterSpacing: -4, color: '#d9d9d9', opacity: ease(f, 30)}}>SUBSCRIPTION</span>
					</div>
					<svg style={{position: 'absolute', left: 540 - 260, top: 1420 - 260, transform: `scale(${ban}) rotate(${(1 - ban) * -40}deg)`}} width="520" height="520" viewBox="0 0 100 100">
						<circle cx="50" cy="50" r="42" fill="none" stroke={C.red} strokeWidth="10" />
						<line x1="21" y1="79" x2="79" y2="21" stroke={C.red} strokeWidth="10" />
					</svg>
				</AbsoluteFill>
			</Shake>
		</Shot>
	);
};

const OpenSource: React.FC = () => {
	const f = useCurrentFrame();
	const glow = 0.6 + 0.4 * Math.sin(f / 4);
	const badge = pop(f, 18);
	return (
		<Shot seed={4} zoom={0.0012}>
			<AbsoluteFill style={{background: '#0d1117', fontFamily: '-apple-system, "Segoe UI", sans-serif'}}>
				<div style={{height: 150, background: '#010409', borderBottom: '2px solid #30363d', display: 'flex', alignItems: 'center', padding: '0 50px', gap: 26}}>
					<Img src={src('github.svg')} style={{width: 70, filter: 'invert(1)'}} />
					<span style={{fontSize: 40, color: '#e6edf3'}}>
						UmarSiddiqui / <b>heymate</b>
					</span>
					<span style={{fontSize: 26, color: '#7d8590', border: '2px solid #30363d', borderRadius: 30, padding: '4px 16px'}}>Public</span>
				</div>
				<div style={{padding: '70px 60px'}}>
					<div style={{display: 'flex', alignItems: 'center', gap: 24}}>
						<Mark size={110} />
						<span style={{fontSize: 110, fontWeight: 700, color: '#e6edf3'}}>HeyMate</span>
					</div>
					<div style={{display: 'flex', gap: 18, marginTop: 50, flexWrap: 'wrap', alignItems: 'center'}}>
						<span style={{fontSize: 30, background: '#30363d', color: '#c9d1d9', padding: '10px 20px', borderRadius: 8}}>macOS 14.2+</span>
						<span style={{fontSize: 30, background: '#30363d', color: '#c9d1d9', padding: '10px 20px', borderRadius: 8}}>Apple silicon & Intel</span>
					</div>
					<div style={{marginTop: 60, display: 'inline-block', transform: `scale(${0.6 + badge * 0.6})`, transformOrigin: 'left center'}}>
						<span style={{fontSize: 66, fontWeight: 800, color: C.green, padding: '22px 40px', borderRadius: 18, border: `4px solid ${C.green}`, background: '#0b2a18', textShadow: `0 0 ${30 * glow}px ${C.green}`, boxShadow: `0 0 ${90 * glow}px ${C.green}88, inset 0 0 40px #39ff8833`}}>Free & Open Source</span>
					</div>
				</div>
				<div style={{position: 'absolute', bottom: 0, left: 0, right: 0, height: 700, background: `radial-gradient(ellipse at 50% 100%,#39ff8833,transparent 70%)`}} />
			</AbsoluteFill>
		</Shot>
	);
};

const Cliff: React.FC = () => {
	const f = useCurrentFrame();
	const rows = ['QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM'];
	return (
		<Shot seed={5} zoom={0.0008}>
			<AbsoluteFill style={{background: 'radial-gradient(circle at 50% 70%,#141820,#000 75%)', perspective: 1400}}>
				<div style={{position: 'absolute', left: -200, right: -200, top: 1150, transform: 'rotateX(48deg)', display: 'flex', flexDirection: 'column', gap: 18, alignItems: 'center'}}>
					{rows.map((r, i) => (
						<div key={r} style={{display: 'flex', gap: 18, marginLeft: i * 60}}>
							{r.split('').map((k) => (
								<div key={k} style={{width: 120, height: 120, borderRadius: 22, background: 'linear-gradient(150deg,#262a33,#0c0e12)', border: '2px solid #ffffff18', color: '#7c8698', fontSize: 40, display: 'grid', placeItems: 'center', boxShadow: '0 10px 0 #000'}}>{k}</div>
							))}
						</div>
					))}
					<div style={{display: 'flex', gap: 18, marginLeft: -340}}>
						<Key label="⌃" down={false} size={120} glow={f % 30 < 15} />
						<Key label="⌥" down={false} size={120} glow={f % 30 < 15} />
					</div>
				</div>
			</AbsoluteFill>
		</Shot>
	);
};

// frames after the drop
const BODY: Segment[] = [
	{from: 0, to: 120, scene: Drive},
	{from: 120, to: 240, scene: Model3D},
	{from: 240, to: 345, scene: Fees},
	{from: 345, to: 450, scene: OpenSource},
	{from: 450, to: BODY_LENGTH, scene: Cliff},
];

// ---------- hook 1: anger / frustration ----------
const Slam: React.FC = () => {
	const f = useCurrentFrame();
	const fall = Math.min(1, f / 8);
	const y = -1100 * (1 - fall * fall);
	const squash = f >= 8 ? 1 - 0.12 * Math.max(0, 1 - (f - 8) / 6) : 1;
	return (
		<Shake at={8} power={70}>
			<AbsoluteFill style={{background: 'radial-gradient(circle at 50% 60%,#2a0c0c,#050608 70%)'}}>
				{f >= 8 &&
					[0, 1, 2].map((i) => {
						const p = ease(f, 8 + i * 3, 20);
						return <div key={i} style={{position: 'absolute', left: 540 - 500 * p, top: 1230 - 140 * p, width: 1000 * p, height: 280 * p, borderRadius: '50%', border: `${10 - i * 3}px solid ${C.red}`, opacity: 1 - p}} />;
					})}
				<div style={{position: 'absolute', left: 540 - 210, top: 600 + y, width: 420, height: 640, transform: `scaleY(${squash})`, transformOrigin: '50% 100%'}}>
					<svg width="420" height="640" viewBox="0 0 42 64">
						<defs>
							<linearGradient id="m" x1="0" x2="1">
								<stop offset="0" stopColor="#e9ecf1" />
								<stop offset="1" stopColor="#9aa1ad" />
							</linearGradient>
						</defs>
						<rect x="1" y="1" width="40" height="62" rx="20" fill="url(#m)" stroke="#000" strokeWidth="1" />
						<line x1="21" y1="2" x2="21" y2="24" stroke="#5c626d" strokeWidth="1" />
						<rect x="19.5" y="9" width="3" height="8" rx="1.5" fill="#5c626d" />
					</svg>
				</div>
			</AbsoluteFill>
		</Shake>
	);
};

const Statement: React.FC = () => {
	const f = useCurrentFrame();
	const rows = ['AI WRITER PRO', 'CHAT WRAPPER PLUS', 'AI NOTES+', 'SMART SUMMARY AI', 'AI EMAIL HELPER', 'PROMPT VAULT'];
	const circle = ease(f, 55, 20);
	return (
		<Shot seed={11} zoom={0.0025}>
			<AbsoluteFill style={{background: '#110505'}}>
				<div style={{position: 'absolute', left: 70, top: 200, width: 940, padding: 50, background: '#f4f1ea', transform: 'rotate(-3deg)', fontFamily: mono, color: '#111', boxShadow: '0 40px 90px #000c'}}>
					<div style={{fontSize: 34, fontWeight: 700}}>CARD STATEMENT · OCT</div>
					<div style={{fontSize: 24, color: '#666', marginBottom: 30}}>RECURRING CHARGES</div>
					{rows.map((r, i) => (
						<div key={r} style={{display: 'flex', justifyContent: 'space-between', fontSize: 38, padding: '16px 0', borderBottom: '2px dashed #ccc', opacity: ease(f, i * 4, 6), transform: `translateX(${(1 - ease(f, i * 4, 6)) * 120}px)`}}>
							<span>{r}</span>
							<span style={{color: '#c11'}}>$20.00</span>
						</div>
					))}
					<div style={{position: 'relative', display: 'flex', justifyContent: 'space-between', fontSize: 50, fontWeight: 800, marginTop: 30, color: '#c11'}}>
						<span>TOTAL / MONTH</span>
						<span>$120.00</span>
						<svg style={{position: 'absolute', left: -30, top: -30, overflow: 'visible'}} width="900" height="130">
							<ellipse cx="450" cy="58" rx="460" ry="70" fill="none" stroke={C.red} strokeWidth="9" strokeDasharray="2950" strokeDashoffset={2950 * (1 - circle)} strokeLinecap="round" />
						</svg>
					</div>
				</div>
			</AbsoluteFill>
		</Shot>
	);
};

const Tabs: React.FC = () => {
	const f = useCurrentFrame();
	const count = Math.min(48, Math.floor(f * 0.9) + 6);
	const names = ['Chat', 'AI', 'Docs', 'Prompt', 'Copy', 'Paste', 'Notes', 'Bot', 'Help', 'Code', 'Edit', 'GPT'];
	return (
		<Shot seed={12} zoom={0.0018}>
			<AbsoluteFill style={{background: '#08090c'}}>
				<div style={{position: 'absolute', left: 30, right: 30, top: 180, height: 1500, borderRadius: 26, background: '#1f2128', overflow: 'hidden', boxShadow: '0 40px 90px #000'}}>
					<div style={{display: 'flex', flexWrap: 'wrap', gap: 4, padding: 14, background: '#15161b'}}>
						{Array.from({length: count}, (_, i) => (
							<div key={i} style={{width: 120, height: 50, borderRadius: 10, background: i === count - 1 ? '#2f323b' : '#22242b', display: 'flex', alignItems: 'center', gap: 6, padding: '0 8px', fontSize: 18, color: '#aab', overflow: 'hidden', whiteSpace: 'nowrap'}}>
								<span style={{width: 16, height: 16, borderRadius: 4, flexShrink: 0, background: `hsl(${(i * 47) % 360} 70% 55%)`}} />
								{names[i % names.length]}
							</div>
						))}
					</div>
					<div style={{padding: 50, display: 'flex', flexDirection: 'column', gap: 30}}>
						{[0, 1, 2].map((i) => {
							const active = Math.floor(f / 10) % 3 === i;
							return (
								<div key={i} style={{height: 170, borderRadius: 20, border: `3px ${active ? 'solid' : 'dashed'} ${active ? C.yellow : '#444'}`, display: 'flex', alignItems: 'center', padding: '0 34px', fontSize: 40, color: active ? C.yellow : '#666', fontFamily: mono}}>
									{['⌘C  copy from app…', '⌘V  paste into chat tab…', '⌘C  copy answer back…'][i]}
								</div>
							);
						})}
					</div>
				</div>
				<div style={{position: 'absolute', right: 60, top: 120, background: C.red, color: '#fff', fontWeight: 900, fontSize: 54, padding: '12px 30px', borderRadius: 50, transform: `scale(${1 + 0.08 * Math.sin(f / 3)})`}}>{count} TABS</div>
			</AbsoluteFill>
		</Shot>
	);
};

const Burn: React.FC = () => {
	const f = useCurrentFrame();
	return (
		<Shot seed={13}>
			<AbsoluteFill style={{background: 'radial-gradient(circle at 50% 100%,#ff5a1f,#5a0f00 45%,#050608 80%)'}}>
				{Array.from({length: 22}, (_, i) => {
					const r = random(`b${i}`);
					const life = ((f + r * 40) % 40) / 40;
					return (
						<div key={i} style={{position: 'absolute', left: 60 + r * 860, top: 1900 - life * 1700, width: 220, height: 110, borderRadius: 10, background: '#2f7d32', border: '4px solid #a5d6a7', color: '#d7ffd9', fontSize: 64, fontWeight: 900, display: 'grid', placeItems: 'center', opacity: 1 - life, transform: `rotate(${(r - 0.5) * 80 + life * 90}deg) scale(${1 - life * 0.5})`, filter: `sepia(${life}) brightness(${1 - life * 0.6})`}}>
							$20
						</div>
					);
				})}
			</AbsoluteFill>
		</Shot>
	);
};

// ---------- hook 2: insider secret ----------
const Mic: React.FC = () => {
	const f = useCurrentFrame();
	return (
		<Shot seed={21} zoom={0.0012}>
			<AbsoluteFill style={{background: 'radial-gradient(circle at 50% 45%,#0f1a2b,#020305 65%)'}}>
				{[0, 1, 2].map((i) => {
					const p = ((f + i * 20) % 60) / 60;
					return <div key={i} style={{position: 'absolute', left: 540 - 300 - p * 200, top: 700 - 300 - p * 200, width: 600 + p * 400, height: 600 + p * 400, borderRadius: '50%', border: '2px solid #a8cbfa', opacity: 0.25 * (1 - p)}} />;
				})}
				<svg style={{position: 'absolute', left: 540 - 200, top: 260}} width="400" height="1200" viewBox="0 0 40 120">
					<defs>
						<linearGradient id="cap" x1="0" x2="1">
							<stop offset="0" stopColor="#0b0f16" />
							<stop offset="0.75" stopColor="#2c3a52" />
							<stop offset="1" stopColor="#a8cbfa" />
						</linearGradient>
					</defs>
					<rect x="6" y="2" width="28" height="48" rx="14" fill="url(#cap)" stroke="#a8cbfa55" strokeWidth="0.6" />
					{Array.from({length: 9}, (_, i) => (
						<line key={i} x1="8" x2="32" y1={10 + i * 4.4} y2={10 + i * 4.4} stroke="#ffffff22" strokeWidth="0.5" />
					))}
					<rect x="12" y="50" width="16" height="10" rx="2" fill="#151b26" />
					<rect x="18.5" y="60" width="3" height="60" fill="#0d1118" />
				</svg>
				<div style={{position: 'absolute', bottom: 120, width: '100%', textAlign: 'center', fontSize: 30, letterSpacing: 8, color: '#5a6b85'}}>OFF THE RECORD</div>
			</AbsoluteFill>
		</Shot>
	);
};

const Terminal: React.FC = () => {
	const f = useCurrentFrame();
	const lines = ['$ git clone github.com/UmarSiddiqui/heymate', 'Cloning into heymate…', 'Receiving objects: 100% done.', '$ open HeyMate.app', '> mate crew online ▊'];
	const chars = f * 3;
	let left = chars;
	return (
		<Shot seed={22} zoom={0.002}>
			<AbsoluteFill style={{background: '#010402', perspective: 1200}}>
				<div style={{position: 'absolute', left: -60, right: -60, top: 520, transform: 'rotateX(18deg) rotateY(-14deg)', fontFamily: mono, fontSize: 58, lineHeight: 1.6, color: C.green, textShadow: `0 0 18px ${C.green}, 0 0 50px #39ff8866`, padding: '0 120px'}}>
					{lines.map((l, i) => {
						const show = l.slice(0, Math.max(0, left));
						left -= l.length;
						return (
							<div key={i} style={{whiteSpace: 'nowrap', opacity: i === 0 || show ? 1 : 0}}>
								{show}
							</div>
						);
					})}
				</div>
				<AbsoluteFill style={{background: 'linear-gradient(#010402 0%,transparent 30%,transparent 70%,#010402 100%)'}} />
				<AbsoluteFill style={{background: 'repeating-linear-gradient(transparent 0 3px,#00000055 3px 5px)'}} />
			</AbsoluteFill>
		</Shot>
	);
};

const StuckChat: React.FC = () => {
	const f = useCurrentFrame();
	return (
		<Shot seed={23}>
			<AbsoluteFill style={{background: '#16171a', filter: 'grayscale(1)'}}>
				{f < 8 && (
					<AbsoluteFill style={{zIndex: 5}}>
						<Logo />
					</AbsoluteFill>
				)}
				<div style={{position: 'absolute', left: 70, right: 70, top: 230, height: 1450, borderRadius: 30, background: '#222429', padding: 50, display: 'flex', flexDirection: 'column', gap: 40}}>
					<div style={{fontSize: 36, color: '#777'}}>web chatbot · new tab</div>
					<div style={{alignSelf: 'flex-end', background: '#3a3c42', color: '#ddd', fontSize: 40, padding: '24px 34px', borderRadius: 30, maxWidth: 700}}>Can you click the export button for me?</div>
					<div style={{background: '#2c2e33', color: '#aaa', fontSize: 40, padding: '24px 34px', borderRadius: 30, maxWidth: 760}}>I can't see your screen or use your apps. Try copying and pasting…</div>
					<div style={{display: 'flex', gap: 14, paddingLeft: 30}}>
						{[0, 1, 2].map((i) => (
							<div key={i} style={{width: 26, height: 26, borderRadius: '50%', background: '#666', opacity: Math.floor(f / 6) % 3 === i ? 1 : 0.3}} />
						))}
					</div>
				</div>
			</AbsoluteFill>
		</Shot>
	);
};

// ---------- hook 3: lazy shortcut ----------
const Chair: React.FC = () => {
	const f = useCurrentFrame();
	const sway = Math.sin(f / 22) * 2;
	return (
		<Shot seed={31} zoom={0.0006}>
			<AbsoluteFill style={{background: 'linear-gradient(#1b1430,#3b2346 55%,#120d18)'}}>
				<div style={{position: 'absolute', left: 540 - 300, top: -200, width: 600, height: 600, borderRadius: '50%', background: 'radial-gradient(circle,#ffd9a066,transparent 70%)'}} />
				<div style={{position: 'absolute', left: 540 - 60, top: 0, width: 120, height: 150, background: '#2a2236', borderRadius: '0 0 60px 60px', boxShadow: '0 40px 80px #ffd9a055'}} />
				<svg style={{position: 'absolute', left: 90, top: 520, transform: `rotate(${sway}deg)`, transformOrigin: '50% 90%'}} width="900" height="1200" viewBox="0 0 90 120">
					{/* reclined gaming chair */}
					<path d="M18 10 Q12 8 14 20 L26 74 L58 74 L60 66 L34 62 L24 14 Q22 8 18 10 Z" fill="#111" stroke="#ff2e63" strokeWidth="1.2" />
					<rect x="38" y="74" width="4" height="22" fill="#222" />
					<path d="M22 100 L58 100 M40 96 L40 100" stroke="#333" strokeWidth="3" strokeLinecap="round" />
					{/* person leaning back */}
					<circle cx="24" cy="18" r="8" fill="#e0b18f" />
					<path d="M18 14 L10 26 L26 24 Z" fill="none" stroke="#e0b18f" strokeWidth="3.2" strokeLinejoin="round" />
					<path d="M30 14 L38 26 L24 24" fill="none" stroke="#e0b18f" strokeWidth="3.2" strokeLinejoin="round" />
					<path d="M24 26 L34 60 L56 58" fill="none" stroke="#3d5afe" strokeWidth="9" strokeLinecap="round" strokeLinejoin="round" />
					<path d="M56 58 L78 54 L84 54" fill="none" stroke="#263238" strokeWidth="7" strokeLinecap="round" />
					<rect x="80" y="49" width="7" height="6" rx="2" fill="#fff" />
				</svg>
				<div style={{position: 'absolute', left: 620, top: 470, fontSize: 70, color: '#ffffffaa', fontWeight: 800, opacity: 0.5 + 0.5 * Math.sin(f / 10)}}>z z z</div>
			</AbsoluteFill>
		</Shot>
	);
};

const AutoTimeline: React.FC = () => (
	<Shot seed={32}>
		<CapCut auto cursor={false} top={0} s={0.98} />
	</Shot>
);

const TwoKeys: React.FC = () => {
	const f = useCurrentFrame();
	const down = f % 30 > 4 && f % 30 < 16;
	return (
		<Shot seed={33}>
			<AbsoluteFill style={{background: 'radial-gradient(circle at 50% 40%,#1a2333,#050608 70%)', alignItems: 'center'}}>
				<div style={{position: 'absolute', top: 360, display: 'flex', gap: 60, transform: 'perspective(900px) rotateX(24deg)'}}>
					<Key label="⌃" down={down} size={340} glow={down} />
					<Key label="⌥" down={down} size={340} glow={down} />
				</div>
				<div style={{position: 'absolute', bottom: 260, fontSize: 46, letterSpacing: 6, color: '#8090aa'}}>CONTROL + OPTION</div>
			</AbsoluteFill>
		</Shot>
	);
};

const Driving: React.FC = () => (
	<Shot seed={34}>
		<CapCut top={0} s={0.98} />
	</Shot>
);

// ---------- hook definitions ----------
// One scene per script line (see scripts/hooks-vo.mjs); each cuts in when its first word is spoken.
type Hook = 'anger' | 'insider' | 'lazy';
const HOOK_SCENES: Record<Hook, React.FC[]> = {
	anger: [Slam, Statement, Tabs, Burn, Logo],
	insider: [Mic, Terminal, StuckChat, Mates, Logo],
	lazy: [Chair, AutoTimeline, TwoKeys, Mates, Driving],
};

export const HookVideo: React.FC<{hook: Hook}> = ({hook}) => {
	const f = useCurrentFrame();
	const {starts, drop, words} = VO[hook];
	const segments: Segment[] = [
		...HOOK_SCENES[hook].map((scene, i) => ({from: starts[i], to: starts[i + 1] ?? drop, scene})),
		...BODY.map((b) => ({...b, from: b.from + drop, to: b.to + drop})),
	];
	const captions = [...words, ...VO_BODY.map((w) => ({...w, from: w.from + drop, to: w.to + drop}))];
	return (
		<AbsoluteFill style={{fontFamily: font, background: C.bg, color: C.paper}}>
			<style>{`@font-face{font-family:Figtree;src:url('${src('Figtree.woff2')}') format('woff2');font-weight:300 900;font-style:normal}*{box-sizing:border-box}`}</style>
			<Audio src={src(`score-${hook}.wav`)} volume={0.5} />
			<Audio src={src(`vo-${hook}.mp3`)} />
			{VO_BODY_CLIPS.map((clip) => (
				<Sequence key={clip.file} from={drop + Math.round(clip.at * FPS)}>
					<Audio src={src(clip.file)} />
				</Sequence>
			))}
			{segments.map((s) => (
				<Sequence key={s.from} from={s.from} durationInFrames={s.to - s.from}>
					<s.scene />
				</Sequence>
			))}
			<Captions words={captions} />
			<div style={{position: 'absolute', left: 0, bottom: 0, height: 8, width: `${(f / lengthOf(hook)) * 100}%`, background: C.green, opacity: 0.7}} />
		</AbsoluteFill>
	);
};
