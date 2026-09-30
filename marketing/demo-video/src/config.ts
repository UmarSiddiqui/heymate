// Brand tokens, timing and copy for the HeyMate demo video.
// Everything you are likely to tweak lives in this one file.
//
// Colors mirror `heymate/leanring-buddy/DesignSystem.swift` (dark mode) and
// `AppTheme.swift`. The only UI accent is Signal blue, the app's default
// buddy color. Violet (`iconGlow`) is reserved for the logo reveal.

export const COLORS = {
  // Matte neutrals, deepest to most elevated (DS.Colors.background … surface4)
  background: '#0A0A0A',
  surface1: '#121213',
  surface2: '#1A1A1C',
  surface3: '#232325',
  surface4: '#2D2D30',
  notch: '#000000',

  borderSubtle: '#262628',
  borderStrong: '#3E3E42',

  textPrimary: '#F5F5F7',
  textSecondary: '#B3B3BA',
  textTertiary: '#84848C',

  // Accent — AppTheme "Signal"
  accent: '#3380FF',
  accentText: '#6FA5FF', // Signal blended 28% with white (DS.Colors.accentText)
  userBubble: '#2254A8', // Signal blended 34% with black (DS.Colors.helpChatUserBubble)

  // Semantic
  success: '#34D399',
  warning: '#FFB224',
  warningText: '#F1A10D',
  destructive: '#E5484D',
  destructiveText: '#FF6369',
  codeText: '#9DC2FF',

  // Brand identity only — the app icon's halo. Never UI.
  iconGlow: '#5E54FF',
} as const;

export const FONTS = {
  // DS.Fonts: Avenir Next carries the voice.
  ui: '"Avenir Next", Avenir, -apple-system, "Helvetica Neue", sans-serif',
  mono: '"SF Mono", Menlo, Monaco, monospace',
  numeric: '-apple-system, "SF Pro Rounded", "Helvetica Neue", sans-serif',
} as const;

export const FPS = 60;

// Scene lengths in seconds. Reorder scenes in `src/HeyMateDemo.tsx`.
export const SCENE_SECONDS = {
  hook: 4.5,
  logo: 3.5,
  notch: 6,
  vision: 7,
  agents: 7.5,
  mates: 6.5,
  close: 5,
} as const;

// Cross-fade length between scenes, in frames (60 = 1 s).
export const TRANSITION_FRAMES = 18;

// Swift `spring(response:dampingFraction:)` converted to mass/stiffness/damping.
// buddySpring: response 0.42, damping 0.78. controlSpring: 0.28, 0.72.
export const SPRINGS = {
  buddy: {mass: 1, stiffness: 224, damping: 23.3},
  control: {mass: 1, stiffness: 504, damping: 32.3},
  gentle: {mass: 1, stiffness: 120, damping: 22},
} as const;

// ─── Music slot ───────────────────────────────────────────────────────────
// Put your own licensed track in `public/music/` and set its filename here,
// e.g. 'music/heymate-theme.mp3'. Leave null for a silent render.
export const MUSIC_SRC: string | null = 'music/show-me-by-peyruis.mp3';
export const MUSIC_VOLUME = 0.7;
// Fade the music in/out over this many seconds.
export const MUSIC_FADE_SECONDS = 1;

// ─── Copy ────────────────────────────────────────────────────────────────
export const COPY = {
  hook: {
    // Fans roaring, beachball spinning. \n breaks the line in the vertical cut.
    symptom: 'fans at 6,200 rpm  ·  memory pressure: high',
    question: 'Why is my Mac\nso slow?',
    chores: ['Open Activity Monitor', 'Sort by CPU', 'Look it up', 'Guess'],
    answer: "There's a faster way.",
  },
  logo: {
    name: 'HeyMate',
    tagline: "Say hey. It's already looking.",
  },
  notch: {
    title: 'Lives in your notch.',
    sub: 'Hover to peek. Click to open. Out of the way the rest of the time.',
  },
  vision: {
    title: 'It sees what you see.',
    sub: 'Hold control + option, ask, let go. It points at the answer and says it out loud.',
    question: 'Why is my Mac so slow?',
    reply: '`Chrome Helper (Renderer)` is at 97% CPU. That\'s one runaway tab. Close it and your Mac speeds back up.',
  },
  agents: {
    title: 'Real work.\nWith a leash.',
    sub: 'Agents plan read-only. Nothing changes until you approve.',
    brainsLabel: 'Runs on the subscription you already have',
    brains: ['claude', 'codex', 'opencode'],
  },
  mates: {
    title: 'Not one assistant.\nA small team.',
    sub: 'Mates with their own job, memory, and schedule.',
  },
  close: {
    line: 'Say hey.',
    cta: 'Download free for Mac',
    meta: 'macOS 14.2+  ·  Free  ·  Bring your own AI',
    url: 'getheymate.vercel.app',
  },
} as const;
