// Static share card: Open Graph (1200x630) and GitHub social preview (1280x640).
import React from 'react';
import {Img, staticFile, useVideoConfig} from 'remotion';
import {COLORS, FONTS} from './config';

export const SocialCard: React.FC = () => {
  const {width, height} = useVideoConfig();
  const u = height / 630;
  return (
    <div
      style={{
        width,
        height,
        position: 'relative',
        overflow: 'hidden',
        background: `radial-gradient(ellipse 60% 80% at 78% 50%, rgba(51,128,255,0.16), rgba(10,10,10,0) 70%), ${COLORS.background}`,
        fontFamily: FONTS.ui,
        color: COLORS.textPrimary,
      }}
    >
      <Img
        src={staticFile('vision-still.jpg')}
        style={{
          position: 'absolute',
          right: -110 * u,
          top: 60 * u,
          height: 520 * u,
          borderRadius: 24 * u,
          boxShadow: '0 40px 100px rgba(0,0,0,0.7)',
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          bottom: 0,
          width: 640 * u,
          background: `linear-gradient(90deg, ${COLORS.background} 70%, rgba(10,10,10,0))`,
        }}
      />
      <div style={{position: 'absolute', left: 72 * u, top: 0, bottom: 0, width: 520 * u, display: 'flex', flexDirection: 'column', justifyContent: 'center'}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 18 * u}}>
          <Img src={staticFile('icon.png')} style={{width: 76 * u, height: 76 * u, borderRadius: 76 * u * 0.225}} />
          <div style={{fontSize: 52 * u, fontWeight: 600, letterSpacing: '-0.02em'}}>HeyMate</div>
        </div>
        <div style={{marginTop: 34 * u, fontSize: 50 * u, fontWeight: 600, lineHeight: 1.08, letterSpacing: '-0.025em'}}>
          The AI buddy that lives in your Mac&apos;s notch.
        </div>
        <div style={{marginTop: 20 * u, fontSize: 23 * u, lineHeight: 1.4, color: COLORS.textSecondary}}>
          Sees your screen, answers out loud, and runs Claude Code or Codex agents on the subscription you already have.
        </div>
        <div style={{marginTop: 30 * u, display: 'flex', gap: 10 * u}}>
          {['Free', 'Open source', 'macOS'].map((t) => (
            <div
              key={t}
              style={{
                padding: `${8 * u}px ${16 * u}px`,
                borderRadius: 999,
                border: `1px solid ${COLORS.borderStrong}`,
                background: COLORS.surface1,
                fontSize: 18 * u,
                fontWeight: 600,
                color: COLORS.textSecondary,
              }}
            >
              {t}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};
