// Shared, stylized recreations of HeyMate / macOS surfaces.
import React from 'react';
import {AbsoluteFill, Img, useVideoConfig} from 'remotion';
import {COLORS, FONTS} from '../config';
import {ease, riseStyle, useLayout, useSpringIn, useTime} from './motion';

// ─── Backdrop ─────────────────────────────────────────────────────────────

export const Backdrop: React.FC<{children?: React.ReactNode}> = ({children}) => (
  <AbsoluteFill
    style={{
      backgroundColor: COLORS.background,
      backgroundImage:
        'radial-gradient(ellipse 70% 55% at 50% 38%, rgba(255,255,255,0.045), rgba(255,255,255,0) 70%)',
      fontFamily: FONTS.ui,
      color: COLORS.textPrimary,
      WebkitFontSmoothing: 'antialiased',
    }}
  >
    {children}
  </AbsoluteFill>
);

// ─── Feature scene layout: callout + stage ────────────────────────────────

type Rect = {x: number; y: number; w: number; h: number};

type FeatureLayoutProps = {
  title: string;
  sub: string;
  stageWidth: number;
  stageHeight: number;
  children: React.ReactNode;
  /** Extra element under the callout copy (e.g. brain chips). */
  extra?: React.ReactNode;
  /** Overlays drawn in stage space, above the stage (keycaps, captions). */
  overlay?: React.ReactNode;
  /**
   * Vertical (9:16) only: the part of the stage that must stay fully in view.
   * The stage is scaled up to fill the frame width with this region, and
   * anything outside it may be cropped by the frame edges.
   */
  verticalFocus?: Rect;
};

export const FeatureLayout: React.FC<FeatureLayoutProps> = ({
  title,
  sub,
  stageWidth,
  stageHeight,
  children,
  extra,
  overlay,
  verticalFocus,
}) => {
  const {vertical, width, height, stageOnly} = useLayout();
  const {t, frame} = useTime();
  const {durationInFrames} = useVideoConfig();
  const titleIn = useSpringIn(0.2, 'gentle');
  const subIn = useSpringIn(0.42, 'gentle');
  const extraIn = useSpringIn(0.7, 'gentle');
  const stageIn = useSpringIn(0.05, 'buddy');

  // Where the stage goes, in canvas pixels. `focus` is the stage region that
  // must be visible; `box` is where that region lands on the canvas.
  let focus: Rect = {x: 0, y: 0, w: stageWidth, h: stageHeight};
  let box: Rect;
  let calloutTop = 0;
  if (stageOnly) {
    const pad = 36;
    const s = Math.min((width - pad * 2) / stageWidth, (height - pad * 2) / stageHeight);
    box = {
      x: (width - stageWidth * s) / 2,
      y: (height - stageHeight * s) / 2,
      w: stageWidth * s,
      h: stageHeight * s,
    };
  } else if (vertical) {
    focus = verticalFocus ?? focus;
    const maxW = width - 60;
    const s = Math.min(maxW / focus.w, 1100 / focus.h, 1.6);
    const titleLines = title.split('\n').length;
    const calloutH = titleLines * 81 + 26 + 94 + (extra ? 120 : 0);
    const gap = 90;
    const groupH = calloutH + gap + focus.h * s;
    calloutTop = Math.max(120, (height - groupH) / 2 - 20);
    box = {x: (width - focus.w * s) / 2, y: calloutTop + calloutH + gap, w: focus.w * s, h: focus.h * s};
  } else {
    const area = {x: 760, y: 70, w: width - 760 - 70, h: height - 140};
    const s = Math.min(area.w / stageWidth, area.h / stageHeight);
    box = {
      x: area.x + (area.w - stageWidth * s) / 2,
      y: area.y + (area.h - stageHeight * s) / 2,
      w: stageWidth * s,
      h: stageHeight * s,
    };
  }
  const scale = box.w / focus.w;
  // A slow push-in keeps the frame alive without drawing attention.
  const drift = 1 + ease(t, [0, 8], [0, 0.018], (x) => x);
  const focusCenter = `${focus.x + focus.w / 2}px ${focus.y + focus.h / 2}px`;

  const calloutStyle: React.CSSProperties = vertical
    ? {position: 'absolute', left: 70, right: 70, top: calloutTop, textAlign: 'center'}
    : {
        position: 'absolute',
        left: 120,
        width: 560,
        top: 0,
        bottom: 0,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
      };

  return (
    <Backdrop>
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          width: stageWidth,
          height: stageHeight,
          transformOrigin: '0 0',
          transform: `translate(${box.x - focus.x * scale}px, ${box.y - focus.y * scale}px) scale(${scale})`,
        }}
      >
        <div
          style={{
            position: 'absolute',
            inset: 0,
            transformOrigin: focusCenter,
            transform: `scale(${drift * (0.94 + 0.06 * stageIn)}) translateY(${(1 - stageIn) * 40}px)`,
            // Web clips fade out at the end so they loop cleanly.
            opacity: Math.min(1, stageIn * 1.5) * (stageOnly ? 1 - ease(frame, [durationInFrames - 24, durationInFrames - 1]) : 1),
          }}
        >
          {children}
          {overlay}
        </div>
      </div>

      {vertical ? (
        // Keep the callout legible where a cropped stage runs underneath it.
        <div
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            top: 0,
            height: box.y - 20,
            background: `linear-gradient(180deg, ${COLORS.background} 85%, rgba(10,10,10,0))`,
          }}
        />
      ) : null}

      {stageOnly ? null : (
      <div style={calloutStyle}>
        <div
          style={{
            fontSize: vertical ? 76 : 62,
            fontWeight: 600,
            letterSpacing: '-0.025em',
            lineHeight: 1.06,
            whiteSpace: 'pre-line',
            ...riseStyle(titleIn, 28, 10),
          }}
        >
          {title}
        </div>
        <div
          style={{
            marginTop: vertical ? 26 : 24,
            fontSize: vertical ? 34 : 27,
            lineHeight: 1.38,
            color: COLORS.textSecondary,
            maxWidth: vertical ? undefined : 520,
            ...riseStyle(subIn, 20, 6),
          }}
        >
          {sub}
        </div>
        {extra ? <div style={{marginTop: vertical ? 30 : 40, ...riseStyle(extraIn, 16, 4)}}>{extra}</div> : null}
      </div>
      )}
    </Backdrop>
  );
};

