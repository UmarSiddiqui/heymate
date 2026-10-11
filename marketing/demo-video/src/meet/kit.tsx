// Shared pieces for the "Meet HeyMate" film: the buddy as a character,
// speech bubbles, kinetic words, and the small illustration tag.
import React from 'react';
import {COLORS, FONTS} from '../config';
import {BuddyCursor} from '../components/Icons';
import {riseStyle, springAt, useLayout, useTime} from '../components/motion';

/** The blue cursor buddy, with an idle bob and an optional wave wiggle. */
export const Buddy: React.FC<{
  x: number;
  y: number;
  size?: number;
  opacity?: number;
  /** 0 → 1, how hard it waves (rotational wiggle). */
  wave?: number;
  tilt?: number;
}> = ({x, y, size = 40, opacity = 1, wave = 0, tilt = 0}) => {
  const {t} = useTime();
  const bob = Math.sin(t * 3.2) * 3;
  const wiggle = Math.sin(t * 16) * 16 * wave;
  return (
    <div
      style={{
        position: 'absolute',
        left: x - size * 0.12,
        top: y - size * 0.1 + bob,
        opacity,
        transform: `rotate(${tilt + wiggle}deg)`,
        transformOrigin: '12% 10%',
        zIndex: 20,
      }}
    >
      <BuddyCursor size={size} color={COLORS.accent} />
    </div>
  );
};

/** Buddy's reply bubble. Types `text` out as `p` goes 0 → 1. */
export const Bubble: React.FC<{
  x: number;
  y: number;
  text: string;
  /** 0 → 1 entrance spring. */
  pop: number;
  /** 0 → 1 typing progress. */
  typed?: number;
  label?: string;
  width?: number;
  size?: number;
  tone?: 'buddy' | 'win';
}> = ({x, y, text, pop, typed = 1, label, width = 330, size = 19, tone = 'buddy'}) => {
  const chars = Math.ceil(text.length * Math.min(1, typed));
  const border = tone === 'win' ? COLORS.success : COLORS.borderStrong;
  return (
    <div
      style={{
        position: 'absolute',
        left: x,
        top: y,
        width,
        padding: `${size * 0.7}px ${size * 0.85}px`,
        borderRadius: size * 0.9,
        borderTopLeftRadius: 6,
        background: 'rgba(26,26,28,0.96)',
        border: `1.5px solid ${border}`,
        boxShadow: '0 18px 44px rgba(0,0,0,0.6)',
        fontSize: size,
        lineHeight: 1.36,
        color: COLORS.textPrimary,
        opacity: Math.min(1, pop * 1.6),
        transform: `scale(${0.7 + 0.3 * pop})`,
        transformOrigin: '0 0',
        zIndex: 21,
      }}
    >
      {label ? (
        <div
          style={{
            fontSize: size * 0.68,
            fontWeight: 700,
            letterSpacing: '0.06em',
            textTransform: 'uppercase',
            color: tone === 'win' ? COLORS.success : COLORS.accentText,
            marginBottom: size * 0.25,
          }}
        >
          {label}
        </div>
      ) : null}
      <span>{text.slice(0, chars)}</span>
      <span style={{opacity: 0}}>{text.slice(chars)}</span>
    </div>
  );
};

/** The user's own question, as a right-aligned chat bubble. */
export const UserBubble: React.FC<{text: string; pop: number; size?: number; style?: React.CSSProperties}> = ({
  text,
  pop,
  size = 19,
  style,
}) => (
  <div
    style={{
      alignSelf: 'flex-end',
      maxWidth: '86%',
      padding: `${size * 0.6}px ${size * 0.85}px`,
      borderRadius: size * 0.9,
      borderBottomRightRadius: 6,
      background: COLORS.userBubble,
      color: COLORS.textPrimary,
      fontSize: size,
      lineHeight: 1.32,
      fontWeight: 500,
      opacity: Math.min(1, pop * 1.6),
      transform: `translateY(${(1 - pop) * 14}px) scale(${0.85 + 0.15 * pop})`,
      transformOrigin: '100% 100%',
      ...style,
    }}
  >
    {text}
  </div>
);

/** Words that spring in one after another. `accent` words get the accent color. */
export const PopWords: React.FC<{
  text: string;
  at: number;
  step?: number;
  size: number;
  accent?: string[];
  color?: string;
  weight?: number;
  style?: React.CSSProperties;
}> = ({text, at, step = 0.09, size, accent = [], color = COLORS.textPrimary, weight = 600, style}) => {
  const {frame, fps} = useTime();
  const lines = text.split('\n');
  let index = 0;
  return (
    <div style={{fontSize: size, fontWeight: weight, letterSpacing: '-0.03em', lineHeight: 1.08, color, ...style}}>
      {lines.map((line, li) => (
        <div key={li}>
          {line.split(' ').map((word, wi) => {
            const p = springAt(frame, fps, at + step * index++, 'buddy');
            const isAccent = accent.includes(word.replace(/[.,!?]/g, ''));
            return (
              <span
                key={wi}
                style={{
                  display: 'inline-block',
                  marginRight: '0.24em',
                  color: isAccent ? COLORS.accentText : undefined,
                  ...riseStyle(p, size * 0.35, 8),
                }}
              >
                {word}
              </span>
            );
          })}
        </div>
      ))}
    </div>
  );
};

/** Small, honest corner tag for recreated UI. */
export const IllustratedTag: React.FC = () => {
  const {vertical} = useLayout();
  return (
    <div
      style={{
        position: 'absolute',
        right: vertical ? 40 : 48,
        bottom: vertical ? 48 : 36,
        fontFamily: FONTS.ui,
        fontSize: vertical ? 20 : 16,
        fontWeight: 600,
        letterSpacing: '0.08em',
        textTransform: 'uppercase',
        color: COLORS.textTertiary,
        opacity: 0.75,
      }}
    >
      Illustrated UI
    </div>
  );
};

/** Little burst of accent sparks, centered on (x, y), triggered at `at` seconds. */
export const Sparks: React.FC<{x: number; y: number; at: number; count?: number; radius?: number}> = ({
  x,
  y,
  at,
  count = 10,
  radius = 80,
}) => {
  const {t} = useTime();
  const p = Math.max(0, Math.min(1, (t - at) / 0.7));
  if (p <= 0 || p >= 1) return null;
  const colors = [COLORS.accent, COLORS.success, COLORS.warning, COLORS.textPrimary];
  return (
    <>
      {Array.from({length: count}).map((_, i) => {
        const a = (i / count) * Math.PI * 2 + 0.3;
        const r = radius * (1 - Math.pow(1 - p, 3));
        return (
          <div
            key={i}
            style={{
              position: 'absolute',
              left: x + Math.cos(a) * r - 5,
              top: y + Math.sin(a) * r - 5,
              width: 10,
              height: 10,
              borderRadius: i % 2 ? 10 : 2,
              rotate: `${p * 180}deg`,
              background: colors[i % colors.length],
              opacity: 1 - p,
              zIndex: 22,
            }}
          />
        );
      })}
    </>
  );
};

/** Point along a gentle arc from a to b; p is 0 → 1 (springs may overshoot). */
export const arcPoint = (a: {x: number; y: number}, b: {x: number; y: number}, p: number, lift = 80) => {
  const arc = Math.sin(Math.min(1, Math.max(0, p)) * Math.PI) * lift;
  return {x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p - arc};
};
