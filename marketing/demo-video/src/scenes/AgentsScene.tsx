// Scene 5 — an agent plans read-only, you approve, it runs, you can undo.
import React from 'react';
import {COLORS, COPY, FONTS} from '../config';
import {CheckIcon, ChevronDownIcon, ClockIcon, CpuIcon, FileIcon, FolderIcon, PlanIcon, SystemPointer, UndoIcon} from '../components/Icons';
import {ease, springAt, useLayout, useTime} from '../components/motion';
import {Dot, FeatureLayout, MacWindow, TrafficLights} from '../components/UI';

const WIN_W = 1000;
const WIN_H = 600;

// Beats (seconds)
const APPROVE_AT = 2.85;
const STEP_DONE = [3.55, 4.15, 4.75];
const DONE_AT = 5.05;

const PLAN = [
  'Add CheckoutTotalTests.swift covering nil, zero and normal totals.',
  'Change line 42 of CheckoutView.swift to use (total ?? 0) + shipping.',
  'Run the test target and report the result.',
];

const mix = (a: string, b: string, p: number) => {
  const pa = [1, 3, 5].map((i) => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map((i) => parseInt(b.slice(i, i + 2), 16));
  return `rgb(${pa.map((v, i) => Math.round(v + (pb[i] - v) * p)).join(',')})`;
};

const BrainChips: React.FC = () => {
  const {vertical} = useLayout();
  return (
    <div style={{display: 'flex', flexDirection: 'column', alignItems: vertical ? 'center' : 'flex-start', gap: 14}}>
      <div style={{fontSize: vertical ? 24 : 20, color: COLORS.textTertiary, fontWeight: 500}}>{COPY.agents.brainsLabel}</div>
      <div style={{display: 'flex', gap: 12}}>
        {COPY.agents.brains.map((b, i) => (
          <div
            key={b}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 10,
              padding: '10px 18px',
              borderRadius: 12,
              background: COLORS.surface1,
              border: `1px solid ${i === 0 ? 'rgba(51,128,255,0.55)' : COLORS.borderSubtle}`,
              fontFamily: FONTS.mono,
              fontSize: vertical ? 24 : 21,
              color: i === 0 ? COLORS.textPrimary : COLORS.textSecondary,
            }}
          >
            <span style={{color: COLORS.textTertiary}}>$</span>
            {b}
          </div>
        ))}
      </div>
    </div>
  );
};

