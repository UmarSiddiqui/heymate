// Still life: glass bottle, ceramic cup, gold ball, wooden board.
const f = figure(100, 60, 620, 520, { spin: 0, tilt: 16 });
f.box({ name: 'Board', size: [2.6, 0.1, 1.5], at: [0, -0.85, 0], bevel: 0.04, mat: 'wood' });
f.lathe({ name: 'Bottle', at: [-0.7, -0.8, 0], profile: [[0, 0], [0.32, 0], [0.34, 0.08], [0.34, 0.9], [0.14, 1.3], [0.11, 1.7], [0.13, 1.74], [0, 1.74]], mat: 'glass' });
f.cyl({ name: 'Cork', r: 0.1, h: 0.16, at: [-0.7, 0.98, 0], mat: 'wood' });
f.lathe({ name: 'Cup', at: [0.2, -0.8, 0.25], profile: [[0, 0], [0.24, 0], [0.3, 0.42], [0.27, 0.42], [0.22, 0.05], [0, 0.05]], mat: 'ceramic' });
f.torus({ name: 'Handle', r: 0.13, tube: 0.03, axis: 'z', at: [0.5, -0.58, 0.25], mat: 'ceramic' });
f.sphere({ name: 'Gold ball', r: 0.26, at: [0.85, -0.54, -0.2], mat: 'gold' });
f.sphere({ name: 'Chrome ball', r: 0.17, at: [0.05, -0.63, -0.4], mat: 'chrome' });
f.box({ name: 'Red block', size: [0.34, 0.34, 0.34], at: [-0.15, -0.63, 0.5], bevel: 0.04, rot: [0, 25, 0], mat: 'plastic:#e5484d' });
