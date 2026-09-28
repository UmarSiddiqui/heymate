// The full demo: scenes in order, joined by short cross-fades.
// Reorder or remove scenes by editing SCENES below; lengths live in config.ts.
import React from 'react';
import {AbsoluteFill, Audio, interpolate, staticFile, useVideoConfig} from 'remotion';
import {linearTiming, TransitionSeries} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {COLORS, FPS, MUSIC_FADE_SECONDS, MUSIC_SRC, MUSIC_VOLUME, SCENE_SECONDS, TRANSITION_FRAMES} from './config';
import {HookScene} from './scenes/HookScene';
import {LogoScene} from './scenes/LogoScene';
import {NotchScene} from './scenes/NotchScene';
import {VisionScene} from './scenes/VisionScene';
import {AgentsScene} from './scenes/AgentsScene';
import {MatesScene} from './scenes/MatesScene';
import {CloseScene} from './scenes/CloseScene';

export const SCENES: {id: keyof typeof SCENE_SECONDS; Component: React.FC}[] = [
  {id: 'hook', Component: HookScene},
  {id: 'logo', Component: LogoScene},
  {id: 'notch', Component: NotchScene},
  {id: 'vision', Component: VisionScene},
  {id: 'agents', Component: AgentsScene},
  {id: 'mates', Component: MatesScene},
  {id: 'close', Component: CloseScene},
];

export const sceneFrames = (id: keyof typeof SCENE_SECONDS) => Math.round(SCENE_SECONDS[id] * FPS);

export const TOTAL_FRAMES =
  SCENES.reduce((sum, s) => sum + sceneFrames(s.id), 0) - TRANSITION_FRAMES * (SCENES.length - 1);

const Music: React.FC = () => {
  const {durationInFrames, fps} = useVideoConfig();
  if (!MUSIC_SRC) return null;
  const fadeFrames = MUSIC_FADE_SECONDS * fps;
  return (
    <Audio
      src={staticFile(MUSIC_SRC)}
      volume={(f) =>
        MUSIC_VOLUME *
        interpolate(f, [0, fadeFrames, durationInFrames - fadeFrames, durationInFrames], [0, 1, 1, 0], {
          extrapolateLeft: 'clamp',
          extrapolateRight: 'clamp',
        })
      }
    />
  );
};

export const HeyMateDemo: React.FC = () => (
  <AbsoluteFill style={{backgroundColor: COLORS.background}}>
    <TransitionSeries>
      {SCENES.flatMap(({id, Component}, i) => {
        const items = [
          <TransitionSeries.Sequence key={id} durationInFrames={sceneFrames(id)} name={id}>
            <Component />
          </TransitionSeries.Sequence>,
        ];
        if (i < SCENES.length - 1) {
          items.push(
            <TransitionSeries.Transition
              key={`${id}-fade`}
              presentation={fade()}
              timing={linearTiming({durationInFrames: TRANSITION_FRAMES})}
            />,
          );
        }
        return items;
      })}
    </TransitionSeries>
    {/* ── MUSIC SLOT ── set MUSIC_SRC in src/config.ts */}
    <Music />
  </AbsoluteFill>
);
