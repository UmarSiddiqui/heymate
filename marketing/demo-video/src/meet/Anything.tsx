// 4 — Quick-fire: ask about anything on screen, not just one app.
import React from 'react';
import {COLORS, FONTS} from '../config';
import {ease, riseStyle, springAt, useLayout, useTime} from '../components/motion';
import {Backdrop, TrafficLights} from '../components/UI';
import {Bubble, Buddy, IllustratedTag, UserBubble} from './kit';

const CARD_W = 520;
const CARD_H = 400;
const CONTENT_H = 196;

type Example = {
  at: number;
  window: string;
  question: string;
  answer: string;
  /** Where the buddy points, in card-local px. */
  point: {x: number; y: number};
  Content: React.FC<{lit: number}>;
};

const Recipe: React.FC<{lit: number}> = ({lit}) => (
  <div style={{padding: '16px 22px'}}>
    <div style={{fontSize: 22, fontWeight: 700}}>Banana bread</div>
    <div style={{fontSize: 13, color: COLORS.textTertiary, marginTop: 2}}>Serves 8 · 1 hr</div>
    {['3 ripe bananas', '½ cup butter, melted', '¾ cup sugar', '1½ cups flour'].map((line, i) => (
      <div
        key={line}
        style={{
          marginTop: i === 0 ? 12 : 4,
          padding: '3px 8px',
          marginLeft: -8,
          borderRadius: 6,
          fontSize: 16,
          color: COLORS.textSecondary,
          background: i === 1 ? `rgba(51,128,255,${0.28 * lit})` : undefined,
          boxShadow: i === 1 && lit > 0 ? `inset 0 0 0 1.5px rgba(51,128,255,${lit})` : undefined,
          width: 'fit-content',
        }}
      >
        • {line}
      </div>
    ))}
  </div>
);

const DiskAlert: React.FC<{lit: number}> = ({lit}) => (
  <div style={{height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center'}}>
    <div style={{width: 380, padding: '16px 18px', borderRadius: 14, background: COLORS.surface3, border: `1px solid ${COLORS.borderStrong}`, display: 'flex', gap: 14}}>
      <div style={{width: 42, height: 42, borderRadius: 10, background: COLORS.warning, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 800, fontSize: 24, color: '#1a1200'}}>!</div>
      <div>
        <div style={{fontSize: 16, fontWeight: 700}}>Your startup disk is almost full.</div>
        <div style={{fontSize: 13, color: COLORS.textTertiary, marginTop: 4, lineHeight: 1.35}}>Free up space by deleting files you no longer need.</div>
        <div style={{display: 'flex', gap: 8, marginTop: 10}}>
          <div style={{padding: '4px 12px', borderRadius: 7, fontSize: 13, fontWeight: 600, background: COLORS.surface4}}>Ignore</div>
          <div style={{padding: '4px 12px', borderRadius: 7, fontSize: 13, fontWeight: 600, background: COLORS.accent, boxShadow: lit > 0 ? `0 0 0 ${3 * lit}px rgba(51,128,255,0.45)` : undefined}}>Manage…</div>
        </div>
      </div>
    </div>
  </div>
);

const Menu: React.FC<{lit: number}> = ({lit}) => (
  <div style={{padding: '16px 22px', fontFamily: 'Georgia, "Times New Roman", serif'}}>
    <div style={{fontSize: 22, fontStyle: 'italic', textAlign: 'center', color: COLORS.textPrimary}}>Trattoria · Secondi</div>
    {[
      ['Fritto misto', '18'],
      ['Pollo alla griglia', '16'],
      ['Cotoletta alla milanese', '19'],
    ].map(([dish, price], i) => (
      <div
        key={dish}
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          marginTop: i === 0 ? 14 : 6,
          padding: '4px 10px',
          borderRadius: 6,
          fontSize: 18,
          color: COLORS.textSecondary,
          background: i === 1 ? `rgba(51,128,255,${0.28 * lit})` : undefined,
          boxShadow: i === 1 && lit > 0 ? `inset 0 0 0 1.5px rgba(51,128,255,${lit})` : undefined,
        }}
      >
        <span>{dish}</span>
        <span>€{price}</span>
      </div>
    ))}
  </div>
);

