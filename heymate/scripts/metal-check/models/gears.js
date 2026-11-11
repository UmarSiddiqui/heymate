// A gear train on a base plate.
const f = figure(100, 60, 620, 520, { spin: 0, tilt: 18 });
f.box({ name: 'Plate', size: [3.0, 2.0, 0.12], at: [0, 0, -0.25], bevel: 0.04, mat: 'alu' });
f.gear({ name: 'Drive gear', r: 0.55, teeth: 14, w: 0.22, hole: 0.1, at: [-0.85, 0.1, 0], mat: 'brass' });
f.gear({ name: 'Idler', r: 0.4, teeth: 10, w: 0.22, hole: 0.08, at: [0.02, 0.45, 0], rot: [0, 0, 18], mat: 'steel' });
f.gear({ name: 'Output gear', r: 0.7, teeth: 18, w: 0.22, hole: 0.12, at: [0.98, -0.1, 0], mat: 'copper' });
f.cyl({ name: 'Axle', r: 0.1, h: 0.7, axis: 'z', at: [-0.85, 0.1, 0.05], mat: 'chrome' });
f.cyl({ name: 'Axle 2', r: 0.08, h: 0.7, axis: 'z', at: [0.02, 0.45, 0.05], mat: 'chrome' });
f.cyl({ name: 'Axle 3', r: 0.12, h: 0.7, axis: 'z', at: [0.98, -0.1, 0.05], mat: 'chrome' });
f.cyl({ name: 'Bolt', r: 0.07, h: 0.06, axis: 'z', at: [1.3, 0.8, -0.17], mat: 'black', mirror: 'x' });
f.cyl({ name: 'Bolt low', r: 0.07, h: 0.06, axis: 'z', at: [1.3, -0.8, -0.17], mat: 'black', mirror: 'x' });
