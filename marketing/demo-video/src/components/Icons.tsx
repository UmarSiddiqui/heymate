// Simple line icons drawn for this video (no third-party icon set).
import React from 'react';

type IconProps = {size?: number; color?: string; stroke?: number; style?: React.CSSProperties};

const Svg: React.FC<IconProps & {children: React.ReactNode}> = ({
  size = 16,
  color = 'currentColor',
  stroke = 1.7,
  style,
  children,
}) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke={color}
    strokeWidth={stroke}
    strokeLinecap="round"
    strokeLinejoin="round"
    style={{flexShrink: 0, ...style}}
  >
    {children}
  </svg>
);

export const HomeIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M4 11.5 12 5l8 6.5" />
    <path d="M6.5 10v9h11v-9" />
  </Svg>
);

export const GridIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <rect x="4.5" y="4.5" width="6" height="6" rx="1.5" />
    <rect x="13.5" y="4.5" width="6" height="6" rx="1.5" />
    <rect x="4.5" y="13.5" width="6" height="6" rx="1.5" />
    <rect x="13.5" y="13.5" width="6" height="6" rx="1.5" />
  </Svg>
);

export const SparkleIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M12 3.5c.6 4.2 2.3 5.9 6.5 6.5-4.2.6-5.9 2.3-6.5 6.5-.6-4.2-2.3-5.9-6.5-6.5 4.2-.6 5.9-2.3 6.5-6.5Z" />
    <path d="M18.5 15.5c.25 1.6.9 2.25 2.5 2.5-1.6.25-2.25.9-2.5 2.5-.25-1.6-.9-2.25-2.5-2.5 1.6-.25 2.25-.9 2.5-2.5Z" />
  </Svg>
);

export const PowerIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M12 4v7" />
    <path d="M7.2 7.2a7 7 0 1 0 9.6 0" />
  </Svg>
);

export const ChevronUpIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="m6 14 6-6 6 6" />
  </Svg>
);

export const ChevronRightIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="m9 6 6 6-6 6" />
  </Svg>
);

export const ChevronDownIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="m6 9 6 6 6-6" />
  </Svg>
);

export const MicIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <rect x="9" y="3.5" width="6" height="11" rx="3" />
    <path d="M5.5 11.5a6.5 6.5 0 0 0 13 0" />
    <path d="M12 18v2.5" />
  </Svg>
);

export const ArrowUpIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M12 19V5" />
    <path d="m6 11 6-6 6 6" />
  </Svg>
);

export const WindowIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <rect x="3.5" y="5" width="17" height="14" rx="2.5" />
    <path d="M3.5 9h17" />
  </Svg>
);

export const GearIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="3" />
    <path d="M12 3.5v2.2M12 18.3v2.2M20.5 12h-2.2M5.7 12H3.5M18 6l-1.6 1.6M7.6 16.4 6 18M18 18l-1.6-1.6M7.6 7.6 6 6" />
  </Svg>
);

export const WandIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="m4 20 11-11" />
    <path d="M17 3v3M15.5 4.5h3M20 8v2M19 9h2" />
  </Svg>
);

export const CpuIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <rect x="6" y="6" width="12" height="12" rx="2.5" />
    <rect x="9.5" y="9.5" width="5" height="5" rx="1" />
    <path d="M9 3.5V6M15 3.5V6M9 18v2.5M15 18v2.5M3.5 9H6M3.5 15H6M18 9h2.5M18 15h2.5" />
  </Svg>
);

export const InfoIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M12 11v5M12 8h.01" />
  </Svg>
);

export const TimerIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <circle cx="12" cy="13" r="7.5" />
    <path d="M12 9v4l2.5 2M10 3h4" />
  </Svg>
);

export const TrayIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M4 13.5 6.5 6h11l2.5 7.5V18a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 18Z" />
    <path d="M4 13.5h4.5l1 2h5l1-2H20" />
  </Svg>
);

export const MusicIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M6 10v4M9 7v10M12 9v6M15 5v14M18 10v4" />
  </Svg>
);

export const BoltIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M13 3 6 13.5h5.5L10.5 21 18 10h-5.5Z" />
  </Svg>
);

export const CalendarIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <rect x="4" y="5.5" width="16" height="14" rx="2.5" />
    <path d="M4 10h16M8.5 3.5v3M15.5 3.5v3" />
  </Svg>
);

