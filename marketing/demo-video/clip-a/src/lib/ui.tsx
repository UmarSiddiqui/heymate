import React from 'react';
import {AbsoluteFill, Easing, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import type {Keys} from './types';

export const COLORS = {
  bg: '#0A0A0A',
  surface: '#121213',
  surface2: '#1A1A1C',
  surface3: '#232325',
  border: '#2D2D30',
  borderStrong: '#3E3E42',
  text: '#F5F5F7',
  text2: '#B3B3BA',
  text3: '#84848C',
  accent: '#3380FF', // HeyMate "Signal", the same blue as its pointer
  accentText: '#6FA5FF',
};
export const FONT = '"Avenir Next", Avenir, -apple-system, "Helvetica Neue", sans-serif';
export const MONO = '"SF Mono", Menlo, Monaco, monospace';

export const Chip: React.FC<{children: React.ReactNode; u: number; style?: React.CSSProperties}> = ({children, u, style}) => (
  <div
    style={{
      position: 'absolute',
      padding: `${7 * u}px ${13 * u}px`,
      borderRadius: 999,
      background: 'rgba(10,10,10,0.84)',
      border: `1px solid ${COLORS.border}`,
      color: COLORS.text2,
      fontFamily: FONT,
      fontSize: 15 * u,
      fontWeight: 600,
      letterSpacing: 0.3 * u,
      display: 'flex',
      alignItems: 'center',
      gap: 8 * u,
      whiteSpace: 'nowrap',
      ...style,
    }}
  >
    {children}
  </div>
);

/** The playful label beside HeyMate's cursor. */
export const CalloutBubble: React.FC<{
  text: string;
  px: number;
  py: number;
  place: 'above' | 'left' | 'below' | 'aboveLeft';
  op: number;
  u: number;
  frameW: number;
  frameH: number;
}> = ({text, px, py, place, op, u, frameW, frameH}) => {
  const fs = 30 * u;
  const estW = text.length * fs * 0.55 + 56 * u;
  const h = fs * 1.25 + 26 * u;
  let left = px - 18 * u;
  let top = py - h - 30 * u;
  if (place === 'aboveLeft') left = px - estW + 24 * u;
  if (place === 'left') {
    left = px - estW - 30 * u;
    top = py - h / 2 + 8 * u;
  }
  if (place === 'below') top = py + 78 * u;
  const m = 24 * u;
  left = Math.min(frameW - estW - m, Math.max(m, left));
  top = Math.min(frameH - h - m, Math.max(m, top));
  const pop = interpolate(op, [0, 1], [0.86, 1]);
  return (
    <div
      style={{
        position: 'absolute',
        left,
        top,
        opacity: op,
        transform: `scale(${pop}) translateY(${(1 - op) * 8 * u}px)`,
        transformOrigin: place === 'below' ? 'top left' : 'bottom left',
        display: 'flex',
        alignItems: 'center',
        gap: 12 * u,
        padding: `${12 * u}px ${20 * u}px`,
        borderRadius: 16 * u,
        background: 'rgba(10,10,10,0.92)',
        border: `${1.5 * u}px solid rgba(51,128,255,0.75)`,
        boxShadow: `0 ${14 * u}px ${36 * u}px rgba(0,0,0,0.35), 0 0 ${18 * u}px rgba(51,128,255,0.18)`,
        color: COLORS.text,
        fontFamily: FONT,
        fontSize: fs,
        fontWeight: 600,
        letterSpacing: -0.3 * u,
        whiteSpace: 'nowrap',
      }}
    >
      <span style={{width: 10 * u, height: 10 * u, borderRadius: 10 * u, background: COLORS.accent, flexShrink: 0}} />
      {text}
    </div>
  );
};

const Keycap: React.FC<{glyph: string; label: string; pressed: number; u: number}> = ({glyph, label, pressed, u}) => (
  <div
    style={{
      width: 64 * u,
      height: 64 * u,
      borderRadius: 13 * u,
      background: `linear-gradient(180deg, ${COLORS.surface3}, ${COLORS.surface2})`,
      border: `${1.5 * u}px solid ${pressed > 0.5 ? COLORS.accent : COLORS.borderStrong}`,
      boxShadow: `0 ${(6 - pressed * 4) * u}px 0 #050505${pressed > 0.01 ? `, 0 0 ${20 * pressed * u}px rgba(51,128,255,${0.5 * pressed})` : ''}`,
      transform: `translateY(${pressed * 4 * u}px)`,
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 2 * u,
      color: COLORS.text,
      fontFamily: FONT,
    }}
  >
    <div style={{fontSize: 26 * u, lineHeight: 1}}>{glyph}</div>
    <div style={{fontSize: 10 * u, fontWeight: 600, color: COLORS.text2}}>{label}</div>
  </div>
);

export const Keycaps: React.FC<{raw: number; keys: Keys[]; u: number; vertical: boolean}> = ({raw, keys, u, vertical}) => {
  const k = keys.find((kk) => raw > kk.down - 0.5 && raw < kk.up + 0.7);
  if (!k) return null;
  const show = interpolate(raw, [k.down - 0.4, k.down - 0.15, k.up + 0.3, k.up + 0.6], [0, 1, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const pressed = interpolate(raw, [k.down, k.down + 0.1, k.up, k.up + 0.1], [0, 1, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const holding = raw >= k.down && raw <= k.up;
  return (
    <div
      style={{
        position: 'absolute',
        left: (vertical ? 40 : 40) * u,
        bottom: (vertical ? 300 : 40) * u,
        opacity: show,
        transform: `translateY(${(1 - show) * 12 * u}px)`,
        display: 'flex',
        alignItems: 'center',
        gap: 10 * u,
        padding: `${12 * u}px ${16 * u}px ${15 * u}px`,
        borderRadius: 20 * u,
        background: 'rgba(10,10,10,0.86)',
        border: `1px solid ${COLORS.border}`,
      }}
    >
      <Keycap glyph="⌃" label="control" pressed={pressed} u={u} />
      <Keycap glyph="⌥" label="option" pressed={pressed} u={u} />
      <div style={{fontFamily: FONT, color: COLORS.text2, fontSize: 15 * u, fontWeight: 600, marginLeft: 4 * u, width: 84 * u}}>{holding ? 'Hold to talk' : 'Released'}</div>
    </div>
  );
};

/** The spoken question, small, so the moment reads with the sound off. */
export const AskChip: React.FC<{text: string; op: number; u: number; vertical: boolean}> = ({text, op, u, vertical}) => (
  <AbsoluteFill style={{justifyContent: 'flex-end', alignItems: 'center', paddingBottom: (vertical ? 180 : 44) * u, pointerEvents: 'none'}}>
    <div
      style={{
        opacity: op,
        transform: `translateY(${(1 - op) * 8 * u}px)`,
        maxWidth: vertical ? 960 * u : 1300 * u,
        display: 'flex',
        alignItems: 'center',
        gap: 14 * u,
        padding: `${13 * u}px ${22 * u}px`,
        borderRadius: 18 * u,
        background: 'rgba(10,10,10,0.9)',
        border: `1px solid ${COLORS.border}`,
        fontFamily: FONT,
      }}
    >
      <div style={{flexShrink: 0, fontSize: 12 * u, fontWeight: 700, letterSpacing: 1.4 * u, textTransform: 'uppercase', color: COLORS.text3}}>Asked</div>
      <div style={{fontSize: 27 * u, fontWeight: 500, color: COLORS.text, lineHeight: 1.25}}>“{text}”</div>
    </div>
  </AbsoluteFill>
);

export const TITLE_SECONDS = 1.75;
export const END_SECONDS = 3;

export const Title: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps, width, height} = useVideoConfig();
  const t = frame / fps;
  const narrow = width < 1500;
  const out = interpolate(t, [TITLE_SECONDS - 0.4, TITLE_SECONDS], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.bezier(0.4, 0, 0.2, 1)});
  const rise = spring({frame, fps, config: {damping: 200, mass: 0.7}, durationInFrames: 40});
  const line = interpolate(frame, [8, 46], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic)});
  const u = Math.min(width, height) / 1080;
  return (
    <AbsoluteFill style={{backgroundColor: COLORS.bg, opacity: out, justifyContent: 'center', alignItems: 'center'}}>
      <div
        style={{
          fontFamily: FONT,
          color: COLORS.text,
          fontSize: (narrow ? (height > width ? 92 : 70) : 76) * u,
          fontWeight: 600,
          letterSpacing: -1.6 * u,
          textAlign: 'center',
          lineHeight: 1.08,
          opacity: rise,
          transform: `translateY(${(1 - rise) * 22 * u}px)`,
        }}
      >
        {narrow ? (
          <>
            Ask about anything
            <br />
            on your screen.
          </>
        ) : (
          'Ask about anything on your screen.'
        )}
      </div>
      <div style={{marginTop: 30 * u, height: 3 * u, width: 120 * line * u, borderRadius: 3, background: COLORS.accent}} />
    </AbsoluteFill>
  );
};

