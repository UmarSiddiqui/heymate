// 7 — "Say hey." and the download.
import React from 'react';
import {Img, staticFile} from 'remotion';
import {COLORS} from '../config';
import {ease, riseStyle, springAt, useLayout, useTime} from '../components/motion';
import {Backdrop} from '../components/UI';
import {Buddy} from './kit';

export const MeetClose: React.FC = () => {
  const {vertical, width, height} = useLayout();
  const {t, frame, fps} = useTime();

  const iconIn = springAt(frame, fps, 0.05, 'buddy');
  const lineIn = springAt(frame, fps, 0.2, 'gentle');
  const ctaIn = springAt(frame, fps, 0.6, 'buddy');
  const metaIn = springAt(frame, fps, 0.9, 'gentle');
  const urlIn = springAt(frame, fps, 1.1, 'gentle');
  const shine = ease(t, [1.5, 2.4], [-0.4, 1.4], (x) => x);
  const icon = vertical ? 170 : 140;
  // The buddy parks beside the button and gives one last wave.
  const park = springAt(frame, fps, 1.3, 'gentle');
  const buddyTo = vertical ? {x: width / 2 + 290, y: height / 2 + 150} : {x: width / 2 + 290, y: height / 2 + 120};
  const bx = buddyTo.x + (1 - park) * 260;
  const by = buddyTo.y - (1 - park) * 220;

  return (
    <Backdrop>
      <div style={{position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', textAlign: 'center'}}>
        <Img
          src={staticFile('icon.png')}
          style={{
            width: icon,
            height: icon,
            borderRadius: icon * 0.225,
            boxShadow: '0 24px 60px rgba(0,0,0,0.7), 0 0 0 1px rgba(255,255,255,0.06)',
            opacity: Math.min(1, iconIn * 1.5),
            transform: `scale(${0.8 + 0.2 * iconIn})`,
          }}
        />
        <div style={{marginTop: vertical ? 56 : 44, fontSize: vertical ? 170 : 150, fontWeight: 600, letterSpacing: '-0.035em', lineHeight: 1, ...riseStyle(lineIn, 30, 12)}}>
          Say hey.
        </div>
        <div
          style={{
            marginTop: vertical ? 70 : 56,
            position: 'relative',
            overflow: 'hidden',
            padding: vertical ? '28px 58px' : '24px 52px',
            borderRadius: 999,
            background: COLORS.accent,
            color: '#FFFFFF',
            fontSize: vertical ? 44 : 38,
            fontWeight: 600,
            boxShadow: '0 18px 50px rgba(51,128,255,0.35)',
            opacity: Math.min(1, ctaIn * 1.5),
            transform: `scale(${0.85 + 0.15 * ctaIn})`,
          }}
        >
          Download free for Mac
          <div
            style={{
              position: 'absolute',
              top: 0,
              bottom: 0,
              width: '40%',
              left: `${shine * 100}%`,
              background: 'linear-gradient(90deg, rgba(255,255,255,0), rgba(255,255,255,0.35), rgba(255,255,255,0))',
              transform: 'skewX(-20deg)',
            }}
          />
        </div>
        <div style={{marginTop: vertical ? 44 : 36, fontSize: vertical ? 32 : 28, color: COLORS.textSecondary, whiteSpace: 'pre-line', lineHeight: 1.4, ...riseStyle(metaIn, 16, 4)}}>
          {vertical ? 'Free & open source · macOS 14.2+\nWorks with Claude, ChatGPT & OpenCode' : 'Free & open source  ·  macOS 14.2+  ·  Works with Claude, ChatGPT & OpenCode'}
        </div>
        <div style={{marginTop: 16, fontSize: vertical ? 32 : 28, fontWeight: 600, color: COLORS.accentText, ...riseStyle(urlIn, 16, 4)}}>
          getheymate.vercel.app
        </div>
      </div>
      <Buddy x={bx} y={by} size={vertical ? 60 : 52} opacity={ease(t, [1.25, 1.45])} wave={ease(t, [1.9, 2.1]) * (1 - ease(t, [3.0, 3.4]))} tilt={(1 - Math.min(1, park)) * -25} />
    </Backdrop>
  );
};
