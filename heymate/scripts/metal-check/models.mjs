// Builds the native Metal frame payload for each model in models/, through the real drawing engine and 3D stage,
// so the offscreen renderer (render.swift) can draw the same frames the app would.
// Usage: node models.mjs <out-dir> [yaw-degrees]
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const sources = new URL('../../HeyMate/', import.meta.url);
const read = name => fs.readFileSync(new URL(name, sources), 'utf8');
const outDir = process.argv[2];
const yaw = (+process.argv[3] || 32) * Math.PI / 180;
fs.mkdirSync(outDir, { recursive: true });

const engineContext = vm.createContext({});
vm.runInContext(read('mate-draw-engine.js'), engineContext);

function payloadFor(code) {
  const marks = engineContext.MateDraw.runCode(code, 820, 640);
  if (marks.error) throw Error(marks.error);
  const messages = [];
  let now = 1000, nextFrame;
  class Element {
    constructor(tag, attrs = {}) { this.tagName = tag; this.nodeType = 1; this.attrs = attrs; this.style = {}; this.children = []; this.id = attrs.id; }
    getAttribute(key) { return this.attrs[key] ?? null; }
    setAttribute(key, value) { this.attrs[key] = value; }
    appendChild(child) { this.children.push(child); }
    remove() {}
    getBoundingClientRect() { return { left: 0, top: 0, width: parseFloat(this.style.width) || 620, height: parseFloat(this.style.height) || 520 }; }
  }
  const context = vm.createContext({ console, performance: { now: () => now },
    window: { devicePixelRatio: 2, webkit: { messageHandlers: { heymate: { postMessage: message => messages.push(message.body) } } } },
    __heymateNativeMetal: true,
    document: { createElement: tag => new Element(tag), createElementNS: (_, tag) => new Element(tag) },
    MutationObserver: class { observe() {} disconnect() {} },
    requestAnimationFrame: callback => { nextFrame = callback; return 1; },
  });
  for (const name of ['three-r159.min.js', 'mate-three.js', 'mate-three-parts.js', 'mate-metal-bridge.js', 'mate-stage3d.js']) vm.runInContext(read(name), context);
  const root = new Element('root');
  for (const m of marks) {
    if (m.do === 'stage3d') root.children.push(new Element('scene3d', { id: m.id, x: 0, y: 0, width: m.w, height: m.h, 'data-ink': m.ink, 'data-camera': JSON.stringify(m.camera || {}), 'data-look': m.look || null }));
    else if (m.do === 'part3d') root.children.push(new Element('part3d', { 'data-stage': m.stage, 'data-part': JSON.stringify({ id: m.id, kind: m.kind, params: m.params, at: m.pos, rotate: m.rotate3, scale: m.scale3, material: m.material, parent: m.parent, three: m.three, recipe: m.recipe, name: m.name }) }));
    else if (m.do === 'motion3d' || m.do === 'camera3d') root.children.push(new Element(m.do, { 'data-stage': m.stage, 'data-op': JSON.stringify(m.op || {}) }));
  }
  context.MateStage3D.attach(root, {});
  const stage = [...context.MateStage3D.stages.values()][0];
  const release = () => { for (const body of messages) if (body.op === 'frame') context.MateMetal.presented(body.id); };
  for (const time of [1100, 1600, 2400, 3200]) { now = time; nextFrame(); release(); }
  stage.spin = 0; stage.yaw = yaw;
  now = 3300; nextFrame(); release();
  const frames = messages.filter(body => body.op === 'frame');
  const last = frames[frames.length - 1];
  return { ...last, geometries: frames.flatMap(frame => frame.geometries) };
}

const dir = new URL('models/', import.meta.url);
for (const file of fs.readdirSync(dir).filter(name => name.endsWith('.js')).sort()) {
  const payload = payloadFor(fs.readFileSync(new URL(file, dir), 'utf8'));
  fs.writeFileSync(path.join(outDir, file.replace(/\.js$/, '.json')), JSON.stringify(payload));
  console.log(file, payload.meshes.length, 'meshes');
}
