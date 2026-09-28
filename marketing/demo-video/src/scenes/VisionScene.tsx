// Scene 4 — push-to-talk, the buddy looks, flies to the bug, and answers.
import React from 'react';
import {COLORS, COPY, FONTS} from '../config';
import {BuddyCursor} from '../components/Icons';
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

// Editor geometry (window-local)
const WIN = {x: 36, y: 104, w: 904, h: 488};
const CODE_TOP = 64;
const LINE_H = 29;
const GUTTER = 64;
const CHAR_W = 10.2; // 17px SF Mono advance

type Tok = [string, string?];
const K = COLORS.textPrimary;
const KW = '#F28FC0';
const TY = COLORS.codeText;
const PR = '#8FD6C6';
const ST = '#E6B673';
const CM = COLORS.textTertiary;

const CODE: Tok[][] = [
  [['struct ', KW], ['CheckoutView', TY], [': ', K], ['View', TY], [' {', K]],
  [['    let ', KW], ['items', PR], [': [', K], ['CartItem', TY], [']', K]],
  [['    let ', KW], ['shipping', PR], [': ', K], ['Decimal', TY]],
  [['    var ', KW], ['total', PR], [': ', K], ['Decimal', TY], ['? { items.', K], ['isEmpty', PR], [' ? ', K], ['nil', KW], [' : items.', K], ['sum', PR], [' }', K]],
  [],
  [['    var ', KW], ['grandTotal', PR], [': ', K], ['Decimal', TY], [' {', K]],
  [['        ', K], ['total + shipping', K]],
  [['    }', K]],
  [],
  [['    var ', KW], ['body', PR], [': ', K], ['some ', KW], ['View', TY], [' {', K]],
  [['        ', K], ['SummaryRow', TY], ['(', K], ['"Total"', ST], [', value: grandTotal)', K]],
  [['    }', K]],
  [['}', K]],
];
const FIRST_LINE = 36;
const ERROR_ROW = 6; // line 42

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

  // Buddy flight: notch → end of line 42 along an arc.
  const errorLineY = WIN.y + CODE_TOP + ERROR_ROW * LINE_H;
  const target = {x: WIN.x + GUTTER + 26 + CHAR_W * 24 + 8, y: errorLineY + 8};
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
      verticalFocus={{x: 40, y: 0, w: 840, h: 690}}
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
                width: 400,
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
            <div
              style={{
                height: 46,
                display: 'flex',
                alignItems: 'center',
                padding: '0 18px',
                borderBottom: `1px solid ${COLORS.borderSubtle}`,
                background: COLORS.surface1,
              }}
            >
              <TrafficLights size={12} />
              <div style={{flex: 1, textAlign: 'center', fontSize: 15, fontWeight: 600, color: COLORS.textSecondary, marginRight: 50}}>
                CheckoutView.swift — Shop
              </div>
            </div>
            {/* Error line highlight */}
            <div
              style={{
                position: 'absolute',
                left: 0,
                right: 0,
                top: CODE_TOP + ERROR_ROW * LINE_H - 3,
                height: LINE_H,
                background: `rgba(229,72,77,${0.1 * (1 - highlight)})`,
              }}
            />
            <div
              style={{
                position: 'absolute',
                left: GUTTER + 26 + CHAR_W * 8 - 10,
                top: CODE_TOP + ERROR_ROW * LINE_H - 5,
                width: CHAR_W * 16 + 20,
                height: LINE_H + 4,
                borderRadius: 8,
                background: `rgba(51,128,255,${0.16 * highlight})`,
                boxShadow: `0 0 0 ${1.5 * highlight}px rgba(51,128,255,${0.9 * highlight}), 0 0 ${24 * highlight * (0.6 + 0.4 * pulse)}px rgba(51,128,255,${0.45 * highlight})`,
                transform: `scale(${0.9 + 0.1 * highlight})`,
              }}
            />
            {CODE.map((line, i) => (
              <div
                key={i}
                style={{
                  position: 'absolute',
                  left: 0,
                  top: CODE_TOP + i * LINE_H,
                  height: LINE_H,
                  display: 'flex',
                  fontFamily: FONTS.mono,
                  fontSize: 17,
                  whiteSpace: 'pre',
                }}
              >
                <span style={{width: GUTTER, textAlign: 'right', color: i === ERROR_ROW ? COLORS.destructiveText : '#55555C'}}>
                  {FIRST_LINE + i}
                </span>
                <span style={{marginLeft: 26}}>
                  {line.map(([text, color], j) => (
                    <span
                      key={j}
                      style={{
                        color: color ?? K,
                        textDecoration: i === ERROR_ROW && text.trim() ? 'underline wavy' : undefined,
                        textDecorationColor: i === ERROR_ROW ? `rgba(255,99,105,${1 - highlight * 0.7})` : undefined,
                        textUnderlineOffset: 5,
                      }}
                    >
                      {text}
                    </span>
                  ))}
                </span>
              </div>
            ))}
            {/* Inline compiler error */}
            <div
              style={{
                position: 'absolute',
                left: GUTTER + 26 + CHAR_W * 24 + 34,
                top: CODE_TOP + ERROR_ROW * LINE_H - 1,
                height: LINE_H - 4,
                display: 'flex',
                alignItems: 'center',
                gap: 8,
                padding: '0 12px',
                borderRadius: 7,
                background: 'rgba(229,72,77,0.16)',
                color: COLORS.destructiveText,
                fontSize: 14,
                fontWeight: 600,
                whiteSpace: 'nowrap',
                opacity: 1 - highlight,
              }}
            >
              <Dot color={COLORS.destructive} size={8} />
              Binary operator &apos;+&apos; cannot be applied to &apos;Decimal?&apos;
            </div>
          </MacWindow>
        </div>
      </MacScreen>
    </FeatureLayout>
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
