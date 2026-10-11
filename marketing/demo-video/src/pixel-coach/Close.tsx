import React from 'react';
import {interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {Avatar, C, Frame, Logo, Title, clamp, usePortrait} from './design';

export const PixelClose: React.FC = () => {
  const portrait = usePortrait(); const frame = useCurrentFrame(); const {fps} = useVideoConfig();
  return <Frame chapter="TAKE THE NEXT STEP" number={7} dark>
    <div style={{position: 'absolute', left: 88, top: portrait ? 276 : 249, width: portrait ? 900 : 1200}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 18, fontSize: 28, color: '#D0BDFB', marginBottom: 32}}><Avatar size={58} happy/>A mate beside you. A skill to practise.</div>
      <Title style={{fontSize: portrait ? 106 : 121}}>{'Learn your software.\nOne step at a time.'}</Title>
      <div style={{fontSize: portrait ? 39 : 37, lineHeight: 1.5, color: '#CBC7D5', marginTop: 35}}>Desktop apps and websites.<br/>Free and open source for Mac.</div>
      <div style={{display: 'inline-block', background: C.green, color: C.ink, borderRadius: 18, marginTop: 39, padding: '21px 29px', fontSize: portrait ? 38 : 33, fontWeight: 600}}>getheymate.vercel.app &nbsp;↗</div>
      <div style={{fontSize: portrait ? 28 : 27, color: '#A9A3B8', marginTop: 24}}>Bring your Claude or ChatGPT plan.</div>
    </div>
    <div style={{position: 'absolute', left: portrait ? 270 : 1410, top: portrait ? 1180 : 356, width: portrait ? 540 : 400, rotate: `${interpolate(frame, [0, 2 * fps], [7, 2], clamp)}deg`, background: '#F6F2FC', color: C.ink, padding: 18, borderRadius: 25}}>
      <Logo transparent style={{borderRadius: 13}}/>
      <div style={{padding: '16px 5px 3px', fontSize: portrait ? 28 : 23}}>practice-logo.png <span style={{float: 'right', color: C.purple}}>↗</span></div>
    </div>
  </Frame>;
};