export const AgentsScene: React.FC = () => {
  const {t, frame, fps} = useTime();

  const cardIn = springAt(frame, fps, 0.35, 'buddy');
  const planLine = (i: number) => ease(t, [0.7 + i * 0.12, 1.0 + i * 0.12]);

  const running = ease(t, [APPROVE_AT + 0.05, APPROVE_AT + 0.35]);
  const done = ease(t, [DONE_AT, DONE_AT + 0.35]);
  const stateColor =
    done > 0 ? mix(COLORS.accent, COLORS.success, done) : mix(COLORS.warning, COLORS.accent, running);
  const phase = t < APPROVE_AT + 0.05 ? 'plan' : t < DONE_AT ? 'run' : 'done';

  const badge = {
    plan: {text: 'Read the plan', color: COLORS.warningText},
    run: {text: 'Running', color: COLORS.accentText},
    done: {text: 'Done', color: COLORS.success},
  }[phase];
  const status = {
    plan: 'Plan ready for review',
    run: `Running · 0:${String(Math.max(0, Math.floor((t - APPROVE_AT) * 9))).padStart(2, '0')}`,
    done: 'Finished. 2 files changed, 3 tests passed.',
  }[phase];

  // Pointer glides to "Approve plan" and clicks.
  const pp = ease(t, [1.5, APPROVE_AT - 0.1]);
  const pOut = ease(t, [APPROVE_AT + 0.4, 4.2]);
  const approveBtn = {x: 40 + 26 + 150 + 12 + 80, y: 150 + 372};
  const px = 820 + (approveBtn.x - 820) * pp + 180 * pOut;
  const py = 610 + (approveBtn.y - 610) * pp + 60 * pOut;
  const press = ease(t, [APPROVE_AT - 0.1, APPROVE_AT]) * (1 - ease(t, [APPROVE_AT + 0.02, APPROVE_AT + 0.15]));
  const pointerOpacity = ease(t, [1.3, 1.6]) * (1 - ease(t, [3.8, 4.2]));

  const buttonsOut = ease(t, [APPROVE_AT + 0.15, APPROVE_AT + 0.4]);
  const receiptIn = springAt(frame, fps, DONE_AT + 0.15, 'buddy');

  return (
    <FeatureLayout
      title={COPY.agents.title}
      sub={COPY.agents.sub}
      stageWidth={WIN_W}
      stageHeight={WIN_H}
      extra={<BrainChips />}
      verticalFocus={{x: 30, y: 36, w: 940, h: 540}}
    >
      <MacWindow width={WIN_W} height={WIN_H}>
        <div style={{position: 'absolute', left: 20, top: 20}}>
          <TrafficLights size={13} />
        </div>
        <div style={{position: 'absolute', left: 40, top: 58, right: 40, display: 'flex', alignItems: 'flex-start'}}>
          <div>
            <div style={{fontSize: 32, fontWeight: 600, letterSpacing: '-0.01em'}}>Agents</div>
            <div style={{marginTop: 4, fontSize: 16, color: COLORS.textSecondary}}>
              1 working. Talk answers now; agents do work over time.
            </div>
          </div>
          <div
            style={{
              marginLeft: 'auto',
              marginTop: 8,
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              padding: '7px 12px',
              borderRadius: 10,
              border: `1px solid ${COLORS.borderSubtle}`,
              fontSize: 14,
              fontWeight: 500,
              color: COLORS.textSecondary,
            }}
          >
            <CpuIcon size={14} />
            Claude · Opus 5.5
            <ChevronDownIcon size={13} />
          </div>
        </div>

        {/* Agent card */}
        <div
          style={{
            position: 'absolute',
            left: 40,
            right: 40,
            top: 150,
            borderRadius: 18,
            border: `1.5px solid ${stateColor}`,
            background: `linear-gradient(135deg, ${stateColor.replace('rgb', 'rgba').replace(')', ',0.10)')} 0%, rgba(26,26,28,0.6) 45%, ${COLORS.surface1} 100%)`,
            boxShadow: `0 0 40px ${stateColor.replace('rgb', 'rgba').replace(')', ',0.12)')}`,
            padding: '22px 26px',
            boxSizing: 'border-box',
            opacity: Math.min(1, cardIn * 1.4),
            transform: `translateY(${(1 - cardIn) * 30}px)`,
          }}
        >
          <div style={{display: 'flex', alignItems: 'center', gap: 12}}>
            <PlanIcon size={20} color={stateColor} />
            <div style={{fontSize: 21, fontWeight: 600}}>Test the optional checkout total</div>
            <div
              style={{
                marginLeft: 'auto',
                padding: '5px 12px',
                borderRadius: 8,
                fontSize: 14,
                fontWeight: 600,
                color: badge.color,
                background: `${badge.color}22`,
                display: 'flex',
                alignItems: 'center',
                gap: 7,
              }}
            >
              {phase === 'run' ? <Spinner color={badge.color} /> : null}
              {phase === 'done' ? <CheckIcon size={14} stroke={2.4} /> : null}
              {badge.text}
            </div>
          </div>
          <div style={{marginLeft: 32, marginTop: 4, fontSize: 14, color: COLORS.textTertiary}}>
            Claude Code · Sandbox · checkout-total-test
          </div>
          <div style={{marginTop: 14, fontSize: 16, color: COLORS.textSecondary}}>{status}</div>

          <div
            style={{
              marginTop: 12,
              borderRadius: 14,
              background: 'rgba(20,20,22,0.9)',
              border: `1px solid ${COLORS.borderSubtle}`,
              padding: '16px 18px',
            }}
          >
            <div style={{fontSize: 14, fontWeight: 600, color: COLORS.textSecondary}}>The plan</div>
            {PLAN.map((line, i) => {
              const stepDone = ease(t, [STEP_DONE[i], STEP_DONE[i] + 0.2]);
              const active = phase === 'run' && t < STEP_DONE[i] && (i === 0 || t >= STEP_DONE[i - 1]);
              return (
                <div
                  key={i}
                  style={{
                    marginTop: 10,
                    display: 'flex',
                    alignItems: 'center',
                    gap: 12,
                    fontSize: 16,
                    opacity: planLine(i),
                    transform: `translateY(${(1 - planLine(i)) * 8}px)`,
                  }}
                >
                  <div style={{width: 22, height: 22, flexShrink: 0, position: 'relative'}}>
                    <div
                      style={{
                        position: 'absolute',
                        inset: 0,
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        fontSize: 15,
                        color: COLORS.textTertiary,
                        opacity: active ? 0 : 1 - stepDone,
                      }}
                    >
                      {i + 1}.
                    </div>
                    {active ? (
                      <div style={{position: 'absolute', inset: 2}}>
                        <Spinner color={COLORS.accentText} size={18} />
                      </div>
                    ) : null}
                    <div
                      style={{
                        position: 'absolute',
                        inset: 0,
                        borderRadius: 22,
                        background: COLORS.success,
                        color: '#06281B',
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        opacity: stepDone,
                        transform: `scale(${0.5 + 0.5 * stepDone})`,
                      }}
                    >
                      <CheckIcon size={14} stroke={3} />
                    </div>
                  </div>
                  <span style={{color: stepDone > 0.5 ? COLORS.textSecondary : COLORS.textPrimary}}>{line}</span>
                </div>
              );
            })}
            <div style={{marginTop: 14, fontSize: 15, opacity: planLine(3)}}>Files: 1 new, 1 edited. Nothing else changes.</div>
            <div style={{marginTop: 4, fontSize: 13, color: COLORS.textTertiary, opacity: planLine(3), height: 18, position: 'relative'}}>
              <span style={{position: 'absolute', opacity: 1 - running}}>Nothing has been written yet.</span>
              <span style={{position: 'absolute', opacity: running}}>Undo snapshot saved before the first write.</span>
            </div>
          </div>

          {/* Buttons → receipt */}
          <div style={{position: 'relative', marginTop: 18, height: 44}}>
            <div
              style={{
                position: 'absolute',
                inset: 0,
                display: 'flex',
                alignItems: 'center',
                gap: 12,
                opacity: (1 - buttonsOut) * planLine(4),
              }}
            >
              <Btn>Open thread</Btn>
              <Btn primary pressed={press}>
                Approve plan
              </Btn>
              <Btn ghost>Dismiss</Btn>
              <Btn ghost muted>
                Take over
              </Btn>
              <div style={{marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8, fontSize: 15, color: COLORS.textSecondary}}>
                <FolderIcon size={16} />
                Open folder
              </div>
            </div>
            <div
              style={{
                position: 'absolute',
                inset: 0,
                display: 'flex',
                alignItems: 'center',
                gap: 22,
                padding: '0 16px',
                borderRadius: 12,
                background: 'rgba(20,20,22,0.9)',
                border: `1px solid ${COLORS.borderSubtle}`,
                fontSize: 15,
                color: COLORS.textSecondary,
                opacity: Math.min(1, receiptIn * 1.4),
                transform: `translateY(${(1 - receiptIn) * 14}px)`,
              }}
            >
              <span style={{fontWeight: 600, color: COLORS.textPrimary}}>Completion receipt</span>
              <span style={{display: 'flex', alignItems: 'center', gap: 6}}>
                <ClockIcon size={15} /> 2m elapsed
              </span>
              <span style={{display: 'flex', alignItems: 'center', gap: 6}}>
                <FileIcon size={15} /> 2 files changed
              </span>
              <span style={{display: 'flex', alignItems: 'center', gap: 6}}>
                <Dot color={COLORS.success} size={7} /> Ready undo
              </span>
              <span
                style={{
                  marginLeft: 'auto',
                  display: 'flex',
                  alignItems: 'center',
                  gap: 6,
                  fontWeight: 600,
                  color: COLORS.textPrimary,
                  padding: '5px 12px',
                  borderRadius: 999,
                  background: COLORS.surface3,
                }}
              >
                <UndoIcon size={15} /> Undo
              </span>
            </div>
          </div>
        </div>

        <div style={{position: 'absolute', left: px - 4, top: py - 3, opacity: pointerOpacity}}>
          <SystemPointer size={30} press={press} />
        </div>
      </MacWindow>
    </FeatureLayout>
  );
};

