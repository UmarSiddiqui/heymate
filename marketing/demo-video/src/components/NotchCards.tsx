// Recreations of the expanded notch card: header tabs, Home and Apps pages.
import React from 'react';
import {COLORS, FONTS} from '../config';
import {
  ArrowUpIcon,
  BoltIcon,
  CalendarIcon,
  CameraIcon,
  ChevronRightIcon,
  ChevronUpIcon,
  ClipboardIcon,
  CpuIcon,
  DownloadIcon,
  FileIcon,
  GearIcon,
  GridIcon,
  HomeIcon,
  InfoIcon,
  ListIcon,
  MicIcon,
  MusicIcon,
  PowerIcon,
  SparkleIcon,
  SpeakerIcon,
  TimerIcon,
  TrayIcon,
  WandIcon,
  WindowIcon,
} from './Icons';
import {Dot} from './UI';

export const CARD_W = 760;
export const CARD_H = 372;
export const CARD_PAD = 22;
export const TAB_Y = 26;

const label: React.CSSProperties = {fontSize: 14, fontWeight: 600, color: COLORS.textSecondary};

/** Tab strip. `p` = 0 shows Home selected, 1 shows Apps selected. */
export const NotchHeader: React.FC<{p: number}> = ({p}) => {
  const tab = (icon: React.ReactNode, name: string, sel: number) => (
    <div
      style={{
        height: 36,
        width: 42 + 58 * sel,
        borderRadius: 999,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 7 * sel,
        background: `rgba(51,128,255,${0.22 * sel})`,
        boxShadow: sel > 0.02 ? `inset 0 0 0 1px rgba(51,128,255,${0.5 * sel})` : undefined,
        color: sel > 0.5 ? COLORS.textPrimary : COLORS.textSecondary,
        overflow: 'hidden',
      }}
    >
      {icon}
      <span style={{fontSize: 15, fontWeight: 600, opacity: sel, width: 44 * sel, overflow: 'hidden'}}>{name}</span>
    </div>
  );
  return (
    <div
      style={{
        position: 'absolute',
        left: CARD_PAD,
        right: CARD_PAD,
        top: 8,
        height: 36,
        display: 'flex',
        alignItems: 'center',
      }}
    >
      <div style={{display: 'flex', gap: 4, padding: 2, borderRadius: 999, background: 'rgba(255,255,255,0.06)'}}>
        {tab(<HomeIcon size={17} />, 'Home', 1 - p)}
        {tab(<GridIcon size={16} />, 'Apps', p)}
        {tab(<SparkleIcon size={16} />, 'Agents', 0)}
      </div>
      <div style={{marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10}}>
        <div style={{color: COLORS.textSecondary, marginRight: 70}}>
          <PowerIcon size={18} />
        </div>
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            height: 32,
            padding: '0 14px',
            borderRadius: 999,
            background: 'rgba(255,255,255,0.07)',
            fontSize: 15,
            fontWeight: 600,
          }}
        >
          <Dot color={COLORS.success} size={8} glow />
          Ready
        </div>
        <div
          style={{
            width: 32,
            height: 32,
            borderRadius: 32,
            background: 'rgba(255,255,255,0.07)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            color: COLORS.textSecondary,
          }}
        >
          <ChevronUpIcon size={15} />
        </div>
      </div>
    </div>
  );
};

export const NotchFooter: React.FC = () => (
  <div
    style={{
      position: 'absolute',
      left: CARD_PAD,
      right: CARD_PAD,
      bottom: 14,
      height: 40,
      display: 'flex',
      alignItems: 'center',
      borderTop: `1px solid ${COLORS.borderSubtle}`,
      paddingTop: 12,
    }}
  >
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 8,
        height: 34,
        padding: '0 14px',
        borderRadius: 999,
        background: COLORS.surface2,
        fontSize: 15,
        fontWeight: 600,
      }}
    >
      <CpuIcon size={15} color={COLORS.accentText} />
      Claude
      <span style={{color: COLORS.textTertiary, fontSize: 12}}>⌃</span>
    </div>
    <div style={{marginLeft: 'auto', display: 'flex', gap: 10, alignItems: 'center'}}>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          height: 34,
          padding: '0 16px',
          borderRadius: 999,
          background: COLORS.surface2,
          fontSize: 15,
          fontWeight: 600,
        }}
      >
        <WindowIcon size={15} />
        Undock
      </div>
      <div
        style={{
          width: 34,
          height: 34,
          borderRadius: 34,
          background: COLORS.surface2,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          color: COLORS.textSecondary,
        }}
      >
        <InfoIcon size={16} />
      </div>
    </div>
  </div>
);

