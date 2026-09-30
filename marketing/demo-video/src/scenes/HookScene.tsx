// Scene 1 — the problem: a slow Mac and the Activity Monitor detective work.
import React from 'react';
import {COLORS, COPY, FONTS} from '../config';
import {ease, riseStyle, springAt, useLayout, useTime} from '../components/motion';
import {Backdrop} from '../components/UI';

export const HookScene: React.FC = () => {
  const {vertical} = useLayout();
  const {t, frame, fps} = useTime();

  const errorIn = springAt(frame, fps, 0.05, 'gentle');
  const questionIn = springAt(frame, fps, 0.25, 'gentle');
  // Beat 1 leaves at 2.45 s; the answer arrives at 2.8 s.
  const out = ease(t, [2.45, 2.85]);
  const answerIn = springAt(frame, fps, 2.8, 'gentle');

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
          padding: vertical ? '0 70px' : '0 160px',
          opacity: 1 - out,
          transform: `translateY(${-out * 40}px) scale(${1 - out * 0.03})`,
          filter: `blur(${out * 8}px)`,
        }}
      >
        <div
          style={{
            fontFamily: FONTS.mono,
            fontSize: vertical ? 24 : 22,
            color: COLORS.warningText,
            opacity: 0.85 * Math.min(1, errorIn * 1.3),
            marginBottom: 36,
            textAlign: 'center',
            transform: `translateY(${(1 - errorIn) * 12}px)`,
          }}
        >
          {COPY.hook.symptom}
        </div>
        <div
          style={{
            fontSize: vertical ? 104 : 108,
            fontWeight: 600,
            letterSpacing: '-0.03em',
            lineHeight: 1.04,
            textAlign: 'center',
            whiteSpace: 'pre-line',
            ...riseStyle(questionIn, 36, 12),
          }}
        >
          {vertical ? COPY.hook.question : COPY.hook.question.replace('\n', ' ')}
        </div>
        <div
          style={{
            marginTop: 56,
            display: 'flex',
            flexWrap: 'wrap',
            justifyContent: 'center',
            alignItems: 'center',
            gap: vertical ? '18px 14px' : 14,
            maxWidth: vertical ? 860 : undefined,
          }}
        >
          {COPY.hook.chores.map((chore, i) => {
            const p = springAt(frame, fps, 0.85 + i * 0.2, 'control');
            // The chips pile up: each new one nudges the previous ones dimmer.
            const later = COPY.hook.chores.length - 1 - i;
            const dim = ease(t, [0.85 + (i + 1) * 0.2, 2.2 + later * 0.02], [1, 0.55]);
            return (
              <React.Fragment key={chore}>
                <div
                  style={{
                    padding: '14px 26px',
                    borderRadius: 999,
                    background: COLORS.surface2,
                    border: `1px solid ${COLORS.borderStrong}`,
                    fontSize: vertical ? 32 : 30,
                    fontWeight: 600,
                    color: COLORS.textSecondary,
                    opacity: Math.min(1, p * 1.4) * dim,
                    transform: `translateY(${(1 - p) * -26}px) scale(${0.9 + 0.1 * p})`,
                    whiteSpace: 'nowrap',
                  }}
                >
                  {chore}
                </div>
                {i < COPY.hook.chores.length - 1 && !vertical ? (
                  <div style={{color: COLORS.textTertiary, fontSize: 26, opacity: Math.min(1, p) * dim}}>→</div>
                ) : null}
              </React.Fragment>
            );
          })}
        </div>
      </div>

      <div
        style={{
          position: 'absolute',
          inset: 0,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          textAlign: 'center',
          padding: '0 80px',
          fontSize: vertical ? 92 : 96,
          fontWeight: 600,
          letterSpacing: '-0.03em',
          lineHeight: 1.08,
          ...riseStyle(answerIn, 30, 12),
        }}
      >
        {COPY.hook.answer}
      </div>
    </Backdrop>
  );
};
