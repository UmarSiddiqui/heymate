// Shapes shared by every demo. All times are RAW recording seconds and all
// positions are normalised (0–1) across the 3024×1700 top-of-screen crop
// that `public/<id>.mp4` holds (scaled to 2560×1440). Times get mapped
// through a cut's segment list, so trimming never desyncs an overlay.

export type Segment = {from: number; to: number; rate: number};

/** Camera keyframe: centre (x, y) and zoom s (1 = the whole 16:9 frame). */
export type CamKey = {t: number; x: number; y: number; s: number};

/** A short, playful label that rides beside HeyMate's cursor. */
export type Callout = {
  from: number;
  to: number;
  text: string;
  /** The cursor tip HeyMate landed on. */
  x: number;
  y: number;
  /** Which side of the tip the label sits on (HeyMate's own bubble sits below-right). */
  place?: 'above' | 'left' | 'below' | 'aboveLeft';
};

export type Ask = {from: number; to: number; text: string};
export type Keys = {down: number; up: number};

export type Demo = {
  id: string;
  src: string;
  callouts: Callout[];
  asks: Ask[];
  keys: Keys[];
  cam: CamKey[];
};

export type Cut = {
  demo: Demo;
  segments: Segment[];
  /** Raw times right after a removed stretch, to show a "skipped" chip. */
  skips?: {at: number; text: string}[];
  muted?: boolean;
};