const Tile: React.FC<{icon: React.ReactNode; title: string; sub: string; kbd: string}> = ({icon, title, sub, kbd}) => (
  <div
    style={{
      height: 70,
      borderRadius: 14,
      background: COLORS.surface2,
      border: `1px solid ${COLORS.borderSubtle}`,
      display: 'flex',
      alignItems: 'center',
      gap: 10,
      padding: '0 12px',
    }}
  >
    <div
      style={{
        width: 28,
        height: 28,
        borderRadius: 8,
        flexShrink: 0,
        background: COLORS.surface3,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        color: COLORS.textPrimary,
      }}
    >
      {icon}
    </div>
    <div style={{flex: 1, minWidth: 0}}>
      <div style={{display: 'flex', alignItems: 'baseline'}}>
        <span style={{fontSize: 15, fontWeight: 600}}>{title}</span>
        <span style={{marginLeft: 'auto', fontSize: 11, color: COLORS.textTertiary}}>{kbd}</span>
      </div>
      <div style={{fontSize: 12, color: COLORS.textSecondary, whiteSpace: 'nowrap'}}>{sub}</div>
    </div>
  </div>
);

/** Home page. `stagger(i)` returns a 0–1 reveal for item i. */
export const NotchHome: React.FC<{stagger: (i: number) => number}> = ({stagger}) => {
  const s = (i: number): React.CSSProperties => ({
    opacity: stagger(i),
    transform: `translateY(${(1 - stagger(i)) * 10}px)`,
  });
  return (
    <div style={{position: 'absolute', left: CARD_PAD, right: CARD_PAD, top: 62, display: 'flex', gap: 18}}>
      <div style={{width: 384}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 7, fontSize: 14, color: COLORS.textSecondary, ...s(0)}}>
          <MicIcon size={14} color={COLORS.accentText} />
          Hold ctrl + option and ask about your screen.
        </div>
        <div
          style={{
            marginTop: 12,
            height: 54,
            borderRadius: 27,
            background: COLORS.surface2,
            border: `1px solid ${COLORS.borderSubtle}`,
            display: 'flex',
            alignItems: 'center',
            padding: '0 10px 0 20px',
            fontSize: 18,
            fontWeight: 500,
            color: COLORS.textTertiary,
            ...s(1),
          }}
        >
          Ask HeyMate…
          <div
            style={{
              marginLeft: 'auto',
              width: 34,
              height: 34,
              borderRadius: 34,
              background: COLORS.surface3,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              color: COLORS.textTertiary,
            }}
          >
            <ArrowUpIcon size={16} />
          </div>
        </div>
        <div style={{marginTop: 18, ...label, ...s(2)}}>Last agent</div>
        <div
          style={{
            marginTop: 8,
            height: 62,
            borderRadius: 14,
            background: COLORS.surface2,
            border: `1px solid ${COLORS.borderSubtle}`,
            display: 'flex',
            alignItems: 'center',
            gap: 12,
            padding: '0 14px',
            ...s(3),
          }}
        >
          <Dot color={COLORS.warning} size={9} glow />
          <div>
            <div style={{fontSize: 16, fontWeight: 600}}>Test the optional checkout total</div>
            <div style={{fontSize: 13, color: COLORS.textTertiary}}>Plan ready · 6 minutes ago</div>
          </div>
          <div style={{marginLeft: 'auto', color: COLORS.textTertiary}}>
            <ChevronRightIcon size={16} />
          </div>
        </div>
      </div>
      <div style={{flex: 1}}>
        <div style={{...label, ...s(1)}}>Jump to</div>
        <div style={{marginTop: 10, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10}}>
          <div style={s(2)}>
            <Tile icon={<SparkleIcon size={15} />} title="Agents" sub="1 running" kbd="⌘1" />
          </div>
          <div style={s(3)}>
            <Tile icon={<WindowIcon size={15} />} title="Window" sub="Chat and history" kbd="⌘2" />
          </div>
          <div style={s(4)}>
            <Tile icon={<WandIcon size={15} />} title="Skills" sub="How it answers" kbd="⌘3" />
          </div>
          <div style={s(5)}>
            <Tile icon={<GearIcon size={15} />} title="Settings" sub="Voice, keys" kbd="⌘4" />
          </div>
        </div>
      </div>
    </div>
  );
};

const MICRO_APPS: [string, React.FC<{size?: number}>, boolean][] = [
  ['Shelf', TrayIcon, true],
  ['Music', MusicIcon, true],
  ['Timer', TimerIcon, true],
  ['Battery', BoltIcon, true],
  ['Event', CalendarIcon, false],
  ['Clipboard', ClipboardIcon, true],
  ['Mirror', CameraIcon, false],
  ['Download', DownloadIcon, true],
  ['Volume', SpeakerIcon, false],
  ['Tasks', ListIcon, false],
];

