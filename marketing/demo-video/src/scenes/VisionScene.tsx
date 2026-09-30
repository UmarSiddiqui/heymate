// Scene 4 — push-to-talk, the buddy looks at Activity Monitor, flies to the
// runaway process, and says what to do.
import React from 'react';
import {Img, staticFile} from 'remotion';
import {COLORS, COPY, FONTS} from '../config';
import {BuddyCursor, SearchIcon} from '../components/Icons';
import {ease, springAt, useLayout, useTime} from '../components/motion';
import {Dot, FeatureLayout, Keycap, MacScreen, MENU_BAR_H, MacWindow, NotchShell, TrafficLights, Waveform} from '../components/UI';

const SCREEN_W = 1000;
const SCREEN_H = 640;
const INNER_W = SCREEN_W - 24;

// Beats (seconds)
const KEYS_IN = 0.55;
const PRESS_AT = 0.9;
const RELEASE_AT = 3.0;
const FLY_START = 3.35;
const FLY_END = 4.25;
const REPLY_START = 4.45;
const REPLY_END = 6.2;

// Activity Monitor geometry (window-local)
const WIN = {x: 36, y: 104, w: 904, h: 488};
const TITLE_H = 52;
const HEAD_H = 34;
const ROWS_TOP = TITLE_H + HEAD_H;
const ROW_H = 34;
const CPU_RIGHT = 420; // right edge of the % CPU column

type Proc = {name: string; cpu: string; time: string; threads: string; wakeups: string; pid: string; icon: string | null};
const PROCS: Proc[] = [
  {name: 'Chrome Helper (Renderer)', cpu: '97.4', time: '1:42:08.31', threads: '24', wakeups: '1,204', pid: '4127', icon: null},
  {name: 'WindowServer', cpu: '18.6', time: '3:12:45.02', threads: '21', wakeups: '612', pid: '402', icon: '#4B4B52'},
  {name: 'kernel_task', cpu: '9.8', time: '2:08:11.77', threads: '512', wakeups: '1,880', pid: '0', icon: '#3A3A40'},
  {name: 'Music', cpu: '3.2', time: '0:14:02.60', threads: '38', wakeups: '96', pid: '1893', icon: '#E5484D'},
  {name: 'Finder', cpu: '1.4', time: '0:06:51.13', threads: '12', wakeups: '8', pid: '611', icon: '#3380FF'},
  {name: 'Mail', cpu: '0.9', time: '0:04:33.48', threads: '29', wakeups: '14', pid: '988', icon: '#4C9AFF'},
  {name: 'HeyMate', cpu: '0.6', time: '0:01:12.09', threads: '18', wakeups: '3', pid: '2201', icon: 'heymate'},
  {name: 'Notes', cpu: '0.2', time: '0:00:48.30', threads: '9', wakeups: '1', pid: '1540', icon: '#F1C40F'},
];
const HOG_ROW = 0;
// Right edges of the numeric columns after % CPU.
const COLS: {key: keyof Proc; label: string; right: number}[] = [
  {key: 'time', label: 'CPU Time', right: 545},
  {key: 'threads', label: 'Threads', right: 640},
  {key: 'wakeups', label: 'Idle Wake Ups', right: 775},
  {key: 'pid', label: 'PID', right: 872},
];
const TABS = ['CPU', 'Memory', 'Energy', 'Disk', 'Network'];

