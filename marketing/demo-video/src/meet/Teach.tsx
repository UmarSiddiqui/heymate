// 3 — Teacher mode: ask, it points at the next step, waits while you do it.
import React from 'react';
import {COLORS, FONTS} from '../config';
import {SystemPointer} from '../components/Icons';
import {ease, springAt, useLayout, useTime} from '../components/motion';
import {Dot, FeatureLayout, Keycap, MacScreen, MacWindow, MENU_BAR_H, NotchShell, TrafficLights, Waveform} from '../components/UI';
import {arcPoint, Bubble, Buddy, IllustratedTag, Sparks} from './kit';

const SCREEN_W = 1000;
const SCREEN_H = 640;
const INNER_W = SCREEN_W - 24;

// Beats (seconds)
const PRESS = 0.7;
const RELEASE = 2.3;
const FLY1 = 2.7;
const STEP1 = 3.25;
const WAIT1 = 4.2;
const DRAG_START = 4.9;
const DRAG_END = 5.6;
const NICE = 5.8;
const FLY2 = 6.2;
const STEP2 = 6.7;
const WAIT2 = 7.2;
const CLICK = 7.8;
const CHART = 7.9;
const FLY3 = 8.45;
const WIN_AT = 8.7;

// Spreadsheet geometry (window-local), window placed at WIN in screen space.
const WIN = {x: 28, y: 58, w: 920, h: 530};
const ROW_HEAD = {x: 16, w: 44};
const COLS = [
  {x: 60, w: 170},
  {x: 230, w: 150},
  {x: 380, w: 150},
  {x: 530, w: 374},
];
const GRID_Y = 100;
const LETTER_H = 32;
const ROW_H = 40;
const ROWS = [
  ['Day', 'Food', 'Fun'],
  ['Mon', '42', '18'],
  ['Tue', '35', '60'],
  ['Wed', '28', '24'],
  ['Thu', '51', '12'],
  ['Fri', '38', '75'],
];
const RANGE = {x: COLS[0].x, y: GRID_Y + LETTER_H, w: COLS[2].x + COLS[2].w - COLS[0].x, h: ROW_H * ROWS.length};
const TOOLS = ['Table', 'Chart', 'Text', 'Shape'];
const TOOL = {x: 20, y: 52, w: 92, h: 32, gap: 10};
const CHART_BTN = {x: TOOL.x + TOOL.w + TOOL.gap, y: TOOL.y, w: TOOL.w, h: TOOL.h};
const CHART_CARD = {x: 566, y: 140, w: 320, h: 270};

const scr = (x: number, y: number) => ({x: WIN.x + x, y: WIN.y + y});

