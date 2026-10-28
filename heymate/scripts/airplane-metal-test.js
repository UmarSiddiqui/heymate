// Exercises the installed native Metal stage through the local /explain endpoint.
step(1);
say("First, the fuselage and transparent cockpit arrive.");
const flight = figure(160, 130, 1190, 690, { spin: 0.16, tilt: 22 });
const airframe = flight.group({ name: 'airframe', rot: [0, 35, 0] });
const body = flight.lathe({
  parent: airframe, name: 'fuselage', axis: 'z', mat: 'paint:white', roughness: 0.36,
  profile: [[0,-3.2],[0.10,-3.05],[0.25,-2.65],[0.42,-1.9],[0.46,-1.0],
            [0.46,1.8],[0.42,2.35],[0.30,2.8],[0.12,3.1],[0,3.23]]
});
flight.lathe({
  parent: airframe, name: 'blue belly', axis: 'z', at: [0,-0.11,0], mat: 'paint:#3380ff',
  profile: [[0,-2.85],[0.12,-2.7],[0.32,-1.9],[0.36,1.75],[0.24,2.55],[0,2.95]]
});
const cockpit = flight.sphere({
  parent: airframe, name: 'cockpit glass', r: 0.43, at: [0,0.30,2.13],
  scale: [0.9,0.48,1.45], mat: 'glass', color: '#72A4D2', opacity: 0.78, roughness: 0.12
});
step(2);
say("Next, mirrored swept wings and the tail assemble.");
const wing = flight.extrude({
  parent: airframe, name: 'swept wing', depth: 0.10, rot: [90,0,0], at: [0,-0.05,0],
  shape: [[0.32,0.95],[3.4,-0.75],[3.45,-1.25],[0.32,-0.6]],
  mirror: 'x', mat: 'paint:white', roughness: 0.4
});
flight.box({
  parent: airframe, name: 'blue winglet', size: [0.08,0.42,0.48],
  at: [3.42,0.16,-1.0], rot: [0,0,-16], mirror: 'x', mat: 'paint:#3380ff'
});
flight.extrude({
  parent: airframe, name: 'horizontal stabilizer', depth: 0.08, rot: [90,0,0], at: [0,0.12,-2.1],
  shape: [[0.18,0.32],[1.45,-0.48],[1.5,-0.82],[0.18,-0.4]], mirror: 'x', mat: 'paint:white'
});
flight.extrude({
  parent: airframe, name: 'tail fin', axis: 'x', depth: 0.12,
  shape: [[1.72,0.24],[2.82,0.24],[2.85,1.55],[2.35,1.42]], mat: 'paint:#3380ff'
});
step(3);
say("Two turbofans arrive with spinning fan rotors.");
let engineLabel;
for (const side of [-1,1]) {
  const engine = flight.tube({
    parent: airframe, name: side < 0 ? 'port turbofan' : 'starboard turbofan',
    axis: 'z', r: 0.32, inner: 0.25, h: 1.45, at: [side*1.14,-0.62,0.24],
    mat: 'alu', roughness: 0.25
  });
  engineLabel = engine;
  flight.torus({
    parent: airframe, name: 'intake lip', axis: 'z', r: 0.285, tube: 0.045,
    at: [side*1.14,-0.62,0.97], mat: 'chrome'
  });
  flight.box({
    parent: airframe, name: 'engine pylon', size: [0.12,0.45,0.6],
    at: [side*1.14,-0.25,0.0], mat: 'paint:white'
  });
  const fan = flight.group({ parent: airframe, name: 'fan rotor', at: [side*1.14,-0.62,0.92] });
  flight.cyl({ parent: fan, name: 'fan hub', r: 0.075, h: 0.12, axis: 'z', mat: 'steel' });
  flight.box({
    parent: fan, name: 'fan blade', size: [0.20,0.04,0.045], at: [0.14,0,0],
    rot: [0,0,18], around: { count: 9, axis: 'z' }, mat: 'steel'
  });
  fan.spin({ axis: 'z', period: 1.5 });
}
step(4);
say("Passenger windows and labels finish the airplane.");
for (let z = -1.6; z <= 1.7; z += 0.42) {
  flight.sphere({
    parent: airframe, name: 'passenger window', r: 0.055, scale: [0.28,1,0.78],
    at: [0.448,0.16,z], mirror: 'x', mat: 'paint:#153652', roughness: 0.25
  });
}
airframe.bob({ axis: 'y', amount: 0.06, period: 5 });
flight.label(cockpit, 'Glass cockpit', { side: 'left', size: 18 });
flight.label(wing, 'Mirrored swept wings', { side: 'right', size: 18 });
flight.label(engineLabel, 'Spinning turbofans', { side: 'right', size: 18 });
