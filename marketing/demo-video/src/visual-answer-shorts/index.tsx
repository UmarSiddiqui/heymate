import React from 'react';
import {AbsoluteFill, Audio, Composition, Img, OffthreadVideo, Sequence, interpolate, registerRoot, staticFile, useCurrentFrame} from 'remotion';

const FPS = 30;
const FRAMES = 285;
const clips = {
  biryani: {question: 'Hey mate, how do I cook chicken biryani?', reveal: 94, duration: 7.375},
  camera: {question: 'Hey mate, where does the camera connect to a Raspberry Pi?', reveal: 125, duration: 7.708333},
  board: {question: 'Hey mate, show me this board in 3D.', reveal: 94, duration: 7.5},
};
type Clip = keyof typeof clips;
const asset = (name: string) => staticFile(`visual-answer-shorts/${name}`);
const clamp = {extrapolateLeft: 'clamp' as const, extrapolateRight: 'clamp' as const};

const Short: React.FC<{clip: Clip}> = ({clip}) => {
  const f = useCurrentFrame();
  const c = clips[clip];
  const asking = f < c.reveal;
  const rate = c.duration / ((FRAMES - c.reveal - 15) / FPS);
  const opacity = interpolate(f, [0, 7, c.reveal - 7, c.reveal], [0, 1, 1, 0], clamp);
  return (
    <AbsoluteFill style={{background: '#151515', fontFamily: 'Figtree, sans-serif'}}>
      <style>{`@font-face {font-family: Figtree; src: url('${asset('Figtree.woff2')}') format('woff2'); font-weight: 300 900;}`}</style>
      <Sequence from={7}><Audio src={asset(`${clip}-voice.wav`)} /></Sequence>
      {/* Preserve the full source, including the real notch at the top edge.
          Hold the original first frame during the synthesized prompt. */}
      {asking ? (
        <Img src={asset(`${clip}-start.png`)} style={{width: 1440, height: 944}} />
      ) : (
        <Sequence from={c.reveal}>
          <OffthreadVideo src={asset(`${clip}.mp4`)} muted playbackRate={rate} style={{width: 1440, height: 944}} />
        </Sequence>
      )}
      {asking && <div style={{position: 'absolute', bottom: 76, left: 48, right: 48, display: 'flex', justifyContent: 'center', opacity}}>
        <div style={{padding: '19px 26px', maxWidth: 1270, borderRadius: 16, background: '#11151cf0', color: '#fff', fontSize: 32, lineHeight: 1.3, fontWeight: 500, textAlign: 'center'}}>{c.question}</div>
      </div>}
      <div style={{position: 'absolute', bottom: 18, left: 24, right: 24, display: 'flex', justifyContent: 'space-between', color: '#fff', fontSize: 17, textShadow: '0 1px 5px #000, 0 1px 12px #000'}}>
        <span>Actual app recording · Condensed & sped up</span>
        <span style={{fontWeight: 600}}>sayheymate.com</span>
      </div>
    </AbsoluteFill>
  );
};

const Root = () => <>{(Object.keys(clips) as Clip[]).map(clip => <Composition key={clip} id={`Short-${clip}`} component={Short} defaultProps={{clip}} durationInFrames={FRAMES} fps={FPS} width={1440} height={944} />)}</>;
registerRoot(Root);
