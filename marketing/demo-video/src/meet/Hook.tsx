// 1 — "You already have a brilliant AI. It's stuck in a tab."
import React from 'react';
import {COLORS} from '../config';
import {SparkleIcon} from '../components/Icons';
import {ease, springAt, useLayout, useTime} from '../components/motion';
import {Backdrop} from '../components/UI';
import {PopWords} from './kit';

const TABS = ['Inbox', 'Docs', 'Calendar', 'AI chat', 'Recipes', 'Flights', 'Bank', 'Notes', 'News', 'Maps'];
const AI_TAB = 3;

export const MeetHook: React.FC = () => {
  const {vertical, width} = useLayout();
  const {t, frame, fps} = useTime();

  // Tabs arrive, then more tabs shove in and squeeze the AI tab.
  const rowIn = springAt(frame, fps, 1.6, 'buddy');
  const squeeze = ease(t, [2.6, 3.6]);
  const visible = Math.round(6 + squeeze * (TABS.length - 6));
  const rowW = vertical ? width - 80 : 1240;
  const tabW = rowW / visible;
  const wobble = Math.sin(t * 14) * 3 * squeeze;

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
          gap: vertical ? 90 : 70,
        }}
      >
        <div>
          <PopWords
            text={vertical ? 'You already have\na brilliant AI.' : 'You already have a brilliant AI.'}
            at={0.15}
            size={vertical ? 92 : 104}
          />
          <PopWords
            text={vertical ? "But it's stuck\nin a tab." : "But it's stuck in a tab."}
            at={1.25}
            size={vertical ? 92 : 104}
            color={COLORS.textTertiary}
            style={{marginTop: vertical ? 24 : 12}}
          />
        </div>

        {/* A browser tab strip, getting more crowded. */}
        <div
          style={{
            width: rowW,
            height: vertical ? 74 : 64,
            display: 'flex',
            alignItems: 'flex-end',
            padding: '0 10px',
            boxSizing: 'border-box',
            background: COLORS.surface1,
            borderRadius: 16,
            border: `1px solid ${COLORS.borderSubtle}`,
            overflow: 'hidden',
            opacity: Math.min(1, rowIn * 1.5),
            transform: `translateY(${(1 - rowIn) * 40}px)`,
          }}
        >
          {TABS.slice(0, visible).map((label, i) => {
            const ai = i === AI_TAB;
            return (
              <div
                key={label}
                style={{
                  width: tabW - 6,
                  marginRight: 6,
                  height: vertical ? 54 : 46,
                  borderRadius: '12px 12px 0 0',
                  background: ai ? COLORS.surface3 : COLORS.surface2,
                  border: ai ? `1.5px solid ${COLORS.accent}` : `1px solid ${COLORS.borderSubtle}`,
                  borderBottom: 'none',
                  display: 'flex',
                  alignItems: 'center',
                  gap: 8,
                  padding: '0 12px',
                  boxSizing: 'border-box',
                  overflow: 'hidden',
                  whiteSpace: 'nowrap',
                  fontSize: vertical ? 22 : 20,
                  fontWeight: 600,
                  color: ai ? COLORS.textPrimary : COLORS.textTertiary,
                  transform: ai ? `rotate(${wobble}deg)` : undefined,
                  flexShrink: 0,
                }}
              >
                {ai ? <SparkleIcon size={vertical ? 22 : 20} color={COLORS.accentText} /> : (
                  <div style={{width: 14, height: 14, borderRadius: 4, background: COLORS.surface4, flexShrink: 0}} />
                )}
                <span style={{overflow: 'hidden', textOverflow: 'ellipsis'}}>{label}</span>
              </div>
            );
          })}
        </div>
      </div>
    </Backdrop>
  );
};
