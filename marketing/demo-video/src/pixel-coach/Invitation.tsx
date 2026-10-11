import React from 'react';
import {interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {Avatar, C, Frame, Logo, Pill, Title, clamp, ease, usePortrait} from './design';

export const PixelInvitation: React.FC = () => {
  const portrait = usePortrait(); const frame = useCurrentFrame(); const {fps} = useVideoConfig();
  return <Frame chapter="A MATE THAT TEACHES" number={1}>
    <div style={{position: 'absolute', left: 88, top: portrait ? 266 : 267, width: portrait ? 900 : 880}}>
      <Pill>Meet your next “I did that.”</Pill>
      <Title style={{fontSize: portrait ? 116 : 126, marginTop: 34}}>{'Make it yours.\nLearn by doing.'}</Title>
      <div style={{fontSize: portrait ? 44 : 40, lineHeight: 1.35, color: C.muted, marginTop: 30, maxWidth: 780}}>A little help in the software<br/>you actually use.</div>
    </div>
    <div style={{position: 'absolute', left: portrait ? 135 : 1060, top: portrait ? 915 : 217, width: portrait ? 810 : 690, rotate: `${interpolate(frame, [0, 1.2 * fps], [4, -3], {...clamp, easing: ease})}deg`, translate: `0 ${interpolate(frame, [0, fps], [65, 0], {...clamp, easing: ease})}px`, background: 'white', padding: 22, borderRadius: 32, boxShadow: '0 35px 70px #33245217'}}>
      <div style={{display: 'flex', justifyContent: 'space-between', padding: '12px 10px 25px', fontSize: 25, color: C.muted}}><span>Your practice logo</span><span>PNG</span></div>
      <Logo style={{borderRadius: 14, border: `1px solid ${C.line}`}}/>
      <div style={{position: 'absolute', right: -34, bottom: -40, rotate: '7deg'}}><Avatar size={portrait ? 150 : 130} happy/></div>
    </div>
  </Frame>;
};
