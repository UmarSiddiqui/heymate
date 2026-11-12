// A turbofan front: nacelle, spinner, a ring of titanium blades, airflow arrow.
const f = figure(100, 60, 620, 520, { spin: 0, tilt: 12 });
f.tube({ name: 'Nacelle', r: 1.05, inner: 0.95, h: 1.3, axis: 'x', mat: 'paint:white', cut: true });
f.torus({ name: 'Intake lip', r: 1.0, tube: 0.07, axis: 'x', at: [-0.65, 0, 0], mat: 'chrome' });
const rotor = f.group({ name: 'Rotor', at: [-0.3, 0, 0] });
f.lathe({ parent: rotor, name: 'Spinner', profile: [[0, -0.2], [0.24, -0.2], [0.22, 0.05], [0.12, 0.3], [0, 0.38]], axis: 'x', rot: [0, 0, 180], mat: 'chrome' });
f.box({ parent: rotor, name: 'Blade', size: [0.04, 0.72, 0.22], at: [0, 0.58, 0], rot: [0, 30, 0], bevel: 0.01, mat: 'titanium', around: { count: 18, axis: 'x' } });
f.cyl({ name: 'Core', r: 0.4, h: 1.1, axis: 'x', at: [0.45, 0, 0], mat: 'steel' });
f.cone({ name: 'Exhaust cone', r: 0.3, h: 0.5, axis: 'x', at: [1.25, 0, 0], rot: [0, 0, -90], mat: 'titanium' });
f.box({ name: 'Stator', size: [0.03, 0.55, 0.14], at: [0.3, 0.68, 0], mat: 'alu', around: { count: 10, axis: 'x' } });
f.arrow({ name: 'Airflow', points: [[-1.9, 0.55, 0.9], [-0.6, 0.55, 0.9], [1.3, 0.55, 0.9]], r: 0.03, mat: 'glow:orange' });
