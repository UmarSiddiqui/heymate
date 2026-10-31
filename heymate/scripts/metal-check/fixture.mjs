import fs from 'node:fs';
import vm from 'node:vm';
const root = new URL('../../HeyMate/', import.meta.url);
let payload;
const context = vm.createContext({ console, window: { webkit: { messageHandlers: { heymate: { postMessage: m => { payload = m.body; } } } } } });
for (const name of ['three-r159.min.js', 'mate-three.js', 'mate-three-parts.js', 'mate-metal-bridge.js']) {
  vm.runInContext(fs.readFileSync(new URL(name, root), 'utf8'), context);
}
vm.runInContext(`
const pivot = new THREE.Group(), scene = new THREE.Scene(); scene.add(pivot);
const camera = new THREE.PerspectiveCamera(35, 1.5, 0.01, 1000);
camera.position.set(0, 1.4, 10); camera.lookAt(0, 0, 0);
function part(kind, recipe, x, y, spec) {
  const built = mateThreeBuild(kind, JSON.stringify(recipe));
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(built.positions, 3));
  if (built.normals) g.setAttribute('normal', new THREE.BufferAttribute(built.normals, 3)); else g.computeVertexNormals();
  if (built.uvs) g.setAttribute('uv', new THREE.BufferAttribute(built.uvs, 2));
  if (built.indices) g.setIndex(new THREE.BufferAttribute(built.indices, 1));
  const m = new THREE.MeshStandardMaterial({ color: spec.color, roughness: spec.roughness ?? 0.3, metalness: spec.metalness || 0, opacity: spec.opacity ?? 1 });
  const mesh = new THREE.Mesh(g, m); mesh.position.set(x,y,0); mesh.userData.material = spec; pivot.add(mesh);
}
part('sphere', {r:0.75}, -2, 0.9, {color:'#3380ff'});
part('sphere', {r:0.75}, 0, 0.9, {color:'#f4bd53',metalness:0.95,roughness:0.16});
part('sphere', {r:0.75}, 2, 0.9, {color:'#ffffff',bands:['#f48787','#e9d4a0','#7fcabd','#819ce8']});
part('torus', {r:0.6,tube:0.23,axis:'z'}, -2,-1, {color:'#df87ad',flat:true});
part('sphere', {r:0.75}, 0,-1, {color:'#86cddd',opacity:0.38,double:true});
part('sphere', {r:0.75}, 2,-1, {color:'#b4bfcd',metalness:0.7,cut:[1,0,0,2]});
const canvas = {getBoundingClientRect:()=>({left:0,top:0,width:768,height:512})};
const renderer = MateMetal.create(canvas);
renderer.stage = {pivot,centre:new THREE.Vector3(),look:'illustrated',ink:'#2b2e34',labelList:[]};
renderer.render(scene,camera);
`, context);
fs.writeFileSync(process.argv[2], JSON.stringify(payload));
