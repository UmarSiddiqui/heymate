import React from 'react';
import {interpolate, staticFile, useVideoConfig} from 'remotion';
import {Audio} from '@remotion/media';
import {linearTiming, TransitionSeries} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {MeetHook} from './meet/Hook';
import {MeetHello} from './meet/Meet';
import {MeetTeach} from './meet/Teach';
import {MeetAnything} from './meet/Anything';
import {MeetByo} from './meet/Byo';
import {MeetFun} from './meet/Fun';
import {MeetClose} from './meet/Close';

// "Meet HeyMate": a fun, teaching-first tour that makes bring-your-own-AI obvious.
// UI is recreated (and tagged as such), not a screen recording.
export const MEET_FPS = 30;
const FADE = 10;

export const MEET_SCENES = [
  {id: 'hook', name: 'Stuck in a tab', seconds: 4.5, Component: MeetHook},
  {id: 'hello', name: 'Meet your mate', seconds: 4, Component: MeetHello},
  {id: 'teach', name: 'It teaches, you do', seconds: 10, Component: MeetTeach},
  {id: 'anything', name: 'Ask about anything', seconds: 6, Component: MeetAnything},
  {id: 'byo', name: 'Bring your own AI', seconds: 9.5, Component: MeetByo},
  {id: 'fun', name: 'A more fun way', seconds: 4.5, Component: MeetFun},
  {id: 'close', name: 'Say hey', seconds: 5, Component: MeetClose},
] as const;

export const MEET_TOTAL_FRAMES =
  MEET_SCENES.reduce((sum, s) => sum + Math.round(s.seconds * MEET_FPS), 0) - FADE * (MEET_SCENES.length - 1);

export const MeetHeyMate: React.FC = () => {
  const {fps, durationInFrames} = useVideoConfig();
  return (
    <>
      <TransitionSeries>
        {MEET_SCENES.flatMap(({id, name, seconds, Component}, i) => [
          ...(i > 0 ? [<TransitionSeries.Transition key={`${id}-fade`} presentation={fade()} timing={linearTiming({durationInFrames: FADE})} />] : []),
          <TransitionSeries.Sequence key={id} name={name} durationInFrames={Math.round(seconds * fps)} premountFor={fps}>
            <Component />
          </TransitionSeries.Sequence>,
        ])}
      </TransitionSeries>
      <Audio
        name="Show Me by Peyruis (CC BY 3.0)"
        src={staticFile('music/show-me-by-peyruis.mp3')}
        volume={(f) =>
          0.6 *
          interpolate(f, [0, fps, durationInFrames - 1.5 * fps, durationInFrames - 1], [0, 1, 1, 0], {
            extrapolateLeft: 'clamp',
            extrapolateRight: 'clamp',
          })
        }
      />
    </>
  );
};
