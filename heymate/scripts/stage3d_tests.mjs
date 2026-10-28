import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import vm from 'node:vm';
import test from 'node:test';

const sources = new URL('../HeyMate/', import.meta.url);

function stageHarness(width = 300, height = 500, look = null, nativeMetal = false) {
  const messages = [];
  let now = 1000, nextFrame;
  class Element {
    constructor(tag, attrs = {}) { this.tagName = tag; this.nodeType = 1; this.attrs = attrs; this.style = {}; this.children = []; this.id = attrs.id; }
    getAttribute(key) { return this.attrs[key]; }
    setAttribute(key, value) { this.attrs[key] = value; }
    appendChild(child) { this.children.push(child); }
    remove() {}
    getBoundingClientRect() { return { left: parseFloat(this.style.left) || 0, top: parseFloat(this.style.top) || 0, width, height }; }
  }
  const context = vm.createContext({ console, performance: { now: () => now },
    window: { devicePixelRatio: 1, webkit: { messageHandlers: { heymate: { postMessage: message => messages.push(message) } } } },
    __heymateNativeMetal: nativeMetal,
    document: { createElement: tag => new Element(tag), createElementNS: (_, tag) => new Element(tag) },
    MutationObserver: class { observe() {} disconnect() {} },
    requestAnimationFrame: callback => { nextFrame = callback; return 1; }
  });
  vm.runInContext(fs.readFileSync(new URL('three-r159.min.js', sources), 'utf8'), context);
  vm.runInContext(`
    THREE.WebGLRenderer = class {
      constructor() { this.shadowMap = {}; }
      setPixelRatio() {} setSize() {} dispose() {}
      render(scene, camera) { scene.updateMatrixWorld(true); camera.updateMatrixWorld(true); }
    };
    THREE.PMREMGenerator = class { fromScene() { return { texture: null }; } };
    globalThis.mateThreeBuild = () => ({ positions: new Float32Array([-1,-1,-1, 1,-1,-1, 0,1,1]) });
  `, context);
  vm.runInContext(fs.readFileSync(new URL('mate-metal-bridge.js', sources), 'utf8'), context);
  if (nativeMetal) vm.runInContext(`THREE.WebGLRenderer = class { constructor() { throw Error('Native stage created WebGL'); } };`, context);
  vm.runInContext(fs.readFileSync(new URL('mate-stage3d.js', sources), 'utf8'), context);
  const root = new Element('root');
  root.children.push(new Element('scene3d', { id: 'stage', x: 20, y: 30, width, height, 'data-camera': '{"spin":0}', 'data-look': look }));
  const part = data => new Element('part3d', { 'data-stage': 'stage', 'data-part': JSON.stringify(data) });
  // Same beat: parent must exist before its child.
  root.children.push(part({ id: 'group', kind: 'group', at: [4,0,0], scale: 2 }));
  root.children.push(part({ id: 'blade', name: 'fanBlade', kind: 'box', parent: 'group', at: [1,0,0] }));
  root.children.push(part({ id: 'p3', name: 'shaft', kind: 'box', at: [-3,0,0] }));
  root.children.push(new Element('label3d', { 'data-stage': 'stage', 'data-label': JSON.stringify({follow:'blade',text:'Fan blade',side:'left'}) }));
  const points = [];
  context.MateStage3D.attach(root, { onBuild: (x,y,name) => points.push({ x,y,name }) });
  return { points, messages, context, stage: context.MateStage3D.stages.get('stage'), tick(time) { now = time; nextFrame(); } };
}

test('same-beat grouped parts retain parent and final-size bounds', () => {
  const h = stageHarness(); h.tick(1100);
  assert.equal(h.stage.parts.get('blade').parent, h.stage.parts.get('group'));
  assert.ok(h.stage.radius > 5, 'bounds must include full-size group, not its near-zero growing scale');
});

test('first build visit uses framed camera and groups do not consume visits', () => {
  const h = stageHarness(); h.tick(1100);
  assert.equal(h.points.length, 1);
  assert.equal(h.points[0].name, 'fan blade');
  assert.ok(Number.isFinite(h.points[0].x) && Number.isFinite(h.points[0].y));
  assert.ok(h.points[0].x >= 20 && h.points[0].x <= 320);
  assert.ok(h.points[0].y >= 30 && h.points[0].y <= 530);
  h.tick(1600);
  assert.equal(h.points.length, 2);
  assert.equal(h.points[1].name, 'shaft');
});

