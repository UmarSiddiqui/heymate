// Scene 3 — HeyMate lives in the notch: hover, it opens to Home, then Apps.
import React from 'react';
import {COLORS, COPY} from '../config';
import {SystemPointer} from '../components/Icons';
import {ease, springAt, useLayout, useTime} from '../components/motion';
import {CARD_H, CARD_PAD, CARD_W, NotchApps, NotchFooter, NotchHeader, NotchHome} from '../components/NotchCards';
import {Dot, FeatureLayout, MacScreen, MacWindow, MENU_BAR_H, NotchShell, TrafficLights} from '../components/UI';

const SCREEN_W = 1000;
const SCREEN_H = 640;
const INNER_W = SCREEN_W - 24;

// Beats (seconds into the scene)
const HOVER_AT = 0.95;
const TAB_CLICK_AT = 3.35;

export const NotchScene: React.FC = () => {
  const {t, frame, fps} = useTime();
  const {vertical} = useLayout();

  const open = springAt(frame, fps, HOVER_AT, 'buddy');
  const w = 196 + (CARD_W - 196) * open;
  const h = MENU_BAR_H + (CARD_H - MENU_BAR_H) * open;
  const r = 12 + 16 * open;
  const contentIn = (delay: number) => (i: number) =>
    ease(t, [delay + i * 0.06, delay + 0.3 + i * 0.06]);

  const tabP = springAt(frame, fps, TAB_CLICK_AT + 0.05, 'control');
  const homeFade = 1 - ease(t, [TAB_CLICK_AT, TAB_CLICK_AT + 0.22]);
  const appsReveal = contentIn(TAB_CLICK_AT + 0.12);

  // Pointer path (screen-inner coordinates).
  const cardLeft = INNER_W / 2 - CARD_W / 2;
  const appsTab = {x: cardLeft + CARD_PAD + 2 + 100 + 4 + 21, y: 26};
  const p1 = ease(t, [0.2, HOVER_AT]);
  const p2 = ease(t, [2.6, TAB_CLICK_AT - 0.05]);
  const p3 = ease(t, [TAB_CLICK_AT + 0.4, 5.2]);
  const start = {x: 690, y: 470};
  const hover = {x: INNER_W / 2 + 40, y: 22};
  const rest = {x: 760, y: 470};
  let px = start.x + (hover.x - start.x) * p1;
  let py = start.y + (hover.y - start.y) * p1;
  px += (appsTab.x - hover.x) * p2;
  py += (appsTab.y - hover.y) * p2;
  px += (rest.x - appsTab.x) * p3;
  py += (rest.y - appsTab.y) * p3;
  const press =
    ease(t, [TAB_CLICK_AT - 0.08, TAB_CLICK_AT]) * (1 - ease(t, [TAB_CLICK_AT + 0.02, TAB_CLICK_AT + 0.14]));

  const collapsedDetail = 1 - ease(t, [HOVER_AT, HOVER_AT + 0.15]);

  return (
    <FeatureLayout
      title={COPY.notch.title}
      sub={COPY.notch.sub}
      stageWidth={SCREEN_W}
      stageHeight={SCREEN_H}
      verticalFocus={{x: 100, y: 0, w: 800, h: 600}}
    >
      <MacScreen
        width={SCREEN_W}
        height={SCREEN_H}
        menu={vertical ? 'none' : 'compact'}
        notch={
          <NotchShell width={w} height={h} radius={r} glow={open > 0.05 ? 'rgba(51,128,255,0.10)' : undefined}>
            {/* Collapsed: a quiet status dot. */}
            <div
              style={{
                position: 'absolute',
                right: 16,
                top: MENU_BAR_H / 2 - 4,
                opacity: collapsedDetail,
              }}
            >
              <Dot color={COLORS.success} size={8} glow />
            </div>
            <div style={{position: 'absolute', top: 0, width: CARD_W, height: CARD_H, left: (w - CARD_W) / 2}}>
              <div style={{position: 'absolute', inset: 0, opacity: ease(t, [HOVER_AT + 0.15, HOVER_AT + 0.4])}}>
                <NotchHeader p={tabP} />
                <NotchFooter />
              </div>
              <div style={{position: 'absolute', inset: 0, opacity: homeFade, transform: `translateX(${(1 - homeFade) * -24}px)`}}>
                <NotchHome stagger={contentIn(HOVER_AT + 0.25)} />
              </div>
              {t > TAB_CLICK_AT ? (
                <div style={{position: 'absolute', inset: 0, transform: `translateX(${(1 - appsReveal(0)) * 24}px)`}}>
                  <NotchApps stagger={appsReveal} seconds={Math.max(0, t - TAB_CLICK_AT)} />
                </div>
              ) : null}
            </div>
          </NotchShell>
        }
        top={
          <div style={{position: 'absolute', left: px - 4, top: py - 3}}>
            <SystemPointer size={30} press={press} />
          </div>
        }
      >
        <DesktopWindow />
      </MacScreen>
    </FeatureLayout>
  );
};

/** A quiet chat window on the desktop, so the notch has something to sit over. */
const DesktopWindow: React.FC = () => (
  <div style={{position: 'absolute', left: 78, top: 150, opacity: 0.75}}>
    <MacWindow width={820} height={430} background={COLORS.background}>
      <div style={{position: 'absolute', left: 0, top: 0, bottom: 0, width: 200, background: COLORS.surface1, borderRight: `1px solid ${COLORS.borderSubtle}`}}>
        <div style={{position: 'absolute', left: 16, top: 16}}>
          <TrafficLights size={11} />
        </div>
        {[0, 1, 2, 3, 4].map((i) => (
          <div key={i} style={{position: 'absolute', left: 16, top: 56 + i * 52, display: 'flex', gap: 10, alignItems: 'center'}}>
            <div style={{width: 26, height: 26, borderRadius: 26, background: COLORS.surface3}} />
            <div>
              <div style={{width: 70 + (i % 3) * 18, height: 8, borderRadius: 4, background: COLORS.surface4}} />
              <div style={{marginTop: 6, width: 110 - (i % 2) * 20, height: 6, borderRadius: 3, background: COLORS.surface3}} />
            </div>
          </div>
        ))}
      </div>
      <div style={{position: 'absolute', left: 200, right: 0, top: 0, bottom: 0, padding: '230px 28px 0'}}>
        <div style={{display: 'flex', justifyContent: 'flex-end'}}>
          <div style={{padding: '10px 16px', borderRadius: 16, background: COLORS.userBubble, fontSize: 16}}>
            Summarize this PDF in three bullets.
          </div>
        </div>
        <div style={{marginTop: 18, width: 380}}>
          {[1, 0.92, 0.7].map((w, i) => (
            <div key={i} style={{marginTop: 9, height: 9, width: `${w * 100}%`, borderRadius: 5, background: COLORS.surface3}} />
          ))}
        </div>
      </div>
    </MacWindow>
  </div>
);
