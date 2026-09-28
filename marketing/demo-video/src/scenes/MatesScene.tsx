// Scene 6 — Mates: a small team with a job, memory, and a schedule.
import React from 'react';
import {staticFile} from 'remotion';
import {COLORS, COPY} from '../config';
import {
  ArrowUpIcon,
  CheckIcon,
  ChevronDownIcon,
  CpuIcon,
  HistoryIcon,
  MicIcon,
  PanelIcon,
  PaperclipIcon,
  PlusIcon,
  SearchIcon,
} from '../components/Icons';
import {ease, springAt, useTime} from '../components/motion';
import {Face, FeatureLayout, MacWindow, TrafficLights} from '../components/UI';

const WIN_W = 1000;
const WIN_H = 640;
const SIDEBAR_W = 268;
const PANEL_W = 262;

type MateRow = {name: string; job: string; face: string; badge?: number};
const PINNED: MateRow = {name: 'First Mate', job: 'The one chat that runs the others', face: 'faces/peach.jpg'};
const MATES: MateRow[] = [
  {name: 'Comments', job: 'Reads my YouTube comments', face: 'faces/styled-guy.jpg'},
  {name: 'Builds', job: 'Coding agent for side projects', face: 'faces/robot.jpg'},
  {name: 'Inbox', job: 'Morning mail brief', face: 'faces/amber.jpg', badge: 2},
  {name: 'Research', job: 'Tracks notch-app competitors', face: 'faces/anime-guy.jpg', badge: 1},
];

const MESSAGE = [
  '38 new comments on “I put an AI in my MacBook notch”.',
  '•  21 want a download link. Top ask by far.',
  '•  6 ask if it works without a notch. It does.',
  '•  4 feature requests: Spotify controls, custom wake word.',
  'Most-liked: “the cursor flying to the bug is the coolest thing I’ve seen this year.”',
];

