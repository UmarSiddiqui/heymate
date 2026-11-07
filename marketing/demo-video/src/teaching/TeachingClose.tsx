import React from 'react';
import {CanvasImage, staticFile, useVideoConfig} from 'remotion';
import {TEACHING, TeachingFrame, TeachingTitle} from './TeachingFrame';

export const TeachingClose: React.FC = () => {
  const {width, height, fps} = useVideoConfig();
  const vertical = height > width;
  return (
    <TeachingFrame>
      <div style={{position: 'absolute', left: 88, right: 88, top: vertical ? 380 : 210, display: 'flex', alignItems: 'center', flexDirection: 'column', textAlign: 'center'}}>
        <CanvasImage src={staticFile('icon.png')} premountFor={fps} style={{width: 140, height: 140, borderRadius: 32, marginBottom: 40}} />
        <TeachingTitle style={{fontSize: vertical ? 94 : 120}}>Learn your software.{'\n'}One step at a time.</TeachingTitle>
        <div style={{fontSize: vertical ? 40 : 46, lineHeight: 1.4, marginTop: 38, color: TEACHING.muted}}>Free and open source. Available for macOS.</div>
        <div style={{fontSize: vertical ? 44 : 48, marginTop: 36, color: TEACHING.blue, fontWeight: 600}}>sayheymate.com</div>
        <div style={{fontSize: vertical ? 32 : 29, marginTop: 42, maxWidth: vertical ? 850 : 1300, lineHeight: 1.4, color: TEACHING.muted}}>Screen guidance needs a vision-capable provider.{'\n'}Your provider's usage limits apply.</div>
      </div>
    </TeachingFrame>
  );
};
