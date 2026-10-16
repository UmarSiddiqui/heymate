import React from 'react';
import {AbsoluteFill, Easing, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import type {CamKey, Cut, Segment} from './types';
import {AskChip, CalloutBubble, Chip, Keycaps, COLORS} from './ui';

export const FPS = 60;
const SRC_ASPECT = 16 / 9;

export const segLen = (s: Segment) => (s.to - s.from) / s.rate;
export const cutSeconds = (c: Cut) => c.segments.reduce((a, s) => a + segLen(s), 0);
export const cutFrames = (c: Cut) => segFrames(c.segments).total;

const segFrames = (segs: Segment[]) => {
  let acc = 0;
  const starts: number[] = [];
  for (const s of segs) {
    starts.push(Math.round(acc * FPS));
    acc += segLen(s);
  }
  return {starts, total: Math.round(acc * FPS)};
};

export const outToRaw = (segs: Segment[], t: number) => {
  let acc = 0;
  for (const s of segs) {
    const len = segLen(s);
    if (t < acc + len) return {raw: s.from + (t - acc) * s.rate, seg: s};
    acc += len;
  }
  const last = segs[segs.length - 1];
  return {raw: last.to, seg: last};
};

/** Raw → output seconds. Raw times inside a removed stretch snap to the next kept moment. */
export const rawToOut = (segs: Segment[], raw: number) => {
  let acc = 0;
  for (const s of segs) {
    if (raw < s.from) return acc;
    if (raw <= s.to) return acc + (raw - s.from) / s.rate;
    acc += segLen(s);
  }
  return acc;
};

const ease = Easing.bezier(0.45, 0, 0.2, 1);

const camAt = (keys: CamKey[], segs: Segment[], t: number) => {
  const ks = keys.map((k) => ({...k, o: rawToOut(segs, k.t)}));
  if (t <= ks[0].o) return ks[0];
  for (let i = 0; i < ks.length - 1; i++) {
    const a = ks[i];
    const b = ks[i + 1];
    if (t <= b.o) {
      const p = b.o === a.o ? 1 : ease((t - a.o) / (b.o - a.o));
      return {x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p, s: a.s + (b.s - a.s) * p};
    }
  }
  return ks[ks.length - 1];
};

/** Visible window of the source, in normalised source units. */
const viewport = (outW: number, outH: number, cam: {x: number; y: number; s: number}) => {
  const A = outW / outH;
  const wide = Math.abs(A - SRC_ASPECT) < 0.01;
  // Tall and square crops already enlarge the picture, so they zoom less.
  const s = wide ? cam.s : 1 + (cam.s - 1) * 0.55;
  const vw = Math.min(1, A / SRC_ASPECT) / s;
  const vh = Math.min(1, SRC_ASPECT / A) / s;
  const cx = Math.min(1 - vw / 2, Math.max(vw / 2, cam.x));
  const cy = Math.min(1 - vh / 2, Math.max(vh / 2, cam.y));
  return {vw, vh, left: cx - vw / 2, top: cy - vh / 2};
};

export const envelope = (raw: number, a: number, b: number, fade = 0.2) =>
  interpolate(raw, [a - fade, a, b, b + fade], [0, 1, 1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.33, 0, 0.2, 1),
  });

export const CutVideo: React.FC<{cut: Cut}> = ({cut}) => {
  const frame = useCurrentFrame();
  const {width, height} = useVideoConfig();
  const segs = cut.segments;
  const t = frame / FPS;
  const {raw, seg} = outToRaw(segs, t);
  const u = Math.min(width, height) / 1080;
  const vp = viewport(width, height, camAt(cut.demo.cam, segs, t));
  const vidW = width / vp.vw;
  const vidH = height / vp.vh;
  const toOut = (x: number, y: number) => ({px: ((x - vp.left) / vp.vw) * width, py: ((y - vp.top) / vp.vh) * height});
  const {starts} = segFrames(segs);
  const vertical = height > width;

  return (
    <AbsoluteFill style={{backgroundColor: COLORS.bg, overflow: 'hidden'}}>
      <div style={{position: 'absolute', left: -vp.left * vidW, top: -vp.top * vidH, width: vidW, height: vidH}}>
        {segs.map((s, i) => (
          <Sequence key={i} from={starts[i]} durationInFrames={Math.max(1, (starts[i + 1] ?? Math.round(cutSeconds(cut) * FPS)) - starts[i])} layout="none">
            <OffthreadVideo
              src={staticFile(cut.demo.src)}
              trimBefore={Math.round(s.from * FPS)}
              playbackRate={s.rate}
              muted={cut.muted || s.rate !== 1}
              style={{position: 'absolute', left: 0, top: 0, width: vidW, height: vidH}}
            />
          </Sequence>
        ))}
      </div>

      {cut.demo.callouts.map((c, i) => {
        const op = envelope(raw, c.from, c.to, 0.18);
        if (op <= 0) return null;
        const {px, py} = toOut(c.x, c.y);
        return <CalloutBubble key={i} text={c.text} px={px} py={py} place={c.place ?? 'above'} op={op} u={u} frameW={width} frameH={height} />;
      })}

      <Keycaps raw={raw} keys={cut.demo.keys} u={u} vertical={vertical} />

      {cut.demo.asks.map((a, i) => {
        const op = envelope(raw, a.from, a.to);
        return op > 0 ? <AskChip key={i} text={a.text} op={op} u={u} vertical={vertical} /> : null;
      })}

      {(cut.skips ?? []).map((s, i) => {
        const o = rawToOut(segs, s.at);
        const op = interpolate(t, [o - 0.01, o + 0.15, o + 1.5, o + 1.8], [0, 1, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
        return op > 0 ? (
          <Chip key={i} u={u} style={{left: '50%', transform: 'translateX(-50%)', top: (vertical ? 120 : 40) * u, opacity: op, color: COLORS.text}}>
            {s.text}
          </Chip>
        ) : null;
      })}

      <Chip u={u} style={{right: 28 * u, top: (vertical ? 70 : 28) * u, fontSize: 13 * u, opacity: 0.92}}>
        <span style={{width: 7 * u, height: 7 * u, borderRadius: 7 * u, background: '#E5484D', display: 'inline-block'}} />
        Real screen recording
      </Chip>
      {seg.rate !== 1 ? (
        <Chip u={u} style={{right: 28 * u, top: ((vertical ? 70 : 28) + 44) * u, color: COLORS.text}}>
          <span style={{color: COLORS.accentText}}>▸▸</span> {seg.rate}× speed
        </Chip>
      ) : null}
    </AbsoluteFill>
  );
};