export const ClipboardIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <rect x="6" y="5" width="12" height="15.5" rx="2" />
    <path d="M9.5 3.5h5v3h-5z" />
  </Svg>
);

export const CameraIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M4 8.5A1.5 1.5 0 0 1 5.5 7h2.5l1.5-2h5l1.5 2h2.5A1.5 1.5 0 0 1 20 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5Z" />
    <circle cx="12" cy="12.5" r="3.2" />
  </Svg>
);

export const DownloadIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M12 8v7.5M8.8 12.5 12 15.7l3.2-3.2" />
  </Svg>
);

export const SpeakerIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M4.5 9.5h3l4.5-4v13l-4.5-4h-3Z" />
    <path d="M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11" />
  </Svg>
);

export const ListIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <rect x="4" y="5" width="4" height="4" rx="1" />
    <rect x="4" y="15" width="4" height="4" rx="1" />
    <path d="M11 7h9M11 17h9" />
  </Svg>
);

export const FileIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M7 3.5h6.5L18 8v12.5H7Z" />
    <path d="M13.5 3.5V8H18" />
  </Svg>
);

export const SearchIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <circle cx="11" cy="11" r="6" />
    <path d="m15.5 15.5 4 4" />
  </Svg>
);

export const PlusIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M12 5v14M5 12h14" />
  </Svg>
);

export const CheckIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="m5.5 12.5 4 4 9-9" />
  </Svg>
);

export const ClockIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M12 7.5V12l3 2" />
  </Svg>
);

export const UndoIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M8 8H14a5 5 0 0 1 0 10H9" />
    <path d="M10.5 5 7.5 8l3 3" />
  </Svg>
);

export const FolderIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M3.5 7.5A1.5 1.5 0 0 1 5 6h4.5l2 2H19a1.5 1.5 0 0 1 1.5 1.5v8A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5Z" />
  </Svg>
);

export const PlanIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <circle cx="6" cy="7" r="1.8" />
    <circle cx="6" cy="17" r="1.8" />
    <path d="M10.5 7h9M10.5 17h9M10.5 12h6" />
  </Svg>
);

export const HistoryIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3L4.5 9" />
    <path d="M4.5 4.5V9H9M12 8v4l3 2" />
  </Svg>
);

export const PanelIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <rect x="3.5" y="5" width="17" height="14" rx="2.5" />
    <path d="M14.5 5v14" />
  </Svg>
);

export const PaperclipIcon: React.FC<IconProps> = (p) => (
  <Svg {...p}>
    <path d="m19 11.5-7.1 7.1a4.5 4.5 0 0 1-6.4-6.4l7.4-7.4a3 3 0 0 1 4.2 4.2l-7.3 7.3a1.5 1.5 0 0 1-2.1-2.1l6.6-6.6" />
  </Svg>
);

/** The HeyMate cursor buddy: a rounded arrow, like the app icon's mark. */
export const BuddyCursor: React.FC<{size?: number; color: string; glow?: number}> = ({
  size = 40,
  color,
  glow = 1,
}) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 40 40"
    style={{
      overflow: 'visible',
      filter: `drop-shadow(0 0 ${10 * glow}px ${color}) drop-shadow(0 4px 10px rgba(0,0,0,0.5))`,
    }}
  >
    <path
      d="M6.2 4.4c-.9-.5-2 .3-1.8 1.3l5.8 28.6c.2 1.1 1.7 1.3 2.2.3l5.3-10.3c.3-.6.9-1 1.6-1.1l11.4-1.2c1.1-.1 1.4-1.6.4-2.1Z"
      fill={color}
      stroke="rgba(255,255,255,0.9)"
      strokeWidth={1.6}
      strokeLinejoin="round"
    />
  </svg>
);

/** A plain macOS-style system pointer (drawn for this video). */
export const SystemPointer: React.FC<{size?: number; press?: number}> = ({size = 28, press = 0}) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 28 28"
    style={{
      overflow: 'visible',
      transform: `scale(${1 - press * 0.12})`,
      transformOrigin: '4px 3px',
      filter: 'drop-shadow(0 2px 3px rgba(0,0,0,0.55))',
    }}
  >
    <path
      d="M4 2.5v19.2l4.9-4.6 3.2 7.4 3.4-1.5-3.2-7.2h6.7Z"
      fill="#111"
      stroke="#fff"
      strokeWidth={1.6}
      strokeLinejoin="round"
    />
  </svg>
);