export const VisionScene: React.FC = () => {
  const {t, frame, fps} = useTime();
  const {vertical} = useLayout();

  const keysIn = springAt(frame, fps, KEYS_IN, 'buddy');
  const keysOut = ease(t, [RELEASE_AT + 0.5, RELEASE_AT + 0.9]);
  const pressed = ease(t, [PRESS_AT, PRESS_AT + 0.1]) * (1 - ease(t, [RELEASE_AT, RELEASE_AT + 0.1]));

  const listening = t >= PRESS_AT && t < RELEASE_AT;
  const thinking = t >= RELEASE_AT && t < REPLY_START;
  const speaking = t >= REPLY_START;
  const pillOpen = springAt(frame, fps, PRESS_AT, 'control');
  const pillW = 196 + 150 * pillOpen;
  const pillColor = thinking ? COLORS.warning : COLORS.accent;
  const status = listening ? 'Listening' : thinking ? 'Thinking' : speaking ? 'Speaking' : '';

  // Spoken question, word by word.
  const words = COPY.vision.question.split(' ');
  const wordsShown = Math.floor(ease(t, [PRESS_AT + 0.35, RELEASE_AT - 0.3], [0, words.length + 0.001], (x) => x));
  const captionIn = ease(t, [PRESS_AT + 0.3, PRESS_AT + 0.55]) * (1 - ease(t, [RELEASE_AT + 0.05, FLY_START - 0.05]));

  // Buddy flight: notch → the runaway process's % CPU, along an arc.
  const target = {x: WIN.x + CPU_RIGHT + 6, y: WIN.y + ROWS_TOP + HOG_ROW * ROW_H + 12};
  const origin = {x: INNER_W / 2, y: 26};
  const fp = springAt(frame, fps, FLY_START, 'gentle');
  const arc = Math.sin(Math.min(1, fp) * Math.PI) * 120;
  const bx = origin.x + (target.x - origin.x) * fp + arc * 0.9;
  const by = origin.y + (target.y - origin.y) * fp - arc * 0.15;
  const buddyIn = ease(t, [FLY_START - 0.1, FLY_START + 0.15]);
  const tilt = (1 - Math.min(1, fp)) * -18;

  const highlight = springAt(frame, fps, FLY_END - 0.15, 'buddy');
  const pulse = 0.5 + 0.5 * Math.sin((t - FLY_END) * 5);

  const reply = COPY.vision.reply;
  const chars = Math.floor(ease(t, [REPLY_START, REPLY_END], [0, reply.length], (x) => x));
  const replyIn = springAt(frame, fps, REPLY_START - 0.1, 'buddy');

  return (
    <FeatureLayout
      title={COPY.vision.title}
      sub={COPY.vision.sub}
      stageWidth={SCREEN_W}
      stageHeight={SCREEN_H}
      verticalFocus={{x: 26, y: 0, w: 940, h: 690}}
      overlay={
        <div
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            top: SCREEN_H - 58,
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
        menu={vertical ? 'left-only' : 'full'}
        notch={
          <NotchShell width={pillW} height={MENU_BAR_H} radius={12} glow={pillOpen > 0.1 ? `${pillColor}40` : undefined}>
            <div
              style={{
                position: 'absolute',
                inset: 0,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                padding: '0 16px',
                opacity: ease(t, [PRESS_AT + 0.05, PRESS_AT + 0.25]),
              }}
            >
              {thinking ? <Dot color={COLORS.warning} size={9} glow /> : <Waveform color={COLORS.accent} level={listening ? 1 : 0.7} seed={speaking ? 3 : 0} />}
              <span style={{fontSize: 14, fontWeight: 600, color: thinking ? COLORS.warningText : COLORS.accentText}}>{status}</span>
            </div>
          </NotchShell>
        }
        top={
          <>
            {/* Spoken question caption */}
            <div
              style={{
                position: 'absolute',
                left: 0,
                right: 0,
                top: MENU_BAR_H + 16,
                display: 'flex',
                justifyContent: 'center',
                opacity: captionIn,
                transform: `translateY(${(1 - captionIn) * -8}px)`,
              }}
            >
              <div
                style={{
                  padding: '10px 20px',
                  borderRadius: 999,
                  background: '#0C0C0D',
                  border: `1px solid ${COLORS.borderStrong}`,
                  fontSize: 19,
                  fontWeight: 500,
                  boxShadow: '0 12px 30px rgba(0,0,0,0.5)',
                  minWidth: 320,
                  textAlign: 'center',
                }}
              >
                {words.map((word, i) => (
                  <span key={i} style={{opacity: i < wordsShown ? 1 : 0.18}}>
                    {word}{' '}
                  </span>
                ))}
              </div>
            </div>

            {/* Buddy cursor */}
            <div
              style={{
                position: 'absolute',
                left: bx - 6,
                top: by - 4,
                opacity: buddyIn,
                transform: `rotate(${tilt}deg) scale(${0.6 + 0.4 * buddyIn})`,
                transformOrigin: '6px 4px',
              }}
            >
              <BuddyCursor size={40} color={COLORS.accent} glow={0.8 + 0.4 * (t > FLY_END ? pulse : 0)} />
            </div>

            {/* Reply bubble beside the cursor */}
            <div
              style={{
                position: 'absolute',
                left: target.x + 42,
                top: target.y + 20,
                width: 370,
                padding: '14px 18px',
                borderRadius: 18,
                borderTopLeftRadius: 6,
                background: 'rgba(22,22,24,0.96)',
                border: `1px solid ${COLORS.borderStrong}`,
                boxShadow: '0 20px 50px rgba(0,0,0,0.6)',
                fontSize: 18,
                lineHeight: 1.45,
                opacity: Math.min(1, replyIn * 1.5),
                transform: `translateY(${(1 - replyIn) * 12}px) scale(${0.96 + 0.04 * replyIn})`,
                transformOrigin: 'top left',
              }}
            >
              <ReplyText text={reply.slice(0, chars)} />
              {chars < reply.length ? (
                <span style={{display: 'inline-block', width: 2, height: 18, marginLeft: 2, background: COLORS.accent, verticalAlign: -3}} />
              ) : null}
            </div>
          </>
        }
      >
        <div style={{position: 'absolute', left: WIN.x, top: WIN.y}}>
          <MacWindow width={WIN.w} height={WIN.h} background="#0F0F10">
            <ActivityMonitor t={t} highlight={highlight} pulse={pulse} />
          </MacWindow>
        </div>
      </MacScreen>
    </FeatureLayout>
  );
};

/** Activity Monitor, CPU tab, sorted by % CPU. One renderer is running away. */
const ActivityMonitor: React.FC<{t: number; highlight: number; pulse: number}> = ({t, highlight, pulse}) => {
  const hogY = ROWS_TOP + HOG_ROW * ROW_H;
  return (
    <>
      {/* Toolbar */}
      <div
        style={{
          height: TITLE_H,
          display: 'flex',
          alignItems: 'center',
          gap: 18,
          padding: '0 18px',
          borderBottom: `1px solid ${COLORS.borderSubtle}`,
          background: COLORS.surface1,
        }}
      >
        <TrafficLights size={12} />
        <div style={{lineHeight: 1.15}}>
          <div style={{fontSize: 15, fontWeight: 600, color: COLORS.textPrimary}}>Activity Monitor</div>
          <div style={{fontSize: 12, color: COLORS.textTertiary}}>All Processes</div>
        </div>
        <div style={{flex: 1}} />
        <div style={{display: 'flex', padding: 3, borderRadius: 8, background: COLORS.surface3}}>
          {TABS.map((tab, i) => (
            <div
              key={tab}
              style={{
                padding: '4px 13px',
                borderRadius: 6,
                fontSize: 13,
                fontWeight: 600,
                color: i === 0 ? COLORS.textPrimary : COLORS.textTertiary,
                background: i === 0 ? COLORS.surface4 : 'transparent',
              }}
            >
              {tab}
            </div>
          ))}
        </div>
        <SearchIcon size={18} color={COLORS.textTertiary} />
      </div>

      {/* Column headers */}
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: TITLE_H,
          height: HEAD_H,
          borderBottom: `1px solid ${COLORS.borderSubtle}`,
          fontSize: 13,
          fontWeight: 600,
          color: COLORS.textTertiary,
        }}
      >
        <span style={{position: 'absolute', left: 24, top: 9}}>Process Name</span>
        <span style={{position: 'absolute', right: WIN.w - CPU_RIGHT, top: 9, color: COLORS.textSecondary}}>% CPU ▾</span>
        {COLS.map((c) => (
          <span key={c.key} style={{position: 'absolute', right: WIN.w - c.right, top: 9}}>
            {c.label}
          </span>
        ))}
      </div>

      {/* The runaway row: red before HeyMate looks, selected after. */}
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: hogY,
          height: ROW_H,
          background: `rgba(229,72,77,${0.12 * (1 - highlight)})`,
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: 8,
          right: 8,
          top: hogY + 1,
          height: ROW_H - 2,
          borderRadius: 7,
          background: `rgba(51,128,255,${0.2 * highlight})`,
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: CPU_RIGHT - 70,
          top: hogY + 2,
          width: 82,
          height: ROW_H - 4,
          borderRadius: 8,
          boxShadow: `0 0 0 ${1.5 * highlight}px rgba(51,128,255,${0.9 * highlight}), 0 0 ${24 * highlight * (0.6 + 0.4 * pulse)}px rgba(51,128,255,${0.45 * highlight})`,
          transform: `scale(${0.9 + 0.1 * highlight})`,
        }}
      />

      {PROCS.map((p, i) => {
        const hog = i === HOG_ROW;
        return (
          <div
            key={p.name}
            style={{
              position: 'absolute',
              left: 0,
              right: 0,
              top: ROWS_TOP + i * ROW_H,
              height: ROW_H,
              fontSize: 15,
              color: COLORS.textSecondary,
              background: i % 2 === 1 ? 'rgba(255,255,255,0.018)' : undefined,
            }}
          >
            <div style={{position: 'absolute', left: 24, top: 0, height: ROW_H, display: 'flex', alignItems: 'center', gap: 10}}>
              <ProcIcon icon={p.icon} />
              <span style={{color: COLORS.textPrimary, fontWeight: hog ? 600 : 500}}>{p.name}</span>
            </div>
            <span
              style={{
                position: 'absolute',
                right: WIN.w - CPU_RIGHT,
                top: 7,
                fontFamily: FONTS.numeric,
                fontVariantNumeric: 'tabular-nums',
                fontWeight: hog ? 700 : 500,
                color: hog ? (highlight > 0.5 ? COLORS.textPrimary : COLORS.destructiveText) : COLORS.textSecondary,
              }}
            >
              {p.cpu}
            </span>
            {COLS.map((c) => (
              <span
                key={c.key}
                style={{position: 'absolute', right: WIN.w - c.right, top: 7, fontFamily: FONTS.numeric, fontVariantNumeric: 'tabular-nums', color: COLORS.textTertiary}}
              >
                {p[c.key]}
              </span>
            ))}
          </div>
        );
      })}

      <CpuLoadPanel t={t} />
    </>
  );
};

