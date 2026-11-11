// A round friendly robot mascot.
const f = figure(100, 60, 620, 520, { spin: 0, tilt: 8 });
f.lathe({ name: 'Body', profile: [[0, -0.75], [0.5, -0.72], [0.62, -0.4], [0.6, 0.1], [0.42, 0.3], [0, 0.32]], mat: 'gloss:#ff8a3d' });
f.sphere({ name: 'Head', r: 0.52, at: [0, 0.82, 0], mat: 'gloss:#ffe9c9' });
f.sphere({ name: 'Eye', r: 0.09, at: [0.18, 0.9, 0.45], mat: 'black', mirror: 'x' });
f.sphere({ name: 'Glint', r: 0.03, at: [0.2, 0.93, 0.52], mat: 'glow:white', mirror: 'x' });
f.torus({ name: 'Smile', r: 0.14, tube: 0.02, axis: 'z', at: [0, 0.7, 0.48], sweep: 180, rot: [0, 0, 180], mat: 'black' });
f.cyl({ name: 'Antenna', r: 0.02, h: 0.3, at: [0, 1.45, 0], mat: 'steel' });
f.sphere({ name: 'Antenna tip', r: 0.07, at: [0, 1.63, 0], mat: 'glow:#39c5ff' });
f.capsule({ name: 'Arm', r: 0.1, h: 0.45, at: [0.75, -0.05, 0], rot: [0, 0, 25], mat: 'soft:#ffe9c9', mirror: 'x' });
f.sphere({ name: 'Hand', r: 0.13, at: [0.88, -0.38, 0], mat: 'gloss:#ff8a3d', mirror: 'x' });
f.capsule({ name: 'Leg', r: 0.13, h: 0.25, at: [0.25, -0.95, 0], mat: 'soft:#ffe9c9', mirror: 'x' });
f.box({ name: 'Foot', size: [0.34, 0.14, 0.48], at: [0.25, -1.22, 0.08], bevel: 0.06, mat: 'gloss:#3a3f4b', mirror: 'x' });
f.box({ name: 'Chest panel', size: [0.42, 0.3, 0.04], at: [0, -0.15, 0.6], bevel: 0.03, mat: 'glass' });
f.sphere({ name: 'Button', r: 0.05, at: [0, -0.15, 0.63], mat: 'glow:#7dff8a' });
