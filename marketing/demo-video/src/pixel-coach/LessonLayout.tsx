import React from 'react';
import {interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {C, CoachHeader, Frame, Pill, Title, clamp, usePortrait} from './design';
import {Editor} from './Editor';

export const LessonLayout: React.FC<{stage: 'select' | 'clear' | 'export'; title: string; portraitTitle: string; sub: string; instruction: string; reply: string; step: string; number: number; replyAt: number}> = ({stage, title, portraitTitle, sub, instruction, reply, step, number, replyAt}) => {
  const portrait = usePortrait(); const frame = useCurrentFrame(); const {fps} = useVideoConfig();
  const replied = frame >= replyAt * fps;
  return <Frame chapter={step} number={number}>
    <div style={{position: 'absolute', top: portrait ? 247 : 162, left: 80, right: 80}}>
      <Title style={{fontSize: portrait ? 94 : 85, maxWidth: portrait ? 930 : 1600}}>{portrait ? portraitTitle : title}</Title>
      <div style={{fontSize: portrait ? 37 : 34, lineHeight: 1.4, marginTop: 20, color: C.muted}}>{sub}</div>
    </div>
    <div style={{position: 'absolute', left: 80, top: portrait ? 600 : 357}}><Editor stage={stage}/></div>
    <div style={{position: 'absolute', left: portrait ? 80 : 1190, top: portrait ? 1225 : 357, width: portrait ? 920 : 650, padding: portrait ? '24px 30px' : 33, borderRadius: 25, background: '#FFFEFB', border: `1px solid ${C.line}`}}>
      <CoachHeader/>
      <div style={{fontSize: portrait ? 44 : 38, lineHeight: portrait ? 1.32 : 1.38, marginTop: portrait ? 20 : 31, whiteSpace: 'pre-line'}}>{instruction}</div>
      <div style={{marginTop: portrait ? 20 : 25, display: 'flex', alignItems: 'center', gap: 15}}><Pill style={{fontSize: portrait ? 20 : 22, background: replied ? C.green : C.lilac, color: replied ? '#435A30' : C.purple}}>{replied ? '✓ You did it' : '● Waiting for you'}</Pill></div>
      <div style={{marginTop: portrait ? 18 : 23, padding: portrait ? '14px 20px' : '18px 23px', borderRadius: '16px 16px 4px 16px', background: C.paper, fontSize: portrait ? 30 : 29, color: C.muted, opacity: interpolate(frame, [replyAt * fps, (replyAt + .3) * fps], [0, 1], clamp)}}><b style={{color: C.ink}}>You</b> &nbsp;{reply}</div>
    </div>
  </Frame>;
};
