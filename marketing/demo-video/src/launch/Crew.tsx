import React from 'react';
import {AbsoluteFill, Img, interpolate, spring, staticFile, useCurrentFrame} from 'remotion';

const INK = '#080d19';
const BLUE = '#A8CBFA';
const PAPER = '#f5f5f0';
const FONT = 'Figtree, "Avenir Next", sans-serif';
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const rise = (frame: number, delay = 0, duration = 38) => spring({frame: frame - delay, fps: 60, durationInFrames: duration, config: {damping: 20, stiffness: 115, mass: 0.85}});

const Eyebrow: React.FC<{children: React.ReactNode; light?: boolean; style?: React.CSSProperties}> = ({children, light = false, style}) => (
  <div style={{fontFamily: FONT, fontSize: 20, fontWeight: 600, letterSpacing: 3.3, textTransform: 'uppercase', color: light ? '#65707c' : BLUE, ...style}}>{children}</div>
);

const Character: React.FC<{name: string; role: string; subtitle: string; x: number; y: number; size: number; angle: number; delay: number; frame: number; color: string}> = ({name, role, subtitle, x, y, size, angle, delay, frame, color}) => {
  const p = rise(frame, delay, 50);
  const float = Math.sin((frame - delay) / 46) * 11;
  return (
    <div style={{position: 'absolute', left: x, top: y, width: size, height: size + 100, opacity: Math.min(1, p * 2), transform: `translateY(${(1 - p) * 180 + float}px) rotate(${angle + Math.sin(frame / 66) * 1.2}deg) scale(${0.78 + p * 0.22})`, transformOrigin: '50% 70%'}}>
      <div style={{position: 'absolute', left: '12%', right: '12%', bottom: 72, height: 40, borderRadius: '50%', background: '#000', filter: 'blur(25px)', opacity: 0.55}} />
      <Img src={staticFile(`launch/${name}.png`)} style={{position: 'absolute', inset: 0, width: size, height: size, objectFit: 'contain', filter: 'drop-shadow(0 28px 38px rgba(0,0,0,.3))'}} />
      <div style={{position: 'absolute', bottom: 64, left: '50%', transform: 'translateX(-50%)', padding: '13px 24px 15px', border: '1px solid rgba(255,255,255,.2)', borderRadius: 17, background: '#172334', boxShadow: '0 12px 36px #03081080', whiteSpace: 'nowrap'}}>
        <div style={{fontSize: 28, fontWeight: 650, color, letterSpacing: -.6}}>{role}</div>
        <div style={{fontSize: 17, color: '#a4b1c6', marginTop: 5, letterSpacing: .1}}>{subtitle}</div>
      </div>
    </div>
  );
};

const CrewPortrait: React.FC<{frame: number}> = ({frame}) => {
  const p = rise(frame, 0, 42);
  return (
    <AbsoluteFill style={{background: INK, fontFamily: FONT, color: PAPER, overflow: 'hidden'}}>
      <AbsoluteFill style={{background: 'radial-gradient(ellipse at 74% 69%, #183751 0%, transparent 48%), radial-gradient(ellipse at 21% 100%, #251c3a 0%, transparent 44%)'}} />
      <svg style={{position: 'absolute', inset: 0, width: 1920, height: 1080, opacity: .28}} viewBox="0 0 1920 1080">
        <ellipse cx="1120" cy="800" rx="760" ry="225" fill="none" stroke="#83a9cc" strokeWidth="1" transform="rotate(-11 1120 800)" />
        <ellipse cx="1120" cy="800" rx="920" ry="320" fill="none" stroke="#83a9cc" strokeWidth="1" transform="rotate(-11 1120 800)" opacity=".36" />
      </svg>
      <div style={{position: 'absolute', left: 105, top: 106, transform: `translateY(${(1 - p) * 55}px)`, opacity: p}}>
        <Eyebrow>A mate for every kind of day</Eyebrow>
        <div style={{marginTop: 30, fontSize: 118, fontWeight: 650, lineHeight: 1.01, letterSpacing: -7}}>Your own<br /><span style={{color: BLUE}}>little crew.</span></div>
      </div>
      <Character name="lilac" role="Research" subtitle="Find the useful bits." x={500} y={453} size={380} angle={-11} delay={15} frame={frame} color="#e1ccfa" />
      <Character name="tide" role="Inbox" subtitle="Make room to think." x={920} y={300} size={565} angle={5} delay={5} frame={frame} color="#bddbd7" />
      <Character name="peach" role="Code" subtitle="Build the next thing." x={1455} y={495} size={355} angle={12} delay={26} frame={frame} color="#ffd8c8" />
      <div style={{position: 'absolute', left: 108, bottom: 88, display: 'flex', alignItems: 'center', gap: 15, color: '#899aaf', fontSize: 22, opacity: interpolate(frame, [50, 80], [0, 1], clamp)}}><span style={{width: 6, height: 6, borderRadius: 3, background: BLUE}} /> Roles. Personalities. Routines.</div>
    </AbsoluteFill>
  );
};

