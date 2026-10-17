// Native adapter: upstream owns geometry, idle loops, expression poses and gaze.
import { _posed, lerpPose } from "blobatar/internal";
import { idleAt, idleSeeds, idleTransforms } from "blobatar/idle";
import { idle, happy, sad, surprised, thinking, wink } from "blobatar/expression";
import { project, step, SETTLE } from "blobatar/gaze";

const expressions = { idle, happy, sad, surprised, thinking, wink };
const figures = new Map();
const states = new Map();
function figure(seed, options) {
  const key = JSON.stringify([seed, options]);
  if (!figures.has(key)) {
    if (figures.size >= 256) figures.delete(figures.keys().next().value);
    figures.set(key, { ..._posed(seed, { ...options, background: false }), seeds: idleSeeds(seed, options) });
  }
  return figures.get(key);
}
// SVG transform lists multiply in written order, matching nested native layers.
function multiply(a, b) {
  return [a[0]*b[0]+a[2]*b[1], a[1]*b[0]+a[3]*b[1],
    a[0]*b[2]+a[2]*b[3], a[1]*b[2]+a[3]*b[3],
    a[0]*b[4]+a[2]*b[5]+a[4], a[1]*b[4]+a[3]*b[5]+a[5]];
}
function matrix(text, gaze = null) {
  let out = [1,0,0,1,0,0];
  const first = new Set();
  for (const match of text.matchAll(/(translate|rotate|scale)\(([^)]+)\)/g)) {
    const name = match[1];
    const v = match[2].trim().split(/[ ,]+/).map(Number);
    if (gaze && !first.has(name)) {
      if (name === "translate") { v[0] += gaze.dx; v[1] += gaze.dy; }
      if (name === "rotate") v[0] += gaze.t;
      if (name === "scale") { v[0] *= gaze.sx; v[1] *= gaze.sy; }
      first.add(name);
    }
    let part;
    if (name === "translate") part = [1,0,0,1,v[0],v[1] || 0];
    else if (name === "scale") part = [v[0],0,0,v[1] ?? v[0],0,0];
    else { const r = v[0]*Math.PI/180; part = [Math.cos(r),Math.sin(r),-Math.sin(r),Math.cos(r),0,0]; }
    out = multiply(out, part);
  }
  return out;
}
function frame(id, seed, options, expression, now, animate, target, face) {
  const f = figure(seed, options);
  const goal = (expressions[expression] || idle).p;
  let state = states.get(id);
  if (!state || state.seed !== seed || state.options !== JSON.stringify(options)) {
    state = { seed, options: JSON.stringify(options), expression, shown: goal, from: goal, start: now, last: now, born: now, x: 0, y: 0, hold: 0 };
    states.set(id, state);
  }
  if (state.expression !== expression) {
    state.from = state.shown; state.start = now; state.expression = expression;
  }
  const duration = expression === "idle" ? 560 : 300;
  const progress = animate ? Math.max(0, Math.min(1, (now - state.start) / duration)) : 1;
  // Ease out; interrupting a morph starts from the currently displayed pose.
  state.shown = lerpPose(state.from, goal, 1 - Math.pow(1 - progress, 3));
  const elapsed = animate ? Math.max(0, now - state.born) : 0;
  const dt = Math.max(0, Math.min(64, now - state.last)); state.last = now;
  const k = 1 - Math.exp(-dt / SETTLE);
  const aim = step({ x: state.x, y: state.y, dx: target?.dx || 0, dy: target?.dy || 0,
    radius: target?.radius || 1, k, gain: animate && target ? 1 : 0 });
  state.x = animate ? aim.x : 0; state.y = animate ? aim.y : 0;
  state.hold = animate ? state.hold + ((target ? 1 : 0) - state.hold) * k : 0;
  const seeds = { ...f.seeds };
  for (const key of ["lookX", "lookY", "lookMX", "lookMY"]) seeds[key] *= 1 - state.hold;
  const loops = idleAt(seeds, elapsed, animate ? 1 : 0, animate ? state.shown.shake : 0);
  const t = idleTransforms({ eyes: f.eyeFrames }, state.shown, loops);
  const body = multiply(multiply(matrix(t.root), matrix(t.breathe)), matrix(t.bob));
  const eyePair = multiply(body, matrix(t.eyes));
  const eyes = f.eyeFrames.map((eye, i) => {
    const mark = face.marks[i];
    const p = project(mark, state.x * 3.5 / face.rx, state.y * 3.5 / face.ry);
    p.dx *= face.rx; p.dy *= face.ry;
    return multiply(multiply(eyePair, matrix(t.eye[i], p)), matrix(t.glance[i]));
  });
  return { body, eyes };
}
globalThis.HeyMateBlobatar = { figure, frame, forget: id => states.delete(id) };
