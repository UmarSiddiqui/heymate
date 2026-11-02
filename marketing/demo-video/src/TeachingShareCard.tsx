import React from 'react';
import {AbsoluteFill, CanvasImage, staticFile, useVideoConfig} from 'remotion';
import {FONTS} from './config';
import {TEACHING} from './teaching/TeachingFrame';

// Brand graphic only: no app UI, captured interaction, or outcome is depicted.
export const TeachingShareCard: React.FC = () => {
  const {fps} = useVideoConfig();
  return (
    <AbsoluteFill style={{background: TEACHING.paper, color: TEACHING.ink, fontFamily: FONTS.ui, padding: '58px 72px'}}>
      <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'center'}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 18}}>
          <CanvasImage src={staticFile('icon.png')} premountFor={fps} style={{width: 60, height: 60, borderRadius: 15}} />
          <div style={{fontSize: 38, fontWeight: 600, letterSpacing: '-0.035em'}}>HeyMate</div>
        </div>
        <div style={{display: 'flex', alignItems: 'center', gap: 10}}>
          <CanvasImage src={staticFile('faces/amber.jpg')} premountFor={fps} style={{width: 64, height: 64, borderRadius: 20}} />
          <CanvasImage src={staticFile('faces/robot.jpg')} premountFor={fps} style={{width: 64, height: 64, borderRadius: 20}} />
        </div>
      </div>
      <div style={{marginTop: 63, fontSize: 94, fontWeight: 600, lineHeight: 1.08, letterSpacing: '-0.058em'}}>
        Learn your software.<br />One step at a time.
      </div>
      <div style={{marginTop: 31, fontSize: 33, lineHeight: 1.35, color: TEACHING.muted}}>
        Desktop apps and websites. Free and open source.
      </div>
      <div style={{marginTop: 'auto', paddingTop: 22, borderTop: `1px solid ${TEACHING.line}`, display: 'flex', justifyContent: 'space-between', fontSize: 26}}>
        <span style={{fontWeight: 600, color: TEACHING.blue}}>sayheymate.vercel.app</span>
        <span style={{color: TEACHING.muted}}>Available for macOS</span>
      </div>
    </AbsoluteFill>
  );
};