export const MatesScene: React.FC = () => {
  const {t, frame, fps} = useTime();

  const row = (i: number) => springAt(frame, fps, 0.35 + i * 0.09, 'buddy');
  const badge = (i: number) => springAt(frame, fps, 1.2 + i * 0.15, 'control');
  const msgLine = (i: number) => ease(t, [1.15 + i * 0.32, 1.5 + i * 0.32]);
  const memoryIn = springAt(frame, fps, 2.7, 'buddy');
  const routineIn = springAt(frame, fps, 3.2, 'buddy');
  const routineDone = ease(t, [4.4, 4.65]);

  const Row: React.FC<{m: MateRow; i: number; selected?: boolean}> = ({m, i, selected}) => (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 12,
        padding: '9px 10px',
        borderRadius: 12,
        background: selected ? COLORS.surface3 : 'transparent',
        opacity: Math.min(1, row(i) * 1.4),
        transform: `translateX(${(1 - row(i)) * -18}px)`,
      }}
    >
      <Face src={staticFile(m.face)} size={36} />
      <div style={{flex: 1, minWidth: 0}}>
        <div style={{fontSize: 16, fontWeight: 600}}>{m.name}</div>
        <div style={{fontSize: 13, color: COLORS.textSecondary, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis'}}>
          {m.job}
        </div>
      </div>
      {m.badge ? (
        <div
          style={{
            width: 22,
            height: 22,
            borderRadius: 22,
            background: COLORS.accent,
            fontSize: 12,
            fontWeight: 700,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            transform: `scale(${badge(m.badge === 2 ? 0 : 1)})`,
          }}
        >
          {m.badge}
        </div>
      ) : null}
    </div>
  );

  return (
    <FeatureLayout title={COPY.mates.title} sub={COPY.mates.sub} stageWidth={WIN_W} stageHeight={WIN_H}>
      <MacWindow width={WIN_W} height={WIN_H}>
        {/* Sidebar */}
        <div
          style={{
            position: 'absolute',
            left: 0,
            top: 0,
            bottom: 0,
            width: SIDEBAR_W,
            background: COLORS.surface1,
            borderRight: `1px solid ${COLORS.borderSubtle}`,
            padding: '0 12px',
            boxSizing: 'border-box',
          }}
        >
          <div style={{position: 'absolute', left: 20, top: 20}}>
            <TrafficLights size={13} />
          </div>
          <div
            style={{
              marginTop: 54,
              height: 38,
              borderRadius: 10,
              background: COLORS.surface2,
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              padding: '0 12px',
              fontSize: 15,
              color: COLORS.textTertiary,
            }}
          >
            <SearchIcon size={15} />
            Search mates
          </div>
          <div style={{marginTop: 14, display: 'flex', alignItems: 'center', gap: 10, padding: '0 10px', fontSize: 16, fontWeight: 600}}>
            <PlusIcon size={16} />
            New mate
          </div>
          <div style={{marginTop: 20, padding: '0 10px', fontSize: 13, fontWeight: 600, color: COLORS.textTertiary}}>Pinned</div>
          <div style={{marginTop: 6}}>
            <Row m={PINNED} i={0} />
          </div>
          <div style={{marginTop: 14, padding: '0 10px', fontSize: 13, fontWeight: 600, color: COLORS.textTertiary}}>Mates</div>
          <div style={{marginTop: 6, display: 'flex', flexDirection: 'column', gap: 2}}>
            {MATES.map((m, i) => (
              <Row key={m.name} m={m} i={i + 1} selected={i === 0} />
            ))}
          </div>
        </div>

        {/* Chat */}
        <div style={{position: 'absolute', left: SIDEBAR_W, right: PANEL_W, top: 0, bottom: 0}}>
          <div
            style={{
              height: 84,
              display: 'flex',
              alignItems: 'center',
              gap: 14,
              padding: '0 24px',
              borderBottom: `1px solid ${COLORS.borderSubtle}`,
            }}
          >
            <Face src={staticFile('faces/styled-guy.jpg')} size={44} />
            <div style={{flex: 1, minWidth: 0}}>
              <div style={{fontSize: 22, fontWeight: 600}}>Comments</div>
              <div style={{fontSize: 14, color: COLORS.textSecondary, whiteSpace: 'nowrap'}}>Reads my YouTube comments every morning</div>
            </div>
            <div style={{display: 'flex', gap: 14, color: COLORS.textSecondary}}>
              <HistoryIcon size={18} />
              <PanelIcon size={18} />
            </div>
          </div>
          <div style={{padding: '22px 24px 0'}}>
            <div style={{display: 'flex', alignItems: 'center', gap: 10, opacity: msgLine(0)}}>
              <Face src={staticFile('faces/styled-guy.jpg')} size={24} />
              <span style={{fontSize: 15, fontWeight: 600}}>Comments</span>
              <span style={{fontSize: 13, color: COLORS.textTertiary}}>8:30 AM</span>
            </div>
            {MESSAGE.map((line, i) => (
              <div
                key={i}
                style={{
                  marginTop: i === 0 ? 12 : i === MESSAGE.length - 1 ? 14 : 6,
                  fontSize: 16.5,
                  lineHeight: 1.45,
                  opacity: msgLine(i),
                  transform: `translateY(${(1 - msgLine(i)) * 8}px)`,
                  color: i === MESSAGE.length - 1 ? COLORS.textSecondary : COLORS.textPrimary,
                }}
              >
                {line}
              </div>
            ))}
          </div>
          <div
            style={{
              position: 'absolute',
              left: 20,
              right: 20,
              bottom: 20,
              height: 84,
              borderRadius: 18,
              background: COLORS.surface1,
              border: `1px solid ${COLORS.borderSubtle}`,
              padding: '12px 16px',
              boxSizing: 'border-box',
            }}
          >
            <div style={{fontSize: 16, color: COLORS.textTertiary}}>Message Comments</div>
            <div style={{marginTop: 12, display: 'flex', alignItems: 'center', gap: 14, color: COLORS.textSecondary}}>
              <PaperclipIcon size={16} />
              <MicIcon size={16} />
              <div style={{marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 6, fontSize: 13}}>
                <CpuIcon size={13} />
                Claude · Opus 5.5
                <ChevronDownIcon size={12} />
              </div>
              <ArrowUpIcon size={16} />
            </div>
          </div>
        </div>

        {/* Inspector: memory + routine */}
        <div
          style={{
            position: 'absolute',
            right: 0,
            top: 0,
            bottom: 0,
            width: PANEL_W,
            background: COLORS.surface1,
            borderLeft: `1px solid ${COLORS.borderSubtle}`,
            padding: '26px 18px',
            boxSizing: 'border-box',
          }}
        >
          <div style={{opacity: Math.min(1, memoryIn * 1.4), transform: `translateY(${(1 - memoryIn) * 16}px)`}}>
            <div style={{fontSize: 13, fontWeight: 600, color: COLORS.textTertiary}}>Memory</div>
            <div
              style={{
                marginTop: 8,
                borderRadius: 12,
                background: COLORS.surface2,
                padding: '12px 14px',
                fontSize: 15,
                lineHeight: 1.4,
              }}
            >
              Channel: build-in-public Mac apps. Skip spam.
            </div>
          </div>
          <div style={{marginTop: 24, opacity: Math.min(1, routineIn * 1.4), transform: `translateY(${(1 - routineIn) * 20}px)`}}>
            <div style={{fontSize: 13, fontWeight: 600, color: COLORS.textTertiary}}>Routines</div>
            <div
              style={{
                marginTop: 8,
                borderRadius: 14,
                background: COLORS.surface2,
                border: `1px solid ${COLORS.borderStrong}`,
                padding: '14px 14px',
                boxShadow: `0 ${18 * routineIn}px ${40 * routineIn}px rgba(0,0,0,0.45)`,
              }}
            >
              <div style={{fontSize: 16, fontWeight: 600, lineHeight: 1.3}}>Summarise new YouTube comments</div>
              <div style={{marginTop: 6, fontSize: 14, color: COLORS.textSecondary}}>Daily at 8:30am</div>
              <div style={{marginTop: 8, display: 'flex', alignItems: 'center', gap: 6, fontSize: 14, height: 20}}>
                <span style={{position: 'relative', display: 'flex', alignItems: 'center', gap: 6}}>
                  <span style={{color: COLORS.success, opacity: routineDone, display: 'flex', alignItems: 'center', gap: 6}}>
                    <CheckIcon size={14} stroke={2.6} /> Done · 8:31 AM
                  </span>
                  <span style={{position: 'absolute', left: 0, color: COLORS.accentText, opacity: 1 - routineDone, whiteSpace: 'nowrap'}}>
                    Running…
                  </span>
                </span>
              </div>
              <div style={{marginTop: 10, display: 'flex', gap: 14, fontSize: 14, fontWeight: 600, color: COLORS.textSecondary}}>
                <span>Pause</span>
                <span>Run now</span>
                <span>Edit</span>
              </div>
            </div>
          </div>
        </div>
      </MacWindow>
    </FeatureLayout>
  );
};
