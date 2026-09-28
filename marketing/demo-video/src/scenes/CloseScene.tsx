// Scene 7 — tagline and call to action.
import React from 'react';
import {Img, staticFile} from 'remotion';
import {COLORS, COPY} from '../config';
import {ease, riseStyle, springAt, useLayout, useTime} from '../components/motion';
import {Backdrop} from '../components/UI';

export const CloseScene: React.FC = () => {
  const {vertical} = useLayout();
  const {t, frame, fps} = useTime();

  const iconIn = springAt(frame, fps, 0.05, 'buddy');
  const lineIn = springAt(frame, fps, 0.2, 'gentle');
  const ctaIn = springAt(frame, fps, 0.6, 'buddy');
  const metaIn = springAt(frame, fps, 0.9, 'gentle');
  const urlIn = springAt(frame, fps, 1.1, 'gentle');
  const shine = ease(t, [1.5, 2.4], [-0.4, 1.4], (x) => x);

  return (
    <Backdrop>
      <div
        style={{
          position: 'absolute',
          inset: 0,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          textAlign: 'center',
        }}
      >
        <Img
          src={staticFile('icon.png')}
          style={{
            width: vertical ? 170 : 140,
            height: vertical ? 170 : 140,
            borderRadius: (vertical ? 170 : 140) * 0.225,
            boxShadow: '0 24px 60px rgba(0,0,0,0.7), 0 0 0 1px rgba(255,255,255,0.06)',
            opacity: Math.min(1, iconIn * 1.5),
            transform: `scale(${0.8 + 0.2 * iconIn})`,
          }}
        />
        <div
          style={{
            marginTop: vertical ? 56 : 44,
            fontSize: vertical ? 170 : 150,
            fontWeight: 600,
            letterSpacing: '-0.035em',
            lineHeight: 1,
            ...riseStyle(lineIn, 30, 12),
          }}
        >
          {COPY.close.line}
        </div>
        <div
          style={{
            marginTop: vertical ? 70 : 56,
            position: 'relative',
            overflow: 'hidden',
            padding: vertical ? '28px 58px' : '24px 52px',
            borderRadius: 999,
            background: COLORS.accent,
            color: '#fff',
            fontSize: vertical ? 40 : 34,
            fontWeight: 600,
            boxShadow: `0 16px 50px rgba(51,128,255,0.35), inset 0 1px 0 rgba(255,255,255,0.25)`,
            opacity: Math.min(1, ctaIn * 1.4),
            transform: `translateY(${(1 - ctaIn) * 24}px) scale(${0.92 + 0.08 * ctaIn})`,
          }}
        >
          <span style={{position: 'relative', zIndex: 1}}>{COPY.close.cta}</span>
          <div
            style={{
              position: 'absolute',
              top: 0,
              bottom: 0,
              width: '40%',
              left: `${shine * 100}%`,
              background: 'linear-gradient(100deg, rgba(255,255,255,0) 0%, rgba(255,255,255,0.28) 50%, rgba(255,255,255,0) 100%)',
            }}
          />
        </div>
        <div
          style={{
            marginTop: 34,
            fontSize: vertical ? 30 : 26,
            color: COLORS.textSecondary,
            whiteSpace: 'pre',
            ...riseStyle(metaIn, 12, 4),
          }}
        >
          {COPY.close.meta}
        </div>
        <div
          style={{
            marginTop: 14,
            fontSize: vertical ? 28 : 24,
            color: COLORS.textTertiary,
            letterSpacing: '0.01em',
            ...riseStyle(urlIn, 10, 4),
          }}
        >
          {COPY.close.url}
        </div>
      </div>
    </Backdrop>
  );
};
