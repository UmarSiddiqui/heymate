// 2 — The notch opens and the buddy pops out to say hi.
import React from 'react';
import {Img, staticFile} from 'remotion';
import {COLORS} from '../config';
import {ease, riseStyle, springAt, useLayout, useTime} from '../components/motion';
import {Backdrop, Dot, NotchShell} from '../components/UI';
import {arcPoint, Bubble, Buddy} from './kit';

const BAR_H = 44;

export const MeetHello: React.FC = () => {
  const {vertical, width, height} = useLayout();
  const {t, frame, fps} = useTime();

  const open = springAt(frame, fps, 0.25, 'control');
  const notchW = 220 + 160 * open;
  const drop = springAt(frame, fps, 0.65, 'gentle');
  const from = {x: width / 2, y: BAR_H / 2};
  const to = vertical ? {x: 250, y: 560} : {x: 640, y: 300};
  const pos = arcPoint(from, to, drop, -60);
  const wave = ease(t, [1.2, 1.4]) * (1 - ease(t, [2.4, 2.8]));
  const bubble = springAt(frame, fps, 1.3, 'buddy');
  const typed = ease(t, [1.35, 2.0], [0, 1], (x) => x);

  const iconIn = springAt(frame, fps, 1.9, 'buddy');
  const nameIn = springAt(frame, fps, 2.05, 'gentle');
  const tagIn = springAt(frame, fps, 2.35, 'gentle');
  const iconSize = vertical ? 150 : 128;

  return (
    <Backdrop>
      {/* Menu bar with the notch */}
      <div style={{position: 'absolute', left: 0, right: 0, top: 0, height: BAR_H, background: 'rgba(255,255,255,0.03)'}} />
      <div style={{position: 'absolute', left: 0, right: 0, top: 0, display: 'flex', justifyContent: 'center'}}>
        <NotchShell width={notchW} height={BAR_H} radius={14} glow={open > 0.1 ? `${COLORS.accent}55` : undefined}>
          <div
            style={{
              position: 'absolute',
              inset: 0,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              padding: '0 18px',
              opacity: ease(t, [0.35, 0.6]),
            }}
          >
            <Dot color={COLORS.success} size={10} glow />
            <span style={{fontSize: 16, fontWeight: 600, color: COLORS.textSecondary}}>Ready</span>
          </div>
        </NotchShell>
      </div>

      <Buddy x={pos.x} y={pos.y} size={vertical ? 64 : 56} opacity={ease(t, [0.6, 0.75])} wave={wave} tilt={(1 - Math.min(1, drop)) * 30} />
      <Bubble
        x={pos.x + (vertical ? 70 : 62)}
        y={pos.y + (vertical ? 40 : 34)}
        text="hey! I'm your mate 👋"
        pop={bubble}
        typed={typed}
        width={vertical ? 440 : 360}
        size={vertical ? 32 : 27}
      />

      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: vertical ? height * 0.5 : height * 0.5,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          textAlign: 'center',
        }}
      >
        <Img
          src={staticFile('icon.png')}
          style={{
            width: iconSize,
            height: iconSize,
            borderRadius: iconSize * 0.225,
            boxShadow: '0 24px 60px rgba(0,0,0,0.7), 0 0 0 1px rgba(255,255,255,0.06)',
            opacity: Math.min(1, iconIn * 1.5),
            transform: `scale(${0.7 + 0.3 * iconIn})`,
          }}
        />
        <div style={{marginTop: 34, fontSize: vertical ? 132 : 120, fontWeight: 600, letterSpacing: '-0.035em', lineHeight: 1, ...riseStyle(nameIn, 30, 12)}}>
          HeyMate
        </div>
        <div style={{marginTop: 22, fontSize: vertical ? 42 : 38, color: COLORS.textSecondary, ...riseStyle(tagIn, 18, 6)}}>
          Your AI, sitting right next to you.
        </div>
      </div>
    </Backdrop>
  );
};
