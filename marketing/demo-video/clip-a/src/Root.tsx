import React from 'react';
import {Composition, Series} from 'remotion';
import {CutVideo, FPS, cutFrames} from './lib/CutVideo';
import {EndCard, END_SECONDS, TITLE_SECONDS, Title} from './lib/ui';
import type {Cut} from './lib/types';
import {gifCut, keynoteMain, planetsMain, sizzleParts} from './demos';

type ReelProps = {cuts: Cut[]; title: boolean; end: boolean};

const OVERLAP = 20; // end card fades over the last frames of the video

const reelFrames = ({cuts, title, end}: ReelProps) =>
  (title ? Math.round(TITLE_SECONDS * FPS) : 0) + cuts.reduce((a, c) => a + cutFrames(c), 0) + (end ? Math.round(END_SECONDS * FPS) - OVERLAP : 0);

const Reel: React.FC<ReelProps> = ({cuts, title, end}) => (
  <Series>
    {title ? (
      <Series.Sequence durationInFrames={Math.round(TITLE_SECONDS * FPS)}>
        <Title />
      </Series.Sequence>
    ) : null}
    {cuts.map((c, i) => (
      <Series.Sequence key={i} durationInFrames={cutFrames(c)}>
        <CutVideo cut={c} />
      </Series.Sequence>
    ))}
    {end ? (
      <Series.Sequence offset={-OVERLAP} durationInFrames={Math.round(END_SECONDS * FPS)}>
        <EndCard />
      </Series.Sequence>
    ) : null}
  </Series>
);

const SIZES = {
  wide: [1920, 1080],
  square: [1080, 1080],
  vertical: [1080, 1920],
} as const;

const reels: {id: string; props: ReelProps; sizes: (keyof typeof SIZES)[]}[] = [
  {id: 'planets', props: {cuts: [planetsMain], title: true, end: true}, sizes: ['wide', 'square', 'vertical']},
  {id: 'keynote', props: {cuts: [keynoteMain], title: true, end: true}, sizes: ['wide', 'square', 'vertical']},
  {id: 'sizzle', props: {cuts: sizzleParts, title: true, end: true}, sizes: ['wide', 'vertical']},
  {id: 'gif', props: {cuts: [gifCut], title: false, end: false}, sizes: ['wide']},
];

export const RemotionRoot: React.FC = () => (
  <>
    {reels.flatMap((r) =>
      r.sizes.map((s) => (
        <Composition
          key={`${r.id}-${s}`}
          id={`${r.id}-${s}`}
          component={Reel}
          durationInFrames={reelFrames(r.props)}
          fps={FPS}
          width={SIZES[s][0]}
          height={SIZES[s][1]}
          defaultProps={r.props}
        />
      )),
    )}
  </>
);