const ProcIcon: React.FC<{icon: string | null}> = ({icon}) => {
  if (icon === 'heymate') {
    return <Img src={staticFile('icon.png')} style={{width: 20, height: 20, borderRadius: 5}} />;
  }
  if (icon === null) {
    // Helper processes show the generic executable icon.
    return (
      <div style={{width: 20, height: 20, borderRadius: 5, background: COLORS.surface4, border: `1px solid ${COLORS.borderStrong}`, display: 'flex', alignItems: 'center', justifyContent: 'center'}}>
        <div style={{width: 8, height: 8, borderRadius: 2, background: COLORS.textTertiary}} />
      </div>
    );
  }
  return <div style={{width: 20, height: 20, borderRadius: 5, background: icon, opacity: 0.85}} />;
};

/** Bottom summary: System / User / Idle and a pinned-high CPU load graph. */
const CpuLoadPanel: React.FC<{t: number}> = ({t}) => {
  const panelTop = ROWS_TOP + PROCS.length * ROW_H + 10;
  const bars = 56;
  const shift = Math.floor(t * 6);
  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        top: panelTop,
        bottom: 0,
        borderTop: `1px solid ${COLORS.borderSubtle}`,
        background: COLORS.surface1,
        display: 'flex',
        alignItems: 'center',
        gap: 36,
        padding: '0 28px',
        fontSize: 14,
      }}
    >
      <div style={{display: 'grid', gridTemplateColumns: 'auto auto', gap: '4px 18px', color: COLORS.textTertiary}}>
        <span>System:</span>
        <span style={{color: COLORS.destructiveText, fontWeight: 600, textAlign: 'right'}}>21.8%</span>
        <span>User:</span>
        <span style={{color: COLORS.accentText, fontWeight: 600, textAlign: 'right'}}>74.1%</span>
        <span>Idle:</span>
        <span style={{color: COLORS.textSecondary, fontWeight: 600, textAlign: 'right'}}>4.1%</span>
      </div>
      <div style={{flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6}}>
        <div style={{fontSize: 12, fontWeight: 600, color: COLORS.textTertiary, letterSpacing: '0.08em'}}>CPU LOAD</div>
        <div style={{display: 'flex', alignItems: 'flex-end', gap: 2, height: 54, padding: 4, borderRadius: 6, background: '#0A0A0B', border: `1px solid ${COLORS.borderSubtle}`}}>
          {Array.from({length: bars}, (_, i) => {
            const k = i + shift;
            const h = 0.84 + 0.14 * Math.abs(Math.sin(k * 1.7) * Math.cos(k * 0.6));
            const sys = 0.2 + 0.06 * Math.abs(Math.sin(k * 2.3));
            return (
              <div key={i} style={{width: 3, height: 46 * h, display: 'flex', flexDirection: 'column'}}>
                <div style={{flex: 1 - sys, background: COLORS.accent, opacity: 0.85}} />
                <div style={{flex: sys, background: COLORS.destructive}} />
              </div>
            );
          })}
        </div>
      </div>
      <div style={{display: 'grid', gridTemplateColumns: 'auto auto', gap: '4px 18px', color: COLORS.textTertiary}}>
        <span>Threads:</span>
        <span style={{color: COLORS.textSecondary, fontWeight: 600, textAlign: 'right'}}>3,418</span>
        <span>Processes:</span>
        <span style={{color: COLORS.textSecondary, fontWeight: 600, textAlign: 'right'}}>612</span>
      </div>
    </div>
  );
};

/** Renders `code` spans (backticks) in mono inside the reply. */
const ReplyText: React.FC<{text: string}> = ({text}) => {
  const parts = text.split('`');
  return (
    <>
      {parts.map((part, i) =>
        i % 2 === 1 ? (
          <span key={i} style={{fontFamily: FONTS.mono, fontSize: 16, color: COLORS.codeText, whiteSpace: 'nowrap'}}>
            {part}
          </span>
        ) : (
          <span key={i}>{part}</span>
        ),
      )}
    </>
  );
};