export const EndCard: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps, width, height} = useVideoConfig();
  const inOp = interpolate(frame, [0, 22], [0, 1], {extrapolateRight: 'clamp', easing: Easing.bezier(0.33, 0, 0.2, 1)});
  const s = (d: number) => spring({frame: frame - d, fps, config: {damping: 200, mass: 0.6}, durationInFrames: 36});
  const item = (d: number): React.CSSProperties => ({opacity: s(d), transform: `translateY(${(1 - s(d)) * 16}px)`});
  const k = (Math.min(width, height) / 1080) * (width < 1500 ? 0.9 : 1);
  const vertical = height > width;
  return (
    <AbsoluteFill style={{backgroundColor: COLORS.bg, opacity: inOp, justifyContent: 'center', alignItems: 'center', fontFamily: FONT, textAlign: 'center'}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 26 * k, ...item(6)}}>
        <Img src={staticFile('icon.png')} style={{width: 112 * k, height: 112 * k, borderRadius: 26 * k}} />
        <div style={{color: COLORS.text, fontSize: 84 * k, fontWeight: 600, letterSpacing: -2 * k}}>HeyMate</div>
      </div>
      <div style={{marginTop: 22 * k, color: COLORS.text2, fontSize: 32 * k, fontWeight: 500, display: 'flex', flexDirection: vertical ? 'column' : 'row', gap: 10 * k, alignItems: 'center', ...item(14)}}>
        <span>Free and open source</span>
        {vertical ? null : <span style={{color: COLORS.text3}}>·</span>}
        <span style={{color: COLORS.accentText}}>getheymate.vercel.app</span>
      </div>
      <div
        style={{
          marginTop: 40 * k,
          padding: `${16 * k}px ${26 * k}px`,
          borderRadius: 14 * k,
          background: COLORS.surface,
          border: `1px solid ${COLORS.border}`,
          color: COLORS.text,
          fontFamily: MONO,
          fontSize: (vertical ? 24 : 26) * k,
          ...item(22),
        }}
      >
        <span style={{color: COLORS.text3}}>$ </span>brew install umarsiddiqui/tap/heymate
      </div>
      <div style={{marginTop: 34 * k, color: COLORS.text3, fontSize: 20 * k, fontWeight: 500, ...item(30)}}>Hold ⌃⌥ and ask · macOS</div>
    </AbsoluteFill>
  );
};
