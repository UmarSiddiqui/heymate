import React from 'react';
import {AbsoluteFill, CanvasImage, Easing, interpolate, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {FONTS} from '../config';

export const C = {paper: '#F4F1EA', ink: '#202128', muted: '#777580', purple: '#7554D8', lilac: '#EBE5FB', line: '#D9D5CD', green: '#DCECBB', dark: '#27262F'};
export const ease = Easing.bezier(0.16, 1, 0.3, 1);
export const clamp = {extrapolateLeft: 'clamp' as const, extrapolateRight: 'clamp' as const};
export const usePortrait = () => { const {width, height} = useVideoConfig(); return height > width; };

export const Avatar: React.FC<{size?: number; happy?: boolean}> = ({size = 72, happy = false}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const blink = Math.floor(frame / (3.3 * fps)) % 3 === 1 && frame % Math.round(3.3 * fps) < 4;
  return <svg role="img" aria-label="Pixel Coach avatar" width={size} height={size} viewBox="0 0 100 100">
    <rect x="1" y="1" width="98" height="98" rx="32" fill={C.purple}/>
    <path d="M23 24H34M23 24V35M77 65V76M66 76H77" stroke="#BBA6F4" strokeWidth="3" fill="none"/>
    <rect x="28" y={blink ? 46 : 37} width="11" height={blink ? 3 : 19} rx="5.5" fill="white"/>
    <rect x="60" y={blink ? 46 : 37} width="11" height={blink ? 3 : 19} rx="5.5" fill="white"/>
    <path d={happy ? 'M35 64Q50 82 66 63' : 'M40 66Q50 71 60 66'} stroke="white" strokeWidth="4" fill="none" strokeLinecap="round"/>
  </svg>;
};

export const Logo: React.FC<{transparent?: boolean; style?: React.CSSProperties}> = ({transparent = false, style}) => {
  const {fps} = useVideoConfig();
  return <div style={{position: 'relative', aspectRatio: '5 / 4', overflow: 'hidden', background: transparent ? 'repeating-conic-gradient(#E4E1E9 0% 25%, #FCFBFE 0% 50%) 0 / 32px 32px' : 'white', ...style}}>
    <CanvasImage src={staticFile(transparent ? 'pixel-coach/transparent-export.png' : 'pixel-coach/practice-logo.png')} premountFor={fps} style={{width: '100%', height: '100%'}}/>
  </div>;
};

export const Frame: React.FC<{children: React.ReactNode; chapter: string; number: number; dark?: boolean}> = ({children, chapter, number, dark = false}) => {
  const portrait = usePortrait();
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  return <AbsoluteFill className="pixel-demo" style={{background: dark ? C.dark : C.paper, color: dark ? C.paper : C.ink, fontFamily: FONTS.ui, overflow: 'hidden'}}>
    <style>{'.pixel-demo, .pixel-demo * { box-sizing: border-box; }'}</style>
    <div style={{position: 'absolute', left: 80, top: portrait ? 92 : 52, right: 80, display: 'flex', alignItems: 'center', justifyContent: 'space-between'}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 15, fontSize: 34, fontWeight: 650}}><CanvasImage src={staticFile('icon.png')} premountFor={fps} style={{width: 48, height: 48, borderRadius: 12}}/>HeyMate</div>
      <div style={{border: `1px solid ${dark ? '#625F6E' : C.line}`, borderRadius: 99, padding: '11px 18px', fontSize: portrait ? 18 : 20, letterSpacing: 1.6, fontWeight: 650}}>RECREATED PRODUCT DEMO</div>
    </div>
    <div style={{opacity: interpolate(frame, [0, 0.3 * fps], [0, 1], clamp)}}>{children}</div>
    <div style={{position: 'absolute', bottom: portrait ? 98 : 49, left: 80, right: 80, borderTop: `1px solid ${dark ? '#514E5C' : C.line}`, paddingTop: 20, display: 'flex', alignItems: 'center', justifyContent: 'space-between'}}>
      <div style={{fontSize: 23, letterSpacing: 1.5, fontWeight: 600}}><span style={{opacity: .45, marginRight: 18}}>0{number}</span>{chapter}</div>
      <div style={{display: 'flex', gap: 8}}>{Array.from({length: 7}, (_, i) => <div key={i} style={{width: portrait ? 18 : 31, height: 5, borderRadius: 8, background: i === number - 1 ? (dark ? '#C9B9FB' : C.purple) : (dark ? '#55515F' : '#D7D2C9')}}/>)}</div>
    </div>
  </AbsoluteFill>;
};

export const Title: React.FC<{children: React.ReactNode; style?: React.CSSProperties}> = ({children, style}) => {
  const frame = useCurrentFrame(); const {fps} = useVideoConfig();
  return <div style={{fontSize: 104, lineHeight: 1.06, letterSpacing: '-0.055em', fontWeight: 600, whiteSpace: 'pre-line', translate: `0 ${interpolate(frame, [0, .65 * fps], [24, 0], {...clamp, easing: ease})}px`, ...style}}>{children}</div>;
};

export const Pill: React.FC<{children: React.ReactNode; style?: React.CSSProperties}> = ({children, style}) => <div style={{display: 'inline-flex', alignItems: 'center', gap: 10, padding: '12px 19px', borderRadius: 99, fontSize: 25, fontWeight: 600, background: C.lilac, color: C.purple, ...style}}>{children}</div>;

export const CoachHeader: React.FC = () => <div style={{display: 'flex', alignItems: 'center', gap: 19}}><Avatar size={72}/><div><div style={{fontSize: 32, fontWeight: 650}}>Pixel Coach</div><div style={{fontSize: 23, color: C.muted, marginTop: 3}}>Your patient Photopea tutor</div></div></div>;

export const Cursor: React.FC<{x: number; y: number; click?: boolean; label?: string}> = ({x, y, click = false, label = 'You'}) => {
  const frame = useCurrentFrame();
  return <div style={{position: 'absolute', left: x, top: y, zIndex: 20, pointerEvents: 'none'}}>
    {click && <div style={{position: 'absolute', left: -24, top: -24, width: 52, height: 52, border: `3px solid ${C.purple}`, background: '#B9A5F040', borderRadius: '50%', scale: 1 + (frame % 18) / 36, opacity: 1 - (frame % 18) / 24}}/>}
    <svg width="36" height="47" viewBox="0 0 36 47"><path d="M3 2L30 27L18 28L23 40L17 43L12 30L3 37Z" fill={C.ink} stroke="white" strokeWidth="3" strokeLinejoin="round"/></svg>
    <div style={{position: 'absolute', left: 29, top: 37, background: C.purple, color: 'white', borderRadius: '0 12px 12px 12px', padding: '6px 12px', fontSize: 21, fontWeight: 700, whiteSpace: 'nowrap'}}>{label}</div>
  </div>;
};