export const MeetTeach: React.FC = () => {
  const {t, frame, fps} = useTime();
  const {vertical} = useLayout();
  const bubbleSize = vertical ? 22 : 19;

  // Push-to-talk
  const keysIn = springAt(frame, fps, 0.35, 'buddy');
  const keysOut = ease(t, [RELEASE + 0.4, RELEASE + 0.8]);
  const pressed = ease(t, [PRESS, PRESS + 0.1]) * (1 - ease(t, [RELEASE, RELEASE + 0.1]));
  const question = 'How do I make a chart from this?';
  const words = question.split(' ');
  const shown = Math.floor(ease(t, [PRESS + 0.3, RELEASE - 0.25], [0, words.length + 0.001], (x) => x));
  const captionIn = ease(t, [PRESS + 0.25, PRESS + 0.45]) * (1 - ease(t, [RELEASE + 0.1, FLY1]));

  const state =
    t < PRESS ? 'idle'
    : t < RELEASE ? 'listening'
    : t < FLY1 ? 'thinking'
    : (t >= WAIT1 && t < NICE) || (t >= WAIT2 && t < CHART) ? 'waiting'
    : 'speaking';
  const statusText = {idle: '', listening: 'Listening', thinking: 'Thinking', speaking: 'Speaking', waiting: 'Your turn'}[state];
  const statusColor = state === 'thinking' ? COLORS.warning : state === 'waiting' ? COLORS.success : COLORS.accent;
  const pillOpen = springAt(frame, fps, PRESS, 'control');
  const pillW = 196 + 150 * pillOpen;

  // Buddy path: notch → range corner → Chart button → chart.
  const notch = {x: INNER_W / 2, y: 26};
  const p1 = scr(RANGE.x + RANGE.w + 4, RANGE.y + 6);
  const p2 = scr(CHART_BTN.x + CHART_BTN.w - 8, CHART_BTN.y + CHART_BTN.h - 4);
  const p3 = scr(CHART_CARD.x + 18, CHART_CARD.y + CHART_CARD.h - 4);
  const f1 = springAt(frame, fps, FLY1, 'gentle');
  const f2 = springAt(frame, fps, FLY2, 'gentle');
  const f3 = springAt(frame, fps, FLY3, 'gentle');
  let buddy = arcPoint(notch, p1, f1, 60);
  if (t >= FLY2) buddy = arcPoint(p1, p2, f2, 50);
  if (t >= FLY3) buddy = arcPoint(p2, p3, f3, 70);
  const buddyOpacity = ease(t, [FLY1 - 0.05, FLY1 + 0.15]);

  // User's pointer
  const u0 = {x: 900, y: 610};
  const uA = scr(RANGE.x + 30, RANGE.y + 20);
  const uB = scr(RANGE.x + RANGE.w - 30, RANGE.y + RANGE.h - 14);
  const uC = scr(CHART_BTN.x + 40, CHART_BTN.y + 18);
  const m1 = ease(t, [WAIT1, DRAG_START - 0.1]);
  const drag = ease(t, [DRAG_START, DRAG_END], [0, 1], (x) => x * x * (3 - 2 * x));
  const m2 = ease(t, [WAIT2, CLICK - 0.1]);
  let user = {x: u0.x + (uA.x - u0.x) * m1, y: u0.y + (uA.y - u0.y) * m1};
  if (t >= DRAG_START) user = {x: uA.x + (uB.x - uA.x) * drag, y: uA.y + (uB.y - uA.y) * drag};
  if (t >= WAIT2) user = {x: uB.x + (uC.x - uB.x) * m2, y: uB.y + (uC.y - uB.y) * m2};
  const userOpacity = ease(t, [WAIT1 - 0.1, WAIT1 + 0.1]);
  const userPress =
    ease(t, [DRAG_START - 0.08, DRAG_START]) * (1 - ease(t, [DRAG_END + 0.05, DRAG_END + 0.12])) +
    ease(t, [CLICK - 0.06, CLICK]) * (1 - ease(t, [CLICK + 0.1, CLICK + 0.16]));

  // Selection grows with the drag; the target outline shows before it.
  const selW = (RANGE.w * 0.18 + RANGE.w * 0.82 * drag) * (t >= DRAG_START ? 1 : 0);
  const selH = (ROW_H + (RANGE.h - ROW_H) * drag) * (t >= DRAG_START ? 1 : 0);
  const targetOn = ease(t, [STEP1 - 0.1, STEP1 + 0.2]) * (1 - ease(t, [NICE - 0.2, NICE]));
  const btnRing = ease(t, [STEP2, STEP2 + 0.2]) * (1 - ease(t, [CLICK, CLICK + 0.1]));
  const pulse = 0.5 + 0.5 * Math.sin(t * 7);

  const chartIn = springAt(frame, fps, CHART, 'buddy');
  const bars = ease(t, [CHART + 0.15, CHART + 0.8]);

  const b1 = springAt(frame, fps, STEP1, 'buddy') * (1 - ease(t, [NICE - 0.15, NICE]));
  const nice = springAt(frame, fps, NICE, 'buddy') * (1 - ease(t, [FLY2, FLY2 + 0.15]));
  const b2 = springAt(frame, fps, STEP2, 'buddy') * (1 - ease(t, [FLY3 - 0.1, FLY3 + 0.05]));
  const b3 = springAt(frame, fps, WIN_AT, 'buddy');

  return (
    <>
    <FeatureLayout
      title={'It teaches.\nYou do.'}
      sub="Hold ⌃ ⌥ and ask about anything on screen. HeyMate points at the next step, explains it, then waits while you try."
      stageWidth={SCREEN_W}
      stageHeight={SCREEN_H}
      verticalFocus={{x: 0, y: 0, w: SCREEN_W, h: SCREEN_H + 30}}
      overlay={
        <div
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            top: SCREEN_H - 70,
            display: 'flex',
            justifyContent: 'center',
            gap: 18,
            opacity: Math.min(1, keysIn * 1.4) * (1 - keysOut),
            transform: `translateY(${(1 - keysIn) * 40 + keysOut * 20}px)`,
          }}
        >
          <Keycap glyph="⌃" label="control" pressed={pressed} />
          <Keycap glyph="⌥" label="option" pressed={pressed} />
        </div>
      }
    >
      <MacScreen
        width={SCREEN_W}
        height={SCREEN_H}
        menu={vertical ? 'left-only' : 'compact'}
        notch={
          <NotchShell width={pillW} height={MENU_BAR_H} radius={12} glow={pillOpen > 0.1 ? `${statusColor}40` : undefined}>
            <div
              style={{
                position: 'absolute',
                inset: 0,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                padding: '0 16px',
                opacity: ease(t, [PRESS + 0.05, PRESS + 0.25]),
              }}
            >
              {state === 'thinking' || state === 'waiting' ? (
                <Dot color={statusColor} size={9} glow />
              ) : (
                <Waveform color={COLORS.accent} level={state === 'listening' ? 1 : 0.7} seed={state === 'speaking' ? 3 : 0} />
              )}
              <span style={{fontSize: 14, fontWeight: 600, color: state === 'waiting' ? COLORS.success : state === 'thinking' ? COLORS.warningText : COLORS.accentText}}>
                {statusText}
              </span>
            </div>
          </NotchShell>
        }
        top={
          <>
            {/* Spoken question */}
            <div style={{position: 'absolute', left: 0, right: 0, top: 64, display: 'flex', justifyContent: 'center', opacity: captionIn, zIndex: 30}}>
              <div
                style={{
                  padding: '12px 22px',
                  borderRadius: 16,
                  background: 'rgba(10,10,10,0.92)',
                  border: `1px solid ${COLORS.borderStrong}`,
                  fontSize: vertical ? 26 : 22,
                  fontWeight: 600,
                  boxShadow: '0 14px 40px rgba(0,0,0,0.6)',
                }}
              >
                “{words.slice(0, Math.max(1, shown)).join(' ')}
                <span style={{opacity: 0}}>{' ' + words.slice(Math.max(1, shown)).join(' ')}</span>”
              </div>
            </div>

            {/* Step 1 target outline */}
            <div
              style={{
                position: 'absolute',
                left: WIN.x + RANGE.x - 4,
                top: WIN.y + RANGE.y - 4,
                width: RANGE.w + 8,
                height: RANGE.h + 8,
                borderRadius: 8,
                border: `2.5px dashed ${COLORS.accent}`,
                opacity: targetOn * (0.55 + 0.45 * pulse),
              }}
            />
            {/* Step 2 ring around the Chart button */}
            <div
              style={{
                position: 'absolute',
                left: WIN.x + CHART_BTN.x - 6,
                top: WIN.y + CHART_BTN.y - 6,
                width: CHART_BTN.w + 12,
                height: CHART_BTN.h + 12,
                borderRadius: 12,
                border: `2.5px solid ${COLORS.accent}`,
                boxShadow: `0 0 ${18 + 14 * pulse}px ${COLORS.accent}`,
                opacity: btnRing,
              }}
            />

            <Buddy x={buddy.x} y={buddy.y} size={34} opacity={buddyOpacity} tilt={(1 - Math.min(1, f1)) * -18} />
            <Bubble x={p1.x + 40} y={p1.y + 30} label="Step 1 of 2" text="Drag from “Day” down to Friday’s numbers." pop={b1} typed={ease(t, [STEP1 + 0.05, WAIT1 - 0.15], [0, 1], (x) => x)} size={bubbleSize} width={340} />
            <Bubble x={p1.x + 40} y={p1.y + 30} text="Nice! ✓" pop={nice} size={bubbleSize} width={130} tone="win" />
            <Bubble x={p2.x + 34} y={p2.y + 20} label="Step 2 of 2" text="Now click Chart." pop={b2} typed={ease(t, [STEP2 + 0.05, WAIT2 - 0.1], [0, 1], (x) => x)} size={bubbleSize} width={260} />
            <Bubble x={p3.x + 30} y={p3.y + 16} label="You did it" text="🎉 Next time, it’s all you." pop={b3} typed={ease(t, [WIN_AT + 0.05, WIN_AT + 0.6], [0, 1], (x) => x)} size={bubbleSize} width={300} tone="win" />
            <Sparks x={WIN.x + CHART_CARD.x + CHART_CARD.w / 2} y={WIN.y + CHART_CARD.y + 40} at={CHART + 0.4} radius={150} count={14} />

            <div style={{position: 'absolute', left: user.x, top: user.y, opacity: userOpacity, zIndex: 25}}>
              <SystemPointer size={30} press={userPress} />
            </div>
          </>
        }
      >
        <div style={{position: 'absolute', left: WIN.x, top: WIN.y}}>
          <MacWindow width={WIN.w} height={WIN.h} background={COLORS.surface1}>
            <Sheet selW={selW} selH={selH} chartIn={chartIn} bars={bars} pressed={ease(t, [CLICK - 0.06, CLICK]) * (1 - ease(t, [CLICK + 0.1, CLICK + 0.16]))} />
          </MacWindow>
        </div>
      </MacScreen>
    </FeatureLayout>
    <IllustratedTag />
    </>
  );
};

