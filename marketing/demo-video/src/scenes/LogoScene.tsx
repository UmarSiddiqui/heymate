// Scene 2 — logo reveal. The only place the icon's violet glow appears.
import React from 'react';
import {Img, staticFile} from 'remotion';
import {COLORS, COPY} from '../config';
import {ease, riseStyle, springAt, useLayout, useTime} from '../components/motion';
import {Backdrop} from '../components/UI';

export const LogoScene: React.FC = () => {
  const {vertical} = useLayout();
  const {t, frame, fps} = useTime();

  const iconIn = springAt(frame, fps, 0.1, 'buddy');
  const bloom = ease(t, [0.1, 0.9], [0, 1]) * (1 - ease(t, [1.2, 3.2], [0, 0.45]));
  const wordIn = springAt(frame, fps, 0.55, 'gentle');
  const tagIn = springAt(frame, fps, 1.05, 'gentle');
  const iconSize = vertical ? 300 : 250;

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
        }}
      >
        <div style={{position: 'relative', width: iconSize, height: iconSize}}>
          <div
            style={{
              position: 'absolute',
              left: '50%',
              top: '50%',
              width: iconSize * 3.2,
              height: iconSize * 3.2,
              transform: `translate(-50%, -50%) scale(${0.7 + 0.3 * bloom})`,
              background: `radial-gradient(circle, ${COLORS.iconGlow}66 0%, ${COLORS.iconGlow}22 30%, rgba(94,84,255,0) 62%)`,
              opacity: bloom,
            }}
          />
          <Img
            src={staticFile('icon.png')}
            style={{
              position: 'relative',
              width: iconSize,
              height: iconSize,
              borderRadius: iconSize * 0.225,
              opacity: Math.min(1, iconIn * 1.5),
              transform: `scale(${0.62 + 0.38 * iconIn}) translateY(${(1 - iconIn) * 30}px)`,
              boxShadow: `0 30px 80px rgba(0,0,0,0.7), 0 0 0 1px rgba(255,255,255,0.06)`,
            }}
          />
        </div>
        <div
          style={{
            marginTop: vertical ? 70 : 54,
            fontSize: vertical ? 132 : 120,
            fontWeight: 600,
            letterSpacing: `${0.3 * (1 - wordIn) - 0.03}em`,
            lineHeight: 1,
            opacity: Math.min(1, wordIn * 1.3),
            filter: `blur(${(1 - wordIn) * 10}px)`,
          }}
        >
          {COPY.logo.name}
        </div>
        <div
          style={{
            marginTop: 26,
            fontSize: vertical ? 40 : 36,
            color: COLORS.textSecondary,
            ...riseStyle(tagIn, 16, 6),
          }}
        >
          {COPY.logo.tagline}
        </div>
      </div>
    </Backdrop>
  );
};