// ─── Mac screen (bezel + wallpaper + menu bar) ────────────────────────────

export const MENU_BAR_H = 38;

export const MacScreen: React.FC<{
  width: number;
  height: number;
  children?: React.ReactNode;
  notch?: React.ReactNode;
  /** Drawn above everything, including the notch (pointers, highlights). */
  top?: React.ReactNode;
  /** 'full' date + time, 'compact' time only, 'none' hides menu-bar text (for tight crops). */
  menu?: 'full' | 'compact' | 'left-only' | 'none';
}> = ({width, height, children, notch, top, menu = 'full'}) => (
  <div
    style={{
      width,
      height,
      borderRadius: 30,
      padding: 12,
      background: 'linear-gradient(180deg, #1B1B1D 0%, #0C0C0D 100%)',
      boxShadow:
        '0 0 0 1px rgba(255,255,255,0.08), 0 50px 120px rgba(0,0,0,0.75), 0 18px 40px rgba(0,0,0,0.5)',
      boxSizing: 'border-box',
    }}
  >
    <div
      style={{
        position: 'relative',
        width: '100%',
        height: '100%',
        borderRadius: 18,
        overflow: 'hidden',
        background:
          'radial-gradient(ellipse 90% 70% at 50% 0%, #1A1A1C 0%, #0E0E0F 55%, #0A0A0A 100%)',
      }}
    >
      <MenuBar mode={menu} />
      {children}
      <div style={{position: 'absolute', left: 0, right: 0, top: 0, display: 'flex', justifyContent: 'center'}}>
        {notch}
      </div>
      {top}
    </div>
  </div>
);

export const MenuBar: React.FC<{mode: 'full' | 'compact' | 'left-only' | 'none'}> = ({mode}) => (
  <div
    style={{
      position: 'absolute',
      left: 0,
      right: 0,
      top: 0,
      height: MENU_BAR_H,
      display: 'flex',
      alignItems: 'center',
      padding: '0 22px',
      fontSize: 16,
      color: COLORS.textPrimary,
      background: 'rgba(0,0,0,0.55)',
      gap: 22,
    }}
  >
    {mode !== 'none' ? (
      <>
        <span style={{fontWeight: 700}}>HeyMate</span>
        {['File', 'Edit', 'View', 'Window'].map((m) => (
          <span key={m} style={{fontWeight: 500, color: 'rgba(245,245,247,0.9)'}}>
            {m}
          </span>
        ))}
      </>
    ) : null}
    {mode === 'full' || mode === 'compact' ? (
      <span style={{marginLeft: 'auto', fontWeight: 500}}>{mode === 'compact' ? '9:41 AM' : 'Sun 27 Sep\u00a0\u00a09:41 AM'}</span>
    ) : null}
  </div>
);

// ─── Notch shell ──────────────────────────────────────────────────────────

/** Black hardware-notch shape with the little flares where it meets the bezel. */
export const NotchShell: React.FC<{
  width: number;
  height: number;
  radius: number;
  children?: React.ReactNode;
  glow?: string;
}> = ({width, height, radius, children, glow}) => {
  const f = 10;
  const w = width + f * 2;
  const r = Math.min(radius, height / 2, width / 2);
  const d = `M0,0 Q${f},0 ${f},${f} L${f},${height - r} Q${f},${height} ${f + r},${height} L${w - f - r},${height} Q${w - f},${height} ${w - f},${height - r} L${w - f},${f} Q${w - f},0 ${w},0 Z`;
  return (
    <div style={{position: 'relative', width: w, height}}>
      <svg
        width={w}
        height={height}
        style={{
          position: 'absolute',
          inset: 0,
          overflow: 'visible',
          filter: `drop-shadow(0 18px 40px rgba(0,0,0,0.65))${glow ? ` drop-shadow(0 0 16px ${glow})` : ''}`,
        }}
      >
        <path d={d} fill={COLORS.notch} />
      </svg>
      <div style={{position: 'absolute', left: f, top: 0, width, height, overflow: 'hidden', borderRadius: `0 0 ${r}px ${r}px`}}>
        {children}
      </div>
    </div>
  );
};

