import React from 'react';
import {interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {C, CoachHeader, Frame, Logo, Pill, Title, clamp, ease, usePortrait} from './design';

export const PixelIdentity: React.FC = () => {
  const portrait = usePortrait(); const frame = useCurrentFrame(); const {fps} = useVideoConfig();
  return <Frame chapter="A FAMILIAR FACE" number={3}>
    <div style={{position: 'absolute', left: 88, top: portrait ? 245 : 262, width: portrait ? 900 : 760}}>
      <Pill>02 / Keep the context</Pill>
      <Title style={{fontSize: 109, marginTop: 32}}>{'Same mate.\nNext chat.'}</Title>
      <div style={{fontSize: 40, lineHeight: 1.4, color: C.muted, marginTop: 29}}>A distinct name and job.<br/>Your saved practice note.</div>
    </div>
    <div style={{position: 'absolute', left: portrait ? 80 : 960, top: portrait ? 760 : 174, width: portrait ? 920 : 865, border: `1px solid ${C.line}`, borderRadius: 30, background: '#FFFEFB', padding: 38}}>
      <CoachHeader/>
      <div style={{height: 1, background: C.line, margin: '30px 0'}}/>
      <div style={{display: 'flex', gap: 23, alignItems: 'center', background: C.paper, borderRadius: 19, padding: 22}}>
        <Logo style={{width: 150, borderRadius: 10, flexShrink: 0}}/>
        <div><div style={{fontSize: 22, fontWeight: 600, color: C.purple, marginBottom: 9}}>SAVED NOTE</div><div style={{fontSize: 29, lineHeight: 1.3}}>Practice logo:<br/>purple triangle + dot.</div></div>
      </div>
      <div style={{background: C.lilac, borderRadius: '20px 20px 20px 5px', padding: 28, marginTop: 28, fontSize: 34, lineHeight: 1.4, opacity: interpolate(frame, [.7 * fps, 1.2 * fps], [0, 1], clamp), translate: `0 ${interpolate(frame, [.7 * fps, 1.2 * fps], [16, 0], {...clamp, easing: ease})}px`}}>Let’s use your purple logo.<br/>I’ll guide you one step at a time.</div>
      <div style={{marginTop: 24, padding: '19px 25px', fontSize: 29, border: `1px solid ${C.line}`, borderRadius: 16, color: C.muted}}>Teach me to remove the white background.</div>
    </div>
  </Frame>;
};
