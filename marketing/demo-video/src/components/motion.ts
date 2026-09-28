import React from 'react';
import {Easing, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {SPRINGS} from '../config';

type SpringName = keyof typeof SPRINGS;

/** 0 → 1 spring that starts `delay` seconds into the current sequence. */
export const useSpringIn = (delay = 0, name: SpringName = 'buddy') => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  return spring({frame: frame - Math.round(delay * fps), fps, config: SPRINGS[name]});
};

/** Spring evaluated at an explicit frame (for non-hook contexts). */
export const springAt = (frame: number, fps: number, delay = 0, name: SpringName = 'buddy') =>
  spring({frame: frame - Math.round(delay * fps), fps, config: SPRINGS[name]});

/** Clamped linear map with an ease-out curve by default. */
export const ease = (
  value: number,
  input: [number, number],
  output: [number, number] = [0, 1],
  easing: (t: number) => number = Easing.bezier(0.2, 0.8, 0.2, 1),
) =>
  interpolate(value, input, output, {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing,
  });

/** Seconds → frames helper bound to the current composition. */
export const useTime = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  return {frame, fps, t: frame / fps, f: (s: number) => Math.round(s * fps)};
};

/** Fade + rise + slight blur-to-sharp. `p` is 0 → 1. */
export const riseStyle = (p: number, distance = 24, blur = 8): React.CSSProperties => ({
  opacity: Math.min(1, p * 1.4),
  transform: `translateY(${(1 - p) * distance}px)`,
  filter: blur > 0 ? `blur(${Math.max(0, (1 - p) * blur)}px)` : undefined,
});

/**
 * 'full' renders callouts + UI. 'stage' renders only the UI, filling the
 * frame — used for the silent web clips on the landing page.
 */
export const LayoutModeContext = React.createContext<'full' | 'stage'>('full');

/** Orientation-aware layout facts for the current composition. */
export const useLayout = () => {
  const {width, height} = useVideoConfig();
  const mode = React.useContext(LayoutModeContext);
  const vertical = height > width && mode === 'full';
  // One "unit" = 1px at 1080-short-side. Type scales from this.
  const unit = Math.min(width, height) / 1080;
  return {width, height, vertical, unit, stageOnly: mode === 'stage'};
};
