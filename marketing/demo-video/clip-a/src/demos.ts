import type {Cut, Demo} from './lib/types';

// Event times come from the take logs (key presses, clicks), HeyMate's own log
// (state changes), ElevenLabs speech-to-text of the recorded audio (word
// timings) and a pixel tracker for HeyMate's blue pointer (landing spots).
// See ../README.md for the full take notes.

// ---------------------------------------------------------------- planets
export const planets: Demo = {
  id: 'planets',
  src: 'planets.mp4',
  keys: [{down: 2.37, up: 10.49}],
  asks: [{from: 3.3, to: 10.6, text: 'Which planet in this picture is actually the biggest?'}],
  // HeyMate lands on Jupiter at 18.8 s; tip at (0.676, 0.685).
  callouts: [
    {from: 19.0, to: 21.3, text: 'Jupiter. Not even close 🪐', x: 0.676, y: 0.685},
    {from: 21.4, to: 25.0, text: 'The striped giant, right of Saturn', x: 0.676, y: 0.685},
  ],
  cam: [
    {t: 0, x: 0.6, y: 0.5, s: 1},
    {t: 18.3, x: 0.6, y: 0.5, s: 1},
    {t: 19.4, x: 0.64, y: 0.6, s: 1.75},
    {t: 24.9, x: 0.64, y: 0.6, s: 1.75},
    {t: 26.0, x: 0.6, y: 0.5, s: 1.05},
  ],
};

export const planetsMain: Cut = {
  demo: planets,
  segments: [
    {from: 0.6, to: 10.9, rate: 1},
    {from: 10.9, to: 18.3, rate: 3},
    {from: 18.3, to: 26.2, rate: 1},
  ],
};

// ---------------------------------------------------------------- keynote
// Four real pointing steps. A fifth turn, where HeyMate repeated step 3
// ("click Add an Effect") after the menu had already opened, is cut.
export const keynote: Demo = {
  id: 'keynote',
  src: 'keynote.mp4',
  keys: [
    {down: 2.38, up: 8.75},
    {down: 37.37, up: 42.95},
    {down: 63.37, up: 68.96},
    {down: 130.79, up: 138.43},
  ],
  asks: [
    {from: 3.4, to: 13.8, text: 'Okay, so… how do I make this title fly in?'},
    {from: 38.2, to: 47.8, text: 'Okay, done. Where do I click next?'},
    {from: 64.2, to: 74.9, text: 'Okay, done. Where do I click next?'},
    {from: 131.8, to: 144.9, text: 'Ooh, there’s a whole list… which one makes it fly in?'},
  ],
  callouts: [
    {from: 14.6, to: 19.0, text: 'Step 1: the title itself', x: 0.41, y: 0.535},
    {from: 48.9, to: 54.0, text: 'Step 2: the Animate tab', x: 0.937, y: 0.094, place: 'left'},
    {from: 75.6, to: 81.8, text: 'Step 3: Add an Effect', x: 0.913, y: 0.228, place: 'left'},
    {from: 145.6, to: 148.3, text: 'Step 4: Fly In ✈️', x: 0.858, y: 0.56, place: 'left'},
    {from: 163.5, to: 167.4, text: 'Whoosh. It flies in ✨', x: 0.3, y: 0.47},
  ],
  cam: [
    {t: 0, x: 0.42, y: 0.5, s: 1},
    {t: 13.9, x: 0.42, y: 0.5, s: 1},
    {t: 14.9, x: 0.42, y: 0.52, s: 1.55},
    {t: 18.9, x: 0.42, y: 0.52, s: 1.55},
    {t: 19.8, x: 0.6, y: 0.4, s: 1.0},
    {t: 47.9, x: 0.6, y: 0.4, s: 1.0},
    {t: 49.0, x: 0.84, y: 0.22, s: 1.8},
    {t: 53.9, x: 0.84, y: 0.22, s: 1.8},
    {t: 56.0, x: 0.8, y: 0.3, s: 1.3},
    {t: 74.9, x: 0.8, y: 0.3, s: 1.3},
    {t: 75.9, x: 0.84, y: 0.3, s: 1.9},
    {t: 81.9, x: 0.84, y: 0.3, s: 1.9},
    {t: 91.2, x: 0.8, y: 0.45, s: 1.3},
    {t: 131.4, x: 0.8, y: 0.45, s: 1.3},
    {t: 144.9, x: 0.8, y: 0.45, s: 1.3},
    {t: 145.9, x: 0.8, y: 0.56, s: 1.9},
    {t: 148.3, x: 0.8, y: 0.56, s: 1.9},
    {t: 162.8, x: 0.42, y: 0.5, s: 1.0},
    {t: 168, x: 0.42, y: 0.5, s: 1.0},
  ],
};

const SKIP = [{at: 131.4, text: '⏭  Cut: one repeated step'}];

export const keynoteMain: Cut = {
  demo: keynote,
  skips: SKIP,
  segments: [
    {from: 0.6, to: 9.0, rate: 1},
    {from: 9.0, to: 13.9, rate: 4},
    {from: 13.9, to: 19.3, rate: 1},
    {from: 19.3, to: 47.8, rate: 8},
    {from: 47.8, to: 54.0, rate: 1},
    {from: 54.0, to: 74.9, rate: 8},
    {from: 74.9, to: 81.9, rate: 1},
    {from: 81.9, to: 91.2, rate: 4},
    // 91.2–131.4 removed: HeyMate repeated step 3.
    {from: 131.4, to: 138.6, rate: 1},
    {from: 138.6, to: 145.0, rate: 4},
    {from: 145.0, to: 148.3, rate: 1},
    {from: 148.3, to: 162.8, rate: 6},
    {from: 162.8, to: 167.5, rate: 1},
  ],
};

// ---------------------------------------------------------------- sizzle
export const sizzleParts: Cut[] = [
  {
    demo: planets,
    segments: [
      {from: 3.3, to: 9.2, rate: 1},
      {from: 9.2, to: 18.3, rate: 16},
      {from: 18.3, to: 21.3, rate: 1},
    ],
  },
  {
    demo: keynote,
    skips: SKIP,
    segments: [
      {from: 3.3, to: 7.3, rate: 1},
      {from: 7.3, to: 14.0, rate: 16},
      {from: 14.0, to: 18.65, rate: 1},
      {from: 18.65, to: 48.3, rate: 16},
      {from: 48.3, to: 53.8, rate: 1},
      {from: 53.8, to: 74.9, rate: 16},
      {from: 74.9, to: 79.9, rate: 1},
      {from: 79.9, to: 91.2, rate: 16},
      {from: 131.4, to: 145.0, rate: 16},
      {from: 145.0, to: 148.2, rate: 1},
      {from: 148.2, to: 162.8, rate: 16},
      {from: 162.8, to: 165.3, rate: 1},
    ],
  },
];

// ---------------------------------------------------------------- README GIF (silent, ≤10 s)
export const gifCut: Cut = {
  demo: keynote,
  muted: true,
  skips: SKIP,
  segments: [
    {from: 75.1, to: 77.6, rate: 1},
    {from: 77.6, to: 91.2, rate: 20},
    {from: 131.4, to: 145.05, rate: 20},
    {from: 145.05, to: 147.6, rate: 1},
    {from: 147.6, to: 162.85, rate: 20},
    {from: 162.85, to: 165.3, rate: 1},
  ],
};