export const NotchApps: React.FC<{stagger: (i: number) => number; seconds: number}> = ({stagger, seconds}) => {
  const remaining = 24 * 60 + 49 - Math.floor(seconds);
  const clock = `${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, '0')}`;
  const s = (i: number): React.CSSProperties => ({
    opacity: stagger(i),
    transform: `translateY(${(1 - stagger(i)) * 10}px)`,
  });
  return (
    <div style={{position: 'absolute', left: CARD_PAD, right: CARD_PAD, top: 60, display: 'flex', gap: 18}}>
      <div style={{width: 296}}>
        <div style={{display: 'flex', ...label, ...s(0)}}>
          Micro apps
          <span style={{marginLeft: 'auto', color: COLORS.accentText}}>Manage</span>
        </div>
        <div style={{marginTop: 10, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 7}}>
          {MICRO_APPS.map(([name, Icon, on], i) => (
            <div
              key={name}
              style={{
                height: 36,
                borderRadius: 10,
                display: 'flex',
                alignItems: 'center',
                gap: 8,
                padding: '0 12px',
                fontSize: 14,
                fontWeight: 500,
                background: on ? 'rgba(51,128,255,0.12)' : COLORS.surface2,
                border: `1px solid ${on ? 'rgba(51,128,255,0.35)' : COLORS.borderSubtle}`,
                color: on ? COLORS.textPrimary : COLORS.textSecondary,
                ...s(1 + Math.floor(i / 2)),
              }}
            >
              <Icon size={15} />
              {name}
            </div>
          ))}
        </div>
      </div>
      <div style={{width: 186}}>
        <div style={{...label, ...s(1)}}>Focus timer</div>
        <div
          style={{
            marginTop: 10,
            height: 108,
            borderRadius: 14,
            background: COLORS.surface2,
            border: `1px solid ${COLORS.borderSubtle}`,
            padding: '14px 16px',
            boxSizing: 'border-box',
            ...s(2),
          }}
        >
          <div style={{fontFamily: FONTS.numeric, fontSize: 40, fontWeight: 600, fontVariantNumeric: 'tabular-nums', letterSpacing: '-0.02em'}}>
            {clock}
          </div>
          <div style={{display: 'flex', alignItems: 'center', gap: 7, marginTop: 6}}>
            <Dot color={COLORS.accent} size={7} glow />
            <span style={{fontSize: 13, color: COLORS.textSecondary}}>Deep work</span>
            <span
              style={{
                marginLeft: 'auto',
                fontSize: 13,
                fontWeight: 600,
                padding: '3px 10px',
                borderRadius: 999,
                background: COLORS.surface3,
              }}
            >
              Stop
            </span>
          </div>
        </div>
        <div style={{marginTop: 14, ...label, ...s(3)}}>Now playing</div>
        <div
          style={{
            marginTop: 8,
            height: 52,
            borderRadius: 14,
            background: COLORS.surface2,
            border: `1px solid ${COLORS.borderSubtle}`,
            display: 'flex',
            alignItems: 'center',
            gap: 10,
            padding: '0 12px',
            ...s(4),
          }}
        >
          <div style={{width: 30, height: 30, borderRadius: 7, background: 'linear-gradient(135deg,#2E3A55,#16181F)'}} />
          <div style={{fontSize: 13, lineHeight: 1.25}}>
            <div style={{fontWeight: 600}}>Focus mix</div>
            <div style={{color: COLORS.textTertiary}}>Lo-fi · 12:04</div>
          </div>
        </div>
      </div>
      <div style={{flex: 1}}>
        <div style={{...label, ...s(1)}}>File shelf</div>
        <div
          style={{
            marginTop: 10,
            height: 64,
            borderRadius: 14,
            border: `1.5px dashed ${COLORS.borderStrong}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            gap: 8,
            fontSize: 13,
            color: COLORS.textSecondary,
            ...s(2),
          }}
        >
          <FileIcon size={15} />
          Drop files on the notch
        </div>
        <div style={{marginTop: 14, display: 'flex', ...label, ...s(3)}}>
          Clipboard
          <span style={{marginLeft: 'auto', color: COLORS.textTertiary}}>Clear</span>
        </div>
        {['git push origin main', 'Thursday launch notes'].map((c, i) => (
          <div
            key={c}
            style={{
              marginTop: 8,
              height: 38,
              borderRadius: 11,
              background: COLORS.surface2,
              border: `1px solid ${COLORS.borderSubtle}`,
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              padding: '0 11px',
              fontSize: 13,
              whiteSpace: 'nowrap',
              overflow: 'hidden',
              ...s(4 + i),
            }}
          >
            <ClipboardIcon size={14} />
            <span style={{overflow: 'hidden', textOverflow: 'ellipsis'}}>{c}</span>
          </div>
        ))}
      </div>
    </div>
  );
};