const EXAMPLES: Example[] = [
  {at: 0.35, window: 'grandmas-recipes.com', question: 'Out of butter. Can I use oil?', answer: 'Yep. Swap in 6 tbsp of oil. Just as moist.', point: {x: 262, y: 104}, Content: Recipe},
  {at: 1.55, window: 'Finder', question: 'Uh… what do I do here?', answer: 'Click Manage. I’ll show you what’s taking up space.', point: {x: 346, y: 150}, Content: DiskAlert},
  {at: 2.75, window: 'menu-photo.jpg', question: 'Which one isn’t fried?', answer: 'Pollo alla griglia. It’s grilled chicken.', point: {x: 300, y: 108}, Content: Menu},
];

const ExampleCard: React.FC<{ex: Example}> = ({ex}) => {
  const {t, frame, fps} = useTime();
  const cardIn = springAt(frame, fps, ex.at, 'buddy');
  const q = springAt(frame, fps, ex.at + 0.3, 'buddy');
  const fly = springAt(frame, fps, ex.at + 0.6, 'gentle');
  const a = springAt(frame, fps, ex.at + 0.85, 'buddy');
  const typed = ease(t, [ex.at + 0.9, ex.at + 1.6], [0, 1], (x) => x);
  const lit = ease(t, [ex.at + 0.75, ex.at + 0.95]);
  const start = {x: CARD_W / 2, y: -20};
  const bx = start.x + (ex.point.x - start.x) * fly;
  const by = start.y + (ex.point.y - start.y) * fly;

  return (
    <div
      style={{
        position: 'relative',
        width: CARD_W,
        height: CARD_H,
        borderRadius: 22,
        background: COLORS.surface1,
        border: `1px solid ${COLORS.borderSubtle}`,
        boxShadow: '0 30px 70px rgba(0,0,0,0.6)',
        opacity: Math.min(1, cardIn * 1.5),
        transform: `translateY(${(1 - cardIn) * 60}px) rotate(${(1 - cardIn) * -4}deg)`,
        flexShrink: 0,
      }}
    >
      <div style={{position: 'absolute', inset: 0, borderRadius: 22, overflow: 'hidden'}}>
        <div style={{height: 34, display: 'flex', alignItems: 'center', gap: 12, padding: '0 14px', background: COLORS.surface2, borderBottom: `1px solid ${COLORS.borderSubtle}`}}>
          <TrafficLights size={10} />
          <span style={{fontSize: 13, color: COLORS.textTertiary, fontWeight: 600}}>{ex.window}</span>
        </div>
        <div style={{height: CONTENT_H, background: COLORS.background, borderBottom: `1px solid ${COLORS.borderSubtle}`}}>
          <ex.Content lit={lit} />
        </div>
        <div style={{position: 'absolute', left: 18, right: 18, top: 34 + CONTENT_H + 16, display: 'flex', flexDirection: 'column'}}>
          <UserBubble text={ex.question} pop={q} size={19} />
        </div>
      </div>
      <Buddy x={bx} y={by} size={34} opacity={ease(t, [ex.at + 0.55, ex.at + 0.7])} />
      <Bubble x={18} y={34 + CONTENT_H + 80} text={ex.answer} pop={a} typed={typed} size={19} width={CARD_W - 60} />
    </div>
  );
};

export const MeetAnything: React.FC = () => {
  const {vertical} = useLayout();
  const {frame, fps} = useTime();
  const titleIn = springAt(frame, fps, 0.05, 'gentle');
  const scale = vertical ? 1.15 : 1;

  return (
    <Backdrop>
      <div style={{position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: vertical ? 60 : 64}}>
        <div style={{textAlign: 'center', fontSize: vertical ? 78 : 68, fontWeight: 600, letterSpacing: '-0.03em', lineHeight: 1.06, whiteSpace: 'pre-line', ...riseStyle(titleIn, 28, 10)}}>
          {vertical ? 'Ask about\nanything on screen.' : 'Ask about anything on screen.'}
          <div style={{fontSize: vertical ? 34 : 28, fontWeight: 500, letterSpacing: 0, color: COLORS.textSecondary, marginTop: 16, fontFamily: FONTS.ui}}>
            Any app. Any website. Even a photo of a menu.
          </div>
        </div>
        <div
          style={{
            display: 'flex',
            flexDirection: vertical ? 'column' : 'row',
            gap: vertical ? 30 : 40,
            zoom: scale,
          }}
        >
          {EXAMPLES.map((ex) => (
            <ExampleCard key={ex.window} ex={ex} />
          ))}
        </div>
      </div>
      <IllustratedTag />
    </Backdrop>
  );
};