const Sheet: React.FC<{selW: number; selH: number; chartIn: number; bars: number; pressed: number}> = ({selW, selH, chartIn, bars, pressed}) => (
  <div style={{position: 'absolute', inset: 0, fontFamily: FONTS.ui}}>
    {/* Title bar */}
    <div style={{height: 44, display: 'flex', alignItems: 'center', padding: '0 16px', borderBottom: `1px solid ${COLORS.borderSubtle}`}}>
      <TrafficLights />
      <div style={{flex: 1, textAlign: 'center', fontSize: 15, fontWeight: 600, color: COLORS.textSecondary, marginRight: 50}}>Trip budget</div>
    </div>
    {/* Toolbar */}
    {TOOLS.map((label, i) => {
      const isChart = label === 'Chart';
      return (
        <div
          key={label}
          style={{
            position: 'absolute',
            left: TOOL.x + i * (TOOL.w + TOOL.gap),
            top: TOOL.y,
            width: TOOL.w,
            height: TOOL.h,
            borderRadius: 8,
            background: isChart && pressed > 0 ? COLORS.surface4 : COLORS.surface2,
            border: `1px solid ${COLORS.borderSubtle}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            gap: 6,
            fontSize: 14,
            fontWeight: 600,
            color: COLORS.textSecondary,
            transform: isChart ? `scale(${1 - pressed * 0.06})` : undefined,
          }}
        >
          {isChart ? <MiniBars /> : null}
          {label}
        </div>
      );
    })}
    {/* Column letters */}
    <div style={{position: 'absolute', left: 0, right: 0, top: GRID_Y, height: LETTER_H, background: COLORS.surface2, borderTop: `1px solid ${COLORS.borderSubtle}`, borderBottom: `1px solid ${COLORS.borderSubtle}`}} />
    {COLS.map((c, i) => (
      <div key={i} style={{position: 'absolute', left: c.x, top: GRID_Y, width: c.w, height: LETTER_H, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 600, color: COLORS.textTertiary, borderLeft: `1px solid ${COLORS.borderSubtle}`}}>
        {'ABCD'[i]}
      </div>
    ))}
    {/* Rows */}
    {Array.from({length: 9}).map((_, r) => {
      const y = GRID_Y + LETTER_H + r * ROW_H;
      const row = ROWS[r];
      return (
        <React.Fragment key={r}>
          <div style={{position: 'absolute', left: 0, right: 0, top: y + ROW_H - 1, height: 1, background: COLORS.borderSubtle}} />
          <div style={{position: 'absolute', left: ROW_HEAD.x, top: y, width: ROW_HEAD.w, height: ROW_H, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, color: COLORS.textTertiary}}>
            {r + 1}
          </div>
          {row?.map((cell, ci) => (
            <div
              key={ci}
              style={{
                position: 'absolute',
                left: COLS[ci].x,
                top: y,
                width: COLS[ci].w,
                height: ROW_H,
                display: 'flex',
                alignItems: 'center',
                justifyContent: ci === 0 ? 'flex-start' : 'flex-end',
                padding: '0 16px',
                boxSizing: 'border-box',
                fontSize: 17,
                fontWeight: r === 0 ? 700 : 500,
                color: r === 0 ? COLORS.textPrimary : COLORS.textSecondary,
                fontFamily: ci === 0 || r === 0 ? FONTS.ui : FONTS.numeric,
              }}
            >
              {ci === 0 || r === 0 ? cell : `$${cell}`}
            </div>
          ))}
        </React.Fragment>
      );
    })}
    {COLS.map((c, i) => (
      <div key={`v${i}`} style={{position: 'absolute', left: c.x, top: GRID_Y + LETTER_H, width: 1, bottom: 0, background: COLORS.borderSubtle}} />
    ))}
    {/* User's selection */}
    <div
      style={{
        position: 'absolute',
        left: RANGE.x,
        top: RANGE.y,
        width: selW,
        height: selH,
        background: 'rgba(51,128,255,0.18)',
        border: selW > 0 ? `2px solid ${COLORS.accent}` : undefined,
        boxSizing: 'border-box',
      }}
    />
    {/* The chart the user just made */}
    <div
      style={{
        position: 'absolute',
        left: CHART_CARD.x,
        top: CHART_CARD.y,
        width: CHART_CARD.w,
        height: CHART_CARD.h,
        borderRadius: 14,
        background: COLORS.surface3,
        border: `1px solid ${COLORS.borderStrong}`,
        boxShadow: '0 24px 50px rgba(0,0,0,0.55)',
        opacity: Math.min(1, chartIn * 1.5),
        transform: `scale(${0.75 + 0.25 * chartIn})`,
        transformOrigin: '30% 0%',
        padding: 18,
        boxSizing: 'border-box',
      }}
    >
      <div style={{fontSize: 15, fontWeight: 700, color: COLORS.textPrimary}}>Trip budget</div>
      <div style={{display: 'flex', gap: 14, marginTop: 6, fontSize: 12, color: COLORS.textTertiary}}>
        <span style={{display: 'flex', alignItems: 'center', gap: 5}}><Dot color={COLORS.accent} size={8} /> Food</span>
        <span style={{display: 'flex', alignItems: 'center', gap: 5}}><Dot color={COLORS.success} size={8} /> Fun</span>
      </div>
      <div style={{position: 'absolute', left: 18, right: 18, bottom: 34, height: 150, display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', borderBottom: `1px solid ${COLORS.borderStrong}`}}>
        {ROWS.slice(1).map((row, i) => (
          <div key={i} style={{display: 'flex', alignItems: 'flex-end', gap: 4}}>
            <div style={{width: 16, height: (Number(row[1]) / 75) * 140 * bars, borderRadius: '4px 4px 0 0', background: COLORS.accent}} />
            <div style={{width: 16, height: (Number(row[2]) / 75) * 140 * bars, borderRadius: '4px 4px 0 0', background: COLORS.success}} />
          </div>
        ))}
      </div>
      <div style={{position: 'absolute', left: 18, right: 18, bottom: 10, display: 'flex', justifyContent: 'space-between', fontSize: 12, color: COLORS.textTertiary}}>
        {ROWS.slice(1).map((row) => (
          <span key={row[0]} style={{width: 36, textAlign: 'center'}}>{row[0]}</span>
        ))}
      </div>
    </div>
  </div>
);

const MiniBars: React.FC = () => (
  <div style={{display: 'flex', alignItems: 'flex-end', gap: 2, height: 14}}>
    {[7, 12, 9].map((h, i) => (
      <div key={i} style={{width: 3.5, height: h, borderRadius: 1, background: COLORS.textSecondary}} />
    ))}
  </div>
);