const CrewProduct: React.FC<{frame: number}> = ({frame}) => {
  const p = rise(frame, 0, 50);
  const text = rise(frame, 5, 42);
  const zoom = interpolate(frame, [0, 240], [1, 1.035], clamp);
  return (
    <AbsoluteFill style={{background: INK, color: PAPER, fontFamily: FONT, overflow: 'hidden'}}>
      <AbsoluteFill style={{background: 'radial-gradient(ellipse at 80% 60%, #142a44, transparent 62%)'}} />
      <div style={{position: 'absolute', left: 105, top: 118}}><Eyebrow>Delegate. Check back.</Eyebrow></div>
      <div style={{position: 'absolute', left: 103, top: 323, width: 420, opacity: text, transform: `translateY(${(1 - text) * 45}px)`}}>
        <div style={{fontSize: 97, lineHeight: 1.02, fontWeight: 650, letterSpacing: -5.8}}>Give<br />busywork<br /><span style={{color: BLUE}}>a mate.</span></div>
        <div style={{fontSize: 25, lineHeight: 1.45, marginTop: 34, maxWidth: 340, color: '#a7b6cb'}}>Your tasks.<br />Their little to-do list.</div>
      </div>
      <div style={{position: 'absolute', left: 570, top: 180, width: 1280, height: 803, borderRadius: 28, overflow: 'hidden', border: '1px solid #ffffff26', background: '#1f1f21', boxShadow: '0 50px 120px #000b', opacity: Math.min(1, p * 2), transform: `perspective(2000px) translateX(${(1 - p) * 200}px) rotateY(${(1 - p) * -13}deg) scale(${zoom})`, transformOrigin: '80% 50%'}}>
        <Img src={staticFile('launch/chat.webp')} style={{display: 'block', width: '100%', height: '100%', objectFit: 'cover'}} />
      </div>
      <div style={{position: 'absolute', left: 105, bottom: 56, fontSize: 17, color: '#738298', letterSpacing: .4}}>Product UI · example task</div>
    </AbsoluteFill>
  );
};

/** Eight-second sequence: character portraits, then an actual product UI image. */
export const CrewScene: React.FC = () => {
  const frame = useCurrentFrame();
  return frame < 240 ? <CrewPortrait frame={frame} /> : <CrewProduct frame={frame - 240} />;
};

const Provider: React.FC<{file: string; title: string; detail: string; index: number; frame: number; background: string}> = ({file, title, detail, index, frame, background}) => {
  const p = rise(frame, 18 + index * 10, 55);
  const angle = [-10, 1, 11][index];
  const y = [342, 234, 332][index];
  const bob = Math.sin(frame / 65 + index * 1.5) * 6;
  return (
    <div style={{position: 'absolute', left: 862 + index * 289, top: y, width: 284, height: 408, borderRadius: 32, background, border: '1px solid #ffffffd0', color: INK, boxShadow: '0 36px 65px #10182018, inset 0 2px 2px #ffffffc0', opacity: Math.min(1, p * 1.5), transform: `translateY(${(1 - p) * 280 + bob}px) rotate(${angle * p}deg) scale(${.85 + .15 * p})`}}>
      <div style={{position: 'absolute', left: 27, top: 25, fontSize: 13, letterSpacing: 2, fontWeight: 650, color: '#697782'}}>0{index + 1}</div>
      <Img src={staticFile(`launch/${file}.svg`)} style={{position: 'absolute', width: 106, height: 106, objectFit: 'contain', left: 89, top: 98}} />
      <div style={{position: 'absolute', bottom: 42, left: 28}}>
        <div style={{fontSize: 34, fontWeight: 650, letterSpacing: -1.4}}>{title}</div>
        <div style={{fontSize: 17, color: '#5f6b72', marginTop: 8}}>{detail}</div>
      </div>
    </div>
  );
};

/** Six-second provider choice scene. All marks retain their source colors. */
export const BrainScene: React.FC = () => {
  const frame = useCurrentFrame();
  const p = rise(frame, 0, 42);
  const second = rise(frame, 9, 42);
  return (
    <AbsoluteFill style={{background: PAPER, color: INK, fontFamily: FONT, overflow: 'hidden'}}>
      <AbsoluteFill style={{background: 'radial-gradient(ellipse at 77% 57%, #d7e6f4 0%, transparent 60%)'}} />
      <svg viewBox="0 0 1920 1080" style={{position: 'absolute', inset: 0, width: 1920, height: 1080, opacity: .5}}><ellipse cx="1360" cy="556" rx="592" ry="432" fill="none" stroke="#b9cbd9" strokeWidth="1" /><ellipse cx="1360" cy="556" rx="720" ry="556" fill="none" stroke="#cdd8dc" strokeWidth="1" /></svg>
      <div style={{position: 'absolute', top: 108, left: 105}}><Eyebrow light>Bring the AI you already use</Eyebrow></div>
      <div style={{position: 'absolute', left: 100, top: 306, fontWeight: 650, fontSize: 133, lineHeight: 1.04, letterSpacing: -7}}>
        <div style={{opacity: p, transform: `translateY(${(1 - p) * 60}px)`}}>Your AI.</div>
        <div style={{opacity: second, transform: `translateY(${(1 - second) * 60}px)`, color: '#477fa8'}}>Your choice.</div>
      </div>
      <Provider file="openai" title="ChatGPT" detail="Via Codex" index={0} frame={frame} background="#e7ede8" />
      <Provider file="claude" title="Claude" detail="Via Claude Code" index={1} frame={frame} background="#f4e8df" />
      <Provider file="opencode" title="OpenCode" detail="Your model, connected" index={2} frame={frame} background="#e5e5ef" />
      <div style={{position: 'absolute', left: 105, bottom: 170, opacity: interpolate(frame, [55, 80], [0, 1], clamp), fontSize: 27, color: '#687985'}}>Or your API. Or a local model.</div>
      <div style={{position: 'absolute', left: 105, bottom: 72, fontSize: 17, color: '#7b858e'}}>Provider limits apply.</div>
      <div style={{position: 'absolute', right: 108, bottom: 80, color: '#6e7c87', fontSize: 17, letterSpacing: 2}}>NO HEYMATE SUBSCRIPTION</div>
    </AbsoluteFill>
  );
};