test('portrait camera fits model sphere and explicit zero spin stays still', () => {
  const h = stageHarness(160, 500); h.tick(1100); h.tick(2000);
  assert.equal(h.stage.spin, 0);
  assert.equal(h.stage.yaw, 0);
  const camera = h.stage.camera;
  const halfHorizontal = Math.atan(Math.tan(camera.fov * Math.PI / 360) * camera.aspect);
  const distance = camera.position.distanceTo(h.stage.centre);
  assert.ok(distance * Math.sin(halfHorizontal) >= h.stage.radius);
});

test('illustrated stages execute translated native fragment; studio keeps separate material path', () => {
  const illustrated = stageHarness(300, 500, 'illustrated'); illustrated.tick(1800);
  const mesh = illustrated.stage.parts.get('blade'), material = mesh.material;
  assert.ok(material.isShaderMaterial && material.userData.nativeDaVinci);
  assert.equal(material.toneMapped, false, 'native shader already encodes sRGB');
  assert.ok(material.fragmentShader.includes('smoothstep(-0.08, 0.14, facing)'));
  assert.ok(material.fragmentShader.includes('0.985 - 0.06 * metalness'));
  mesh.onBeforeRender(null, null, illustrated.stage.camera);
  assert.equal(material.uniforms.frame.value.style.x, 1);
  assert.equal(material.uniforms.object.value.baseColor.x, material.color.r);
  material.color.set('#FF0000'); material.emissive = material.color.clone(); material.emissiveIntensity = 0.3;
  mesh.onBeforeRender(null, null, illustrated.stage.camera);
  assert.equal(material.uniforms.object.value.baseColor.x, 1);
  assert.equal(material.uniforms.object.value.baseColor.y, 0);
  assert.equal(material.uniforms.object.value.emissive.x, 0.3);
  const studio = stageHarness(300, 500, 'studio'); studio.tick(1800);
  assert.ok(studio.stage.parts.get('blade').material.isMeshStandardMaterial);
});

test('native fragment bodies remain mechanical MSL-to-GLSL translations of retained source', () => {
  const source = fs.readFileSync(new URL('native-shaders/davinci.metal', import.meta.url), 'utf8');
  const provenance = JSON.parse(fs.readFileSync(new URL('native-shaders/provenance.json', import.meta.url), 'utf8'));
  assert.equal(Buffer.byteLength(source), provenance.bytes);
  assert.equal(createHash('sha256').update(source).digest('hex'), provenance.sourceSHA256);
  const names = ['D_GGX', 'V_GGX_SmithCorrelated', 'F_Schlick', 'BRDF_GGX', 'sRGBFromLinear', 'davinci_fragment'];
  const chunks = names.map(name => {
    const match = new RegExp('^(?:fragment )?float[234]? ' + name + '\\(', 'm').exec(source);
    assert.ok(match, name);
    const start = source.indexOf('{', match.index);
    let i = start + 1, depth = 1;
    while (depth) { depth += (source[i] === '{') - (source[i] === '}'); i++; }
    return name === 'davinci_fragment'
      ? 'vec4 davinci_fragment(VertexOut vertexData, bool isFrontFacing, FrameUniforms frame, ObjectUniforms object) ' + source.slice(start, i)
      : source.slice(match.index, i);
  });
  let expected = 'const float RECIPROCAL_PI = 0.3183098861837907;\n' + chunks.join('\n');
  for (const [from, to] of [['float4x4','mat4'],['float3x3','mat3'],['float4','vec4'],['float3','vec3'],['float2','vec2'],['dfdx','dFdx'],['dfdy','dFdy'],['in','vertexData']]) {
    expected = expected.replace(new RegExp('\\b' + from + '\\b', 'g'), to);
  }
  expected = expected.replace('vec3(value <= 0.0031308)', 'vec3(lessThanEqual(value, vec3(0.0031308)))');
  expected = expected.replace('vec3 directions[2] = { normalize(vec3(3.0, 5.0, 4.0)), normalize(vec3(-4.0, 2.0, -4.0)) };',
    'vec3 directions[2]; directions[0] = normalize(vec3(3.0, 5.0, 4.0)); directions[1] = normalize(vec3(-4.0, 2.0, -4.0));');
  expected = expected.replace('vec3 colors[2] = { vec3(2.2), vec3(0.34670, 0.55201, 1.0) * 0.9 };',
    'vec3 colors[2]; colors[0] = vec3(2.2); colors[1] = vec3(0.34670, 0.55201, 1.0) * 0.9;');
  const illustrated = stageHarness(300, 500, 'illustrated'); illustrated.tick(1800);
  assert.ok(illustrated.stage.parts.get('blade').material.fragmentShader.includes(expected));
});


