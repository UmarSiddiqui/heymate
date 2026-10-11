import React from 'react';
import {interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {Avatar, C, Cursor, Frame, Pill, Title, clamp, ease, usePortrait} from './design';

export const PixelCreate: React.FC = () => {
  const portrait = usePortrait(); const frame = useCurrentFrame(); const {fps} = useVideoConfig();
  const created = frame >= 3.6 * fps;
  return <Frame chapter="CREATE YOUR MATE" number={2}>
    <div style={{position: 'absolute', left: 88, top: portrait ? 252 : 277, width: portrait ? 910 : 790}}>
      <Pill>01 / Make it personal</Pill>
      <Title style={{fontSize: portrait ? 108 : 116, marginTop: 30}}>{'Your mate.\nYour way.'}</Title>
      <div style={{fontSize: 40, lineHeight: 1.4, color: C.muted, marginTop: 28, maxWidth: 650}}>Give it a name, a job,<br/>and a way to help.</div>
    </div>
    <div style={{position: 'absolute', top: portrait ? 760 : 176, left: portrait ? 80 : 980, width: portrait ? 920 : 830, background: '#FFFEFB', border: `1px solid ${C.line}`, borderRadius: 30, padding: 42, boxShadow: '0 25px 60px #2921310C', translate: `0 ${interpolate(frame, [0, .8 * fps], [24, 0], {...clamp, easing: ease})}px`}}>
      <div style={{display: 'flex', gap: 24, alignItems: 'center', marginBottom: 31}}><Avatar size={85} happy={created}/><div style={{fontSize: 35, fontWeight: 600}}>Create a mate</div></div>
      <div style={{fontSize: 23, color: C.muted, marginBottom: 10}}>NAME</div>
      <div style={{fontSize: 38, fontWeight: 550, paddingBottom: 20, borderBottom: `1px solid ${C.line}`}}>Pixel Coach</div>
      <div style={{fontSize: 23, color: C.muted, margin: '24px 0 10px'}}>JOB</div>
      <div style={{fontSize: 33}}>Photopea tutor</div>
      <div style={{fontSize: 23, color: C.muted, margin: '24px 0 10px'}}>PERSONALITY</div>
      <div style={{background: C.paper, borderRadius: 17, padding: 24, fontSize: 32, lineHeight: 1.45}}>Patient. Explain one step,<br/>then wait for me to try it.</div>
      <div style={{marginTop: 30, background: created ? C.green : C.purple, color: created ? '#314727' : 'white', borderRadius: 16, padding: 21, textAlign: 'center', fontSize: 31, fontWeight: 600}}>{created ? '✓  Mate created locally' : 'Create Pixel Coach'}</div>
      {!created && frame > 2.1 * fps && <Cursor x={portrait ? 665 : 590} y={638} click={frame > 3.3 * fps}/>}
    </div>
  </Frame>;
};
