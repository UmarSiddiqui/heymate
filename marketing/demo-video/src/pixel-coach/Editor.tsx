import React from 'react';
import {interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {C, Cursor, Logo, clamp, ease, usePortrait} from './design';

type Stage = 'select' | 'clear' | 'export';

// A deliberately simplified illustration, not a screenshot or live tool trace.
// Source PNG and transparent PNG are the owned fixture and its manual Photopea export.
export const Editor: React.FC<{stage: Stage}> = ({stage}) => {
  const portrait = usePortrait(); const frame = useCurrentFrame(); const {fps} = useVideoConfig();
  const t = frame / fps;
  const w = portrait ? 920 : 1050;
  const h = portrait ? 568 : 594;
  const logoW = portrait ? 480 : 530;
  const logoX = 54 + (w - 234 - logoW) / 2;
  const logoY = 145;
  const cleared = stage === 'export' || (stage === 'clear' && t > 2.7);
  const selected = stage === 'select' ? t > 3.2 : !cleared;
  const menuOpen = stage === 'clear' ? t > .9 && t < 2.8 : stage === 'export' && t > .65 && t < 2.4;
  const exportOpen = stage === 'export' && t >= 2.4 && t < 5.5;
  const saved = stage === 'export' && t >= 5.5;
  let cursorX = 24, cursorY = 190;
  if (stage === 'select') {
    cursorX = interpolate(frame, [1.2 * fps, 2.7 * fps], [24, logoX + 66], {...clamp, easing: ease});
    cursorY = interpolate(frame, [1.2 * fps, 2.7 * fps], [190, logoY + 65], {...clamp, easing: ease});
  } else if (stage === 'clear') {
    cursorX = interpolate(frame, [fps, 2.1 * fps], [79, 182], {...clamp, easing: ease});
    cursorY = interpolate(frame, [fps, 2.1 * fps], [58, 191], {...clamp, easing: ease});
  } else {
    cursorX = t < 2.4 ? interpolate(frame, [.8 * fps, 1.8 * fps], [24, 265], {...clamp, easing: ease}) : w / 2 + 160;
    cursorY = t < 2.4 ? interpolate(frame, [.8 * fps, 1.8 * fps], [58, 209], {...clamp, easing: ease}) : 444;
  }
  return <div style={{position: 'relative', width: w, height: h, background: '#38373E', borderRadius: 24, overflow: 'hidden', boxShadow: '0 22px 50px #302A3819', color: '#EBEBED'}}>
    <div style={{height: 41, background: '#E6E3DE', color: '#625F66', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 19}}>photopea.com</div>
    <div style={{height: 42, background: '#29282E', display: 'flex', alignItems: 'center', gap: 22, paddingLeft: 19, fontSize: 21}}><span>File</span><span>Edit</span><span>Image</span><span>Layer</span><span>Select</span><span>Filter</span><span>View</span></div>
    <div style={{height: 44, background: '#46444D', display: 'flex', gap: 23, alignItems: 'center', paddingLeft: 20, fontSize: 18}}><span>✦ Magic Wand</span><span style={{opacity: .65}}>Tolerance: 16</span><span style={{opacity: .65}}>☑ Contiguous</span></div>
    <div style={{position: 'absolute', left: 0, top: 127, bottom: 0, width: 54, background: '#302F36', display: 'flex', flexDirection: 'column', gap: 15, alignItems: 'center', paddingTop: 18, fontSize: 26}}><span>↖</span><span style={{background: C.purple, width: 41, height: 38, borderRadius: 6, textAlign: 'center'}}>✦</span><span>⌖</span><span>▧</span><span>◒</span><span>T</span><span>◻</span></div>
    <div style={{position: 'absolute', right: 0, top: 127, bottom: 0, width: 180, background: '#302F36', padding: '20px 16px', boxSizing: 'border-box'}}><div style={{fontSize: 20, color: '#BEBBC6'}}>Layers</div><div style={{marginTop: 22, borderRadius: 7, padding: '15px 9px', background: '#4A4657', fontSize: 19, lineHeight: 1.4}}>◉ &nbsp;Practice logo</div><div style={{fontSize: 15, opacity: .6, marginTop: 17}}>1000 × 800 px</div></div>
    <Logo transparent={cleared} style={{position: 'absolute', left: logoX, top: logoY, width: logoW, boxShadow: '0 5px 18px #0004'}}/>
    {selected && <svg width={logoW} height={logoW * .8} viewBox="0 0 1000 800" style={{position: 'absolute', left: logoX, top: logoY, pointerEvents: 'none'}}><g stroke="white" strokeWidth="5" fill="none"><rect x="4" y="4" width="992" height="792"/><path d="M320 575L500 230L680 575Z"/><circle cx="715" cy="265" r="34"/></g><g stroke="#35313F" strokeWidth="3" strokeDasharray="8 8" strokeDashoffset={-frame / 4} fill="none"><rect x="4" y="4" width="992" height="792"/><path d="M320 575L500 230L680 575Z"/><circle cx="715" cy="265" r="34"/></g></svg>}
    {menuOpen && <div style={{position: 'absolute', left: stage === 'clear' ? 60 : 8, top: 79, width: stage === 'clear' ? 259 : 330, background: '#EFEDEF', color: C.ink, borderRadius: '0 0 10px 10px', padding: '12px 8px', boxShadow: '0 15px 25px #0004', fontSize: 24, zIndex: 10}}>
      {stage === 'clear' ? <><div style={{padding: '10px 15px', opacity: .5}}>Undo</div><div style={{padding: '10px 15px', opacity: .5}}>Cut</div><div style={{padding: '10px 15px', color: 'white', background: C.purple, borderRadius: 5}}>Clear</div></> : <><div style={{padding: '10px 15px', opacity: .5}}>Open…</div><div style={{padding: '10px 15px'}}>Export as <span style={{float: 'right'}}>›</span></div><div style={{padding: '10px 15px', color: 'white', background: C.purple, borderRadius: 5}}>PNG</div></>}
    </div>}
    {exportOpen && <div style={{position: 'absolute', left: w / 2 - 285, top: 131, width: 570, background: '#ECEAEC', color: C.ink, borderRadius: 17, boxShadow: '0 25px 80px #0007', padding: 27, zIndex: 15}}>
      <div style={{fontSize: 28, fontWeight: 600}}>Save for web</div>
      <div style={{display: 'flex', marginTop: 19, alignItems: 'center', gap: 28}}><Logo transparent style={{width: 218, borderRadius: 8}}/><div style={{fontSize: 22, lineHeight: 1.85}}>Format &nbsp;<b>PNG</b><br/>Width &nbsp;1000<br/>Height &nbsp;800</div></div>
      <div style={{background: C.purple, color: 'white', borderRadius: 9, padding: '13px 22px', fontSize: 25, textAlign: 'center', marginTop: 19}}>Save</div>
    </div>}
    {saved && <div style={{position: 'absolute', bottom: 28, left: 114, right: 225, background: C.green, color: '#32412E', padding: '20px 22px', borderRadius: 14, fontSize: 25, boxShadow: '0 10px 20px #0003'}}>✓ &nbsp; practice-logo.png</div>}
    {!saved && (stage !== 'clear' || t < 3.1) && <Cursor x={cursorX} y={cursorY} click={stage === 'select' ? t > 2.8 && t < 3.35 : stage === 'clear' ? t > 2.4 && t < 2.9 : t > 5 && t < 5.5}/>}
  </div>;
};