const Btn: React.FC<{children: React.ReactNode; primary?: boolean; ghost?: boolean; muted?: boolean; pressed?: number}> = ({
  children,
  primary,
  ghost,
  muted,
  pressed = 0,
}) => (
  <div
    style={{
      height: 42,
      padding: '0 20px',
      borderRadius: 999,
      display: 'flex',
      alignItems: 'center',
      fontSize: 16,
      fontWeight: 600,
      whiteSpace: 'nowrap',
      background: primary ? COLORS.accent : ghost ? 'transparent' : COLORS.surface3,
      color: primary ? '#fff' : muted ? COLORS.textSecondary : ghost ? COLORS.accentText : COLORS.textPrimary,
      boxShadow: primary ? `0 6px 20px rgba(51,128,255,${0.35 + pressed * 0.3})` : undefined,
      transform: `scale(${1 - pressed * 0.05})`,
      filter: pressed ? `brightness(${1 - pressed * 0.15})` : undefined,
    }}
  >
    {children}
  </div>
);

const Spinner: React.FC<{color: string; size?: number}> = ({color, size = 14}) => {
  const {frame} = useTime();
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" style={{transform: `rotate(${frame * 9}deg)`}}>
      <circle cx="10" cy="10" r="7.5" fill="none" stroke={color} strokeOpacity={0.25} strokeWidth={2.4} />
      <path d="M10 2.5a7.5 7.5 0 0 1 7.5 7.5" fill="none" stroke={color} strokeWidth={2.4} strokeLinecap="round" />
    </svg>
  );
};
