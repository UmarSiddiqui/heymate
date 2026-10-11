// 6 — Positioning: not a rival chatbot, a more fun way to use the one you have.
import React from 'react';
import {COLORS} from '../config';
import {ease, riseStyle, springAt, useLayout, useTime} from '../components/motion';
import {Backdrop} from '../components/UI';
import {PopWords} from './kit';

export const MeetFun: React.FC = () => {
  const {vertical} = useLayout();
  const {t, frame, fps} = useTime();
  const size = vertical ? 96 : 104;
  const before = vertical ? ['HeyMate', 'is', 'a', 'more'] : ['HeyMate', 'is', 'a', 'more'];
  const after = ['way', 'to', 'use', 'them.'];
  const funIn = springAt(frame, fps, 1.1 + 0.09 * before.length, 'buddy');
  const swoosh = ease(t, [1.75, 2.25]);
  const wiggle = Math.sin(t * 9) * 3 * ease(t, [1.6, 1.8]);
  const tailIn = springAt(frame, fps, 2.5, 'gentle');

  const word = (w: string, i: number) => (
    <span key={w + i} style={{display: 'inline-block', marginRight: '0.24em', ...riseStyle(springAt(frame, fps, 1.1 + 0.09 * i, 'buddy'), size * 0.35, 8)}}>
      {w}
    </span>
  );

  return (
    <Backdrop>
      <div style={{position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', textAlign: 'center', padding: '0 60px'}}>
        <PopWords
          text={vertical ? 'Claude and ChatGPT\nare already great.' : 'Claude and ChatGPT are already great.'}
          at={0.15}
          size={vertical ? 56 : 54}
          weight={500}
          color={COLORS.textSecondary}
        />
        <div style={{marginTop: vertical ? 56 : 44, fontSize: size, fontWeight: 600, letterSpacing: '-0.035em', lineHeight: 1.1}}>
          <div>
            {before.map(word)}
            {vertical ? null : (
              <FunWord size={size} pop={funIn} swoosh={swoosh} wiggle={wiggle} />
            )}
          </div>
          <div>
            {vertical ? <FunWord size={size} pop={funIn} swoosh={swoosh} wiggle={wiggle} /> : null}
            {after.map((w, i) => word(w, before.length + 1 + i))}
          </div>
        </div>
        <div style={{marginTop: vertical ? 70 : 56, fontSize: vertical ? 38 : 34, color: COLORS.textTertiary, whiteSpace: 'pre-line', lineHeight: 1.35, ...riseStyle(tailIn, 18, 6)}}>
          {vertical ? 'Learn an app. Ask about anything.\nGet unstuck. Out loud.' : 'Learn an app. Ask about anything. Get unstuck. Out loud.'}
        </div>
      </div>
    </Backdrop>
  );
};

const FunWord: React.FC<{size: number; pop: number; swoosh: number; wiggle: number}> = ({size, pop, swoosh, wiggle}) => (
  <span
    style={{
      position: 'relative',
      display: 'inline-block',
      marginRight: '0.24em',
      color: COLORS.accentText,
      opacity: Math.min(1, pop * 1.5),
      transform: `scale(${0.4 + 0.6 * pop}) rotate(${wiggle}deg)`,
    }}
  >
    fun
    <svg
      viewBox="0 0 200 30"
      preserveAspectRatio="none"
      style={{position: 'absolute', left: '-4%', width: '108%', bottom: -size * 0.16, height: size * 0.24, overflow: 'visible'}}
    >
      <path
        d="M4 18 C 40 4, 70 28, 104 14 S 170 6, 196 16"
        fill="none"
        stroke={COLORS.accent}
        strokeWidth={7}
        strokeLinecap="round"
        pathLength={1}
        strokeDasharray="1 1"
        strokeDashoffset={1 - swoosh}
      />
    </svg>
  </span>
);