test('native stage bypasses WebGL and transfers geometry once with GPU backpressure', () => {
  const h = stageHarness(300, 500, 'illustrated', true);
  h.tick(1800);
  const first = h.messages[0].body;
  assert.equal(first.op, 'frame');
  assert.equal(first.meshes.length, 2);
  assert.equal(first.geometries.length, 2);
  assert.equal(first.viewProjection.length, 16);
  assert.equal(first.labels.length, 1);
  assert.equal(first.labels[0].text, 'Fan blade');
  assert.ok(Number.isFinite(first.labels[0].ax) && Number.isFinite(first.labels[0].ay));
  assert.equal(first.meshes[0].normal.length, 9);
  assert.equal(first.meshes[0].model[12], 6, 'parent scale and translation lost');
  h.tick(1900);
  assert.equal(h.messages.length, 1, 'frame queue must stay bounded');
  h.context.MateMetal.presented(first.id, null);
  h.stage.parts.get('blade').material.color.set('#FF0000');
  h.tick(2000);
  assert.equal(h.messages.length, 2);
  assert.equal(h.messages[1].body.geometries.length, 0);
  assert.deepEqual(Array.from(h.messages[1].body.meshes[0].color), [1,0,0]);
  h.context.MateStage3D.reset();
  assert.equal(h.messages.at(-1).body.op, 'remove');
});

test('native studio sends physical shader style; hidden geometry survives being shown again', () => {
  const h = stageHarness(300, 500, 'studio', true); h.tick(1800);
  const first = h.messages[0].body;
  assert.equal(first.illustrated, false);
  const mesh = h.stage.parts.get('blade');
  mesh.visible = false;
  h.context.MateMetal.presented(first.id); h.tick(1900);
  assert.equal(h.messages[1].body.meshes.length, 1);
  mesh.visible = true;
  mesh.userData.material = { cut: [1,0,0,0], bands: ['#FF0000', '#FFFFFF'] };
  h.context.MateMetal.presented(first.id); h.tick(2000);
  const restored = h.messages[2].body;
  assert.equal(restored.meshes.length, 2);
  assert.equal(restored.geometries.length, 0);
  assert.deepEqual(Array.from(restored.meshes[0].cut), [1,0,0,0]);
  assert.equal(restored.meshes[0].bands.length, 2);
});

test('bundled Metal source remains byte-identical to recovered shader', () => {
  assert.deepEqual(fs.readFileSync(new URL('DaVinciShaders.txt', sources)),
    fs.readFileSync(new URL('native-shaders/davinci.metal', import.meta.url)));
});


test('native picking excludes removed cut surfaces and hidden parents', () => {
  const h = stageHarness(300, 500, 'illustrated', true); h.tick(1800);
  const st = h.stage, mesh = st.parts.get('blade');
  const v = mesh.getWorldPosition(new h.context.THREE.Vector3()).project(st.camera);
  const x = 20 + (v.x + 1) / 2 * st.w, y = 30 + (1 - v.y) / 2 * st.h;
  assert.equal(h.context.MateStage3D.pick(st, x, y), 'fanBlade');
  mesh.userData.material = {cut:[1,0,0,-100]};
  assert.notEqual(h.context.MateStage3D.pick(st, x, y), 'fanBlade');
  mesh.userData.material = {};
  st.parts.get('group').visible = false;
  assert.notEqual(h.context.MateStage3D.pick(st, x, y), 'fanBlade');
});

test('airplane token prefixes produce same meshes and hierarchy as complete program', () => {
  const context = vm.createContext({console});
  vm.runInContext(fs.readFileSync(new URL('mate-draw-engine.js', sources), 'utf8'), context);
  const program = fs.readFileSync(new URL('airplane-metal-test.js', import.meta.url), 'utf8');
  const expected = context.MateDraw.runCode(program, 1512, 982);
  assert.equal(expected.error, null);
  const session = context.MateDraw.Session(1512, 982);
  const received = [], partialCounts = [], says = [];
  for (let end = 120; ; end += 120) {
    const done = end >= program.length;
    const result = session.update(program.slice(0, end), done);
    assert.equal(result.error, null);
    received.push(...result.marks);
    says.push(...result.says);
    partialCounts.push(received.filter(m => m.do === 'part3d' && m.kind !== 'group').length);
    if (done) break;
  }
  const parts = marks => marks.filter(m => m.do === 'part3d').map(m => ({
    id:m.id, kind:m.kind, parent:m.parent, recipe:m.recipe, pos:m.pos, rotate:m.rotate3
  }));
  assert.equal(received.filter(m => m.do === 'part3d' && m.kind !== 'group').length, 52);
  assert.ok(partialCounts.some(n => n > 0 && n < 52), 'meshes must arrive before final prefix');
  assert.deepEqual(JSON.parse(JSON.stringify(parts(received))), JSON.parse(JSON.stringify(parts(expected))));
  assert.equal(says.length, 4);
});
