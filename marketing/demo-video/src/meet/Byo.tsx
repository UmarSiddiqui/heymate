// 5 — Bring your own AI: plug in the plan you already pay for.
import React from 'react';
import {Img, staticFile} from 'remotion';
import {COLORS, FONTS} from '../config';
import {ease, riseStyle, springAt, useLayout, useTime} from '../components/motion';
import {Backdrop, Dot} from '../components/UI';

type Brain = {name: string; via: string; cmd: string};
const BRAINS: Brain[] = [
  {name: 'Claude', via: 'Your Claude plan, via Claude Code', cmd: 'claude auth login'},
  {name: 'ChatGPT', via: 'Your ChatGPT plan, via Codex', cmd: 'codex login'},
  {name: 'OpenCode', via: 'Free, local, or any provider', cmd: 'opencode auth login'},
];

const CARD_AT = [0.8, 0.95, 1.1];
const TYPE_AT = 1.3;
const CABLE_AT = 2.1;
const CONNECT_AT = 2.7;
const SWITCH_IN = 3.4;
const ACTIVE_AT = [3.6, 4.6, 5.6, 7.6];
const EXTRAS_AT = 6.3;
const EXTRAS = ['Your own API key', 'Local models', 'Apple Intelligence'];

export const MeetByo: React.FC = () => {
  const {vertical, width} = useLayout();
  const {t, frame, fps} = useTime();

  const L = vertical
    ? {titleTop: 150, hub: {x: width / 2, y: 700}, icon: 170, cardY: 950, cardW: 316, cardH: 300, gap: 18, switchY: 1340, extrasY: 1560}
    : {titleTop: 70, hub: {x: width / 2, y: 410}, icon: 130, cardY: 570, cardW: 430, cardH: 236, gap: 40, switchY: 846, extrasY: 976};
  const rowW = L.cardW * 3 + L.gap * 2;
  const cardX = (i: number) => (width - rowW) / 2 + i * (L.cardW + L.gap);

  const titleIn = springAt(frame, fps, 0.1, 'gentle');
  const subIn = springAt(frame, fps, 0.35, 'gentle');
  const hubIn = springAt(frame, fps, 0.5, 'buddy');
  const connected = BRAINS.map((_, i) => t >= CONNECT_AT + i * 0.1);
  const hubPulse = ease(t, [CONNECT_AT, CONNECT_AT + 0.25]) * (1 - ease(t, [CONNECT_AT + 0.4, CONNECT_AT + 1.2]));
  const switchIn = springAt(frame, fps, SWITCH_IN, 'buddy');
  const extrasLabelIn = springAt(frame, fps, EXTRAS_AT, 'gentle');

  // Which brain is active; the switcher highlight slides between them.
  const step = ACTIVE_AT.filter((at) => t >= at).length - 1;
  const active = step < 0 ? -1 : step % BRAINS.length;
  const segW = vertical ? 250 : 190;
  const from = step <= 0 ? 0 : (step - 1) % BRAINS.length;
  const slide = step <= 0 ? 1 : springAt(frame, fps, ACTIVE_AT[step], 'control');
  const segX = (from + (Math.max(0, active) - from) * slide) * segW;

  return (
    <Backdrop>
      {/* Title */}
      <div style={{position: 'absolute', left: 60, right: 60, top: L.titleTop, textAlign: 'center'}}>
        <div style={{fontSize: vertical ? 96 : 84, fontWeight: 600, letterSpacing: '-0.035em', lineHeight: 1.04, ...riseStyle(titleIn, 28, 10)}}>
          Bring your own <span style={{color: COLORS.accentText}}>AI.</span>
        </div>
        <div style={{marginTop: 20, fontSize: vertical ? 36 : 30, color: COLORS.textSecondary, lineHeight: 1.35, whiteSpace: 'pre-line', ...riseStyle(subIn, 18, 6)}}>
          {vertical ? 'Sign in with the plan you already have.\nNo new subscription.' : 'Sign in with the plan you already have. No new subscription.'}
        </div>
      </div>

      {/* Cables */}
      <svg style={{position: 'absolute', inset: 0, width: '100%', height: '100%', overflow: 'visible'}}>
        {BRAINS.map((_, i) => {
          const cx = cardX(i) + L.cardW / 2;
          const top = L.cardY;
          const hubBottom = L.hub.y + L.icon / 2 + 6;
          const midY = (top + hubBottom) / 2;
          const d = `M ${cx} ${top} C ${cx} ${midY}, ${L.hub.x} ${midY}, ${L.hub.x} ${hubBottom}`;
          const draw = ease(t, [CABLE_AT + i * 0.1, CABLE_AT + 0.5 + i * 0.1]);
          const isActive = active === i;
          // A spark rides each cable while its brain is active.
          const flow = ((t * 0.9) % 1);
          return (
            <g key={i}>
              <path d={d} fill="none" stroke={isActive ? COLORS.accent : connected[i] ? COLORS.borderStrong : COLORS.surface4} strokeWidth={isActive ? 4 : 3} strokeLinecap="round" pathLength={1} strokeDasharray="1 1" strokeDashoffset={1 - draw} />
              {isActive ? (
                <path d={d} fill="none" stroke="#FFFFFF" strokeWidth={5} strokeLinecap="round" pathLength={1} strokeDasharray="0.06 0.94" strokeDashoffset={-flow + 0.06} opacity={0.9} />
              ) : null}
            </g>
          );
        })}
      </svg>

      {/* Hub */}
      <div
        style={{
          position: 'absolute',
          left: L.hub.x - L.icon / 2,
          top: L.hub.y - L.icon / 2,
          width: L.icon,
          height: L.icon,
          opacity: Math.min(1, hubIn * 1.5),
          transform: `scale(${(0.7 + 0.3 * hubIn) * (1 + 0.08 * hubPulse)})`,
        }}
      >
        <div style={{position: 'absolute', inset: -30, borderRadius: '50%', background: `radial-gradient(circle, rgba(51,128,255,${0.18 + 0.3 * hubPulse}) 0%, rgba(51,128,255,0) 70%)`}} />
        <Img src={staticFile('icon.png')} style={{position: 'relative', width: L.icon, height: L.icon, borderRadius: L.icon * 0.225, boxShadow: '0 24px 60px rgba(0,0,0,0.7), 0 0 0 1px rgba(255,255,255,0.06)'}} />
      </div>

      {/* Brain cards */}
      {BRAINS.map((b, i) => {
        const p = springAt(frame, fps, CARD_AT[i], 'buddy');
        const typed = Math.ceil(b.cmd.length * ease(t, [TYPE_AT + i * 0.12, TYPE_AT + 0.7 + i * 0.12], [0, 1], (x) => x));
        const isActive = active === i;
        const dim = active >= 0 && !isActive ? 0.55 : 1;
        return (
          <div
            key={b.name}
            style={{
              position: 'absolute',
              left: cardX(i),
              top: L.cardY,
              width: L.cardW,
              height: L.cardH,
              boxSizing: 'border-box',
              padding: vertical ? '26px 22px' : '24px 26px',
              borderRadius: 22,
              background: COLORS.surface1,
              border: `2px solid ${isActive ? COLORS.accent : COLORS.borderSubtle}`,
              boxShadow: isActive ? `0 0 40px rgba(51,128,255,0.35), 0 30px 60px rgba(0,0,0,0.6)` : '0 30px 60px rgba(0,0,0,0.6)',
              opacity: Math.min(1, p * 1.5) * dim,
              transform: `translateY(${(1 - p) * 60}px) scale(${isActive ? 1.03 : 1})`,
              display: 'flex',
              flexDirection: 'column',
            }}
          >
            <div style={{fontSize: vertical ? 40 : 38, fontWeight: 700, letterSpacing: '-0.02em'}}>{b.name}</div>
            <div style={{marginTop: 6, fontSize: vertical ? 22 : 19, color: COLORS.textSecondary, lineHeight: 1.3}}>{b.via}</div>
            <div
              style={{
                marginTop: 'auto',
                padding: '10px 14px',
                borderRadius: 10,
                background: COLORS.background,
                border: `1px solid ${COLORS.borderSubtle}`,
                fontFamily: FONTS.mono,
                fontSize: vertical ? 19 : 18,
                color: COLORS.codeText,
                whiteSpace: 'nowrap',
                overflow: 'hidden',
              }}
            >
              <span style={{color: COLORS.textTertiary}}>$ </span>
              {b.cmd.slice(0, typed)}
            </div>
            <div style={{marginTop: 14, display: 'flex', alignItems: 'center', gap: 10, fontSize: vertical ? 22 : 19, fontWeight: 600, color: connected[i] ? COLORS.success : COLORS.textTertiary}}>
              <Dot color={connected[i] ? COLORS.success : COLORS.surface4} size={11} glow={connected[i]} />
              {connected[i] ? 'Signed in' : 'Not connected'}
            </div>
          </div>
        );
      })}

      {/* Brain switcher */}
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: L.switchY,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          gap: 18,
          opacity: Math.min(1, switchIn * 1.5),
          transform: `translateY(${(1 - switchIn) * 30}px)`,
        }}
      >
        <div style={{position: 'relative', display: 'flex', padding: 6, borderRadius: 999, background: COLORS.surface2, border: `1px solid ${COLORS.borderSubtle}`}}>
          <div style={{position: 'absolute', left: 6 + segX, top: 6, width: segW, bottom: 6, borderRadius: 999, background: COLORS.accent, opacity: active >= 0 ? 1 : 0}} />
          {BRAINS.map((b, i) => (
            <div key={b.name} style={{position: 'relative', width: segW, textAlign: 'center', padding: vertical ? '14px 0' : '11px 0', fontSize: vertical ? 28 : 22, fontWeight: 600, color: active === i ? '#FFFFFF' : COLORS.textSecondary}}>
              {b.name}
            </div>
          ))}
        </div>
        <div style={{fontSize: vertical ? 28 : 22, color: COLORS.textTertiary}}>Switch brains anytime. HeyMate itself is free.</div>
      </div>

      {/* Or skip the subscription entirely */}
      <div
        style={{
          position: 'absolute',
          left: 40,
          right: 40,
          top: L.extrasY,
          display: 'flex',
          flexDirection: vertical ? 'column' : 'row',
          alignItems: 'center',
          justifyContent: 'center',
          gap: vertical ? 18 : 14,
        }}
      >
        <div style={{fontSize: vertical ? 30 : 24, fontWeight: 600, color: COLORS.textSecondary, marginRight: vertical ? 0 : 6, ...riseStyle(extrasLabelIn, 14, 4)}}>
          No subscription? Use
        </div>
        <div style={{display: 'flex', gap: vertical ? 12 : 14, flexWrap: 'wrap', justifyContent: 'center'}}>
          {EXTRAS.map((label, i) => {
            const p = springAt(frame, fps, EXTRAS_AT + 0.15 + i * 0.12, 'buddy');
            return (
              <div
                key={label}
                style={{
                  padding: vertical ? '12px 22px' : '10px 20px',
                  borderRadius: 999,
                  background: COLORS.surface2,
                  border: `1.5px solid ${COLORS.borderStrong}`,
                  fontSize: vertical ? 28 : 22,
                  fontWeight: 600,
                  color: COLORS.textPrimary,
                  opacity: Math.min(1, p * 1.5),
                  transform: `scale(${0.6 + 0.4 * p})`,
                }}
              >
                {label}
              </div>
            );
          })}
        </div>
      </div>
    </Backdrop>
  );
};