// ─── Window chrome ────────────────────────────────────────────────────────

export const TrafficLights: React.FC<{size?: number}> = ({size = 13}) => (
  <div style={{display: 'flex', gap: size * 0.62}}>
    {['#FF5F57', '#FEBC2E', '#28C840'].map((c) => (
      <div
        key={c}
        style={{
          width: size,
          height: size,
          borderRadius: size,
          background: c,
          boxShadow: 'inset 0 0 0 0.5px rgba(0,0,0,0.25)',
        }}
      />
    ))}
  </div>
);

export const MacWindow: React.FC<{
  width: number;
  height: number;
  children?: React.ReactNode;
  style?: React.CSSProperties;
  background?: string;
}> = ({width, height, children, style, background = COLORS.background}) => (
  <div
    style={{
      position: 'relative',
      width,
      height,
      borderRadius: 16,
      background,
      overflow: 'hidden',
      boxShadow:
        '0 0 0 1px rgba(255,255,255,0.09), 0 40px 100px rgba(0,0,0,0.7), 0 12px 30px rgba(0,0,0,0.45)',
      ...style,
    }}
  >
    {children}
  </div>
);

// ─── Small controls ───────────────────────────────────────────────────────

export const Pill: React.FC<{
  children: React.ReactNode;
  bg?: string;
  color?: string;
  border?: string;
  style?: React.CSSProperties;
  size?: number;
}> = ({children, bg = COLORS.surface2, color = COLORS.textPrimary, border, style, size = 15}) => (
  <div
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      gap: 7,
      padding: `${size * 0.45}px ${size * 0.95}px`,
      borderRadius: 999,
      background: bg,
      color,
      fontSize: size,
      fontWeight: 600,
      border: border ? `1px solid ${border}` : undefined,
      whiteSpace: 'nowrap',
      ...style,
    }}
  >
    {children}
  </div>
);

export const Dot: React.FC<{color: string; size?: number; glow?: boolean}> = ({color, size = 9, glow}) => (
  <div
    style={{
      width: size,
      height: size,
      borderRadius: size,
      background: color,
      boxShadow: glow ? `0 0 ${size}px ${color}` : undefined,
      flexShrink: 0,
    }}
  />
);

export const Keycap: React.FC<{glyph: string; label: string; pressed: number}> = ({glyph, label, pressed}) => (
  <div
    style={{
      width: 96,
      height: 96,
      borderRadius: 18,
      background: `linear-gradient(180deg, ${COLORS.surface3}, ${COLORS.surface2})`,
      border: `1.5px solid ${pressed > 0.5 ? COLORS.accent : COLORS.borderStrong}`,
      boxShadow: `0 ${10 - pressed * 7}px 0 #050505, 0 ${16 - pressed * 10}px 30px rgba(0,0,0,0.6)${
        pressed > 0.01 ? `, 0 0 ${28 * pressed}px rgba(51,128,255,${0.45 * pressed})` : ''
      }`,
      transform: `translateY(${pressed * 7}px)`,
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 2,
      color: COLORS.textPrimary,
    }}
  >
    <div style={{fontSize: 40, lineHeight: 1, fontFamily: FONTS.numeric}}>{glyph}</div>
    <div style={{fontSize: 14, fontWeight: 600, color: COLORS.textSecondary}}>{label}</div>
  </div>
);

/** Live audio waveform bars. `level` 0–1 scales amplitude. */
export const Waveform: React.FC<{bars?: number; color: string; level: number; height?: number; seed?: number}> = ({
  bars = 5,
  color,
  level,
  height = 18,
  seed = 0,
}) => {
  const {frame} = useTime();
  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 3, height}}>
      {Array.from({length: bars}).map((_, i) => {
        const a =
          0.35 +
          0.65 *
            Math.abs(Math.sin(frame * 0.19 + i * 1.7 + seed) * Math.cos(frame * 0.07 + i * 0.9 + seed * 2));
        const h = Math.max(3, height * (0.2 + 0.8 * a * level));
        return <div key={i} style={{width: 3.5, height: h, borderRadius: 3, background: color}} />;
      })}
    </div>
  );
};

/** Face avatar from the app's built-in mate faces. */
export const Face: React.FC<{src: string; size: number}> = ({src, size}) => (
  <Img
    src={src}
    style={{
      width: size,
      height: size,
      borderRadius: size,
      objectFit: 'cover',
      flexShrink: 0,
      boxShadow: '0 0 0 1px rgba(255,255,255,0.08)',
    }}
  />
);
