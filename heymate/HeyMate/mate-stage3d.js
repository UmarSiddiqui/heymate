// HeyMate's 3D stage. The app draws it with Metal; a browser fixture draws it with WebGL.
// Three.js holds the scene math. Part shapes come from mate-three-parts.js.
// The drawing VM emits scene3d, part3d, label3d, motion3d, camera3d and tick3d.
// This file owns when those arrive, how the camera frames them, labels, and clicks.
(function () {
  'use strict';
  const stages = new Map();
  const seen = new Set();
  let handle = null, root = null, observer = null, frameRequest = 0, last = performance.now();
  let environment = null;

  const readJson = text => { try { return JSON.parse(text || '{}'); } catch { return {}; } };
  const degrees = value => (+value || 0) * Math.PI / 180;
  // A part's beat is the delay of the CSS animation it was given when it was added.
  const beatDelay = element => {
    const match = /([\d.]+)s\s+both/.exec((element.style && element.style.animation) || '');
    return match ? parseFloat(match[1]) : 0;
  };
  const easeOut = t => 1 - Math.pow(1 - Math.min(1, Math.max(0, t)), 3);

  // What a part's `mat` name looks like. Metals take the colour of their measured reflectance (sRGB, toned down a
  // little so a bright metal still reads on a light screen) and are fully metallic; everything else is a plain
  // colour with no metal. Roughness: how blurred the highlight is, from polished (0) to chalk (1).
  const metal = (color, roughness) => ({ color, metalness: 1, roughness });
  const plain = (color, roughness, extra = {}) => ({ color, metalness: 0, roughness, ...extra });
  const MATERIALS = {
    steel: metal(0xc2c5ca, 0.34),
    aluminium: metal(0xdfe1e4, 0.4),
    titanium: metal(0xb9b4ac, 0.42),
    chrome: metal(0xd2d4d6, 0.06),
    brass: metal(0xd4b064, 0.3),
    copper: metal(0xd28c66, 0.32),
    gold: metal(0xeec56a, 0.24),
    iron: { color: 0x6b6e72, metalness: 0.8, roughness: 0.62 },
    metal: metal(0xb3b7bd, 0.36),
    black: plain(0x1e1f23, 0.48),
    rubber: plain(0x2c2c2e, 0.92),
    glass: plain(0xd6ebff, 0.04, { opacity: 0.32 }),
    water: plain(0x4f9de6, 0.08, { opacity: 0.52 }),
    wood: plain(0x9a6943, 0.72),
    ceramic: plain(0xf4f0e7, 0.3),
    paper: plain(0xfaf5ea, 0.95),               // HeyMate's paper tone
    gloss: plain(0xdedede, 0.22),
    paint: { color: 0xdedede, metalness: 0.2, roughness: 0.34 },
    plastic: plain(0xdedede, 0.46),
    soft: plain(0xdedede, 0.76),
    matte: plain(0xdedede, 0.92),
    glow: plain(0xffb534, 0.5, { glow: 1 }),
  };
  MATERIALS.alu = MATERIALS.aluminum = MATERIALS.aluminium;

  function materialFor(spec) {
    spec = spec || {};
    const preset = MATERIALS[spec.mat] || MATERIALS.gloss;
    const tint = spec.color || spec.tint;
    const material = new THREE.MeshStandardMaterial({
      color: tint ? new THREE.Color(tint) : new THREE.Color(preset.color),
      metalness: spec.metalness != null ? spec.metalness : preset.metalness,
      roughness: spec.roughness != null ? spec.roughness : preset.roughness,
      side: spec.double || (globalThis.__heymateNativeMetal && spec.cut) ? THREE.DoubleSide : THREE.FrontSide,
      flatShading: !!spec.flat,
    });
    const opacity = spec.opacity != null ? spec.opacity : preset.opacity;
    if (opacity != null && opacity < 1) {
      material.transparent = true;
      material.opacity = opacity;
      material.depthWrite = false;
    }
    const glow = spec.glow != null ? +spec.glow : preset.glow || 0;
    if (glow > 0 || spec.emissive) {
      material.emissive = new THREE.Color(spec.emissive || tint || preset.color);
      material.emissiveIntensity = spec.emissiveIntensity != null ? spec.emissiveIntensity : Math.max(glow, 0.6);
    }
    return material;
  }

  // The browser's copy of HeyMate's 3D shading (scripts/native-shaders/davinci.metal, which the app runs natively):
  // the shading between the "shared" markers is that file's, written in GLSL (scripts/stage3d_tests.mjs checks they
  // match); only the inputs around it are WebGL's. Used for illustrated stages when the app's Metal renderer is not
  // drawing them (browser pages and fixtures).
  const SHADER_VERTEX = `
    varying vec3 mateWorldPosition;
    varying vec3 mateNormal;
    varying vec2 mateUV;
    uniform mat3 mateNormalMatrix;
    void main() {
      vec4 world = modelMatrix * vec4(position, 1.0);
      mateWorldPosition = world.xyz;
      mateNormal = normalize(mateNormalMatrix * normal);
      mateUV = uv;
      gl_Position = projectionMatrix * viewMatrix * world;
    }
  `;
  const SHADER_FRAGMENT = `
    varying vec3 mateWorldPosition;
    varying vec3 mateNormal;
    varying vec2 mateUV;
    uniform vec3 eye;
    uniform vec4 style;
    uniform vec3 baseColor;
    uniform vec3 emissive;
    uniform vec4 surface;
    uniform vec4 flags;
    uniform vec3 bands[16];
// ---- shared with mate-stage3d.js ----
// Colours are linear until the end. Two looks: illustrated, the way Mate draws with markers (the colour flat where
// the light falls, a cooler darker tone where it does not, a small hard highlight), and studio (soft physically
// based light: a sky above, a dark floor below, a key light and a cool rim light from behind).

float to_srgb_channel(float x) {
    return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
}
vec3 to_srgb(vec3 c) {
    c = max(c, vec3(0.0));
    return vec3(to_srgb_channel(c.x), to_srgb_channel(c.y), to_srgb_channel(c.z));
}

// The normal to light with: the face's own normal for flat-shaded parts (turned to the eye), the far side's
// normal turned round for double-sided parts seen from behind.
vec3 lit_normal(vec3 normal, vec3 position, vec3 eye, bool flat, bool doubleSided, bool front) {
    if (flat) {
        vec3 n = normalize(cross(dFdx(position), dFdy(position)));
        return dot(n, eye - position) < 0.0 ? -n : n;
    }
    vec3 n = normalize(normal);
    return (doubleSided && !front) ? -n : n;
}

vec3 illustrated_tone(vec3 colour, vec3 n, vec3 v, vec3 light, float roughness, float metalness) {
    float facing = dot(n, light);
    // where the light falls, with a soft edge just past the terminator
    float lit = smoothstep(-0.1, 0.12, facing);
    vec3 shadow = colour * mix(vec3(0.54, 0.57, 0.70), vec3(0.33, 0.35, 0.46), metalness);
    vec3 tone = mix(shadow, colour, lit);
    // the side turned right away from the light a little deeper, so round things read as round
    tone *= mix(0.84, 1.0, smoothstep(-0.8, -0.3, facing));
    // a faint lift along the edges facing away from the eye, on the lit side
    float edge = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 3.0);
    tone = mix(tone, vec3(1.0), 0.10 * edge * lit);
    // one small highlight: smaller and sharper the smoother the part, a little wider on metal
    vec3 h = normalize(light + v);
    float gloss = clamp(1.0 - roughness, 0.0, 1.0);
    float size = 0.012 + 0.03 * roughness + 0.05 * metalness;
    float spot = smoothstep(1.0 - size, 1.0 - size * 0.35, dot(n, h));
    return mix(tone, vec3(1.0), spot * (0.3 + 0.6 * gloss));
}

// GGX microfacets: distribution, height-correlated Smith visibility and Schlick's Fresnel.
float ggx_distribution(float a2, float nh) {
    float d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (3.14159265 * d * d);
}
float smith_visibility(float a2, float nl, float nv) {
    float l = nv * sqrt(nl * nl * (1.0 - a2) + a2);
    float w = nl * sqrt(nv * nv * (1.0 - a2) + a2);
    return 0.5 / max(l + w, 1e-5);
}
vec3 schlick_fresnel(vec3 f0, float vh) {
    float k = pow(1.0 - vh, 5.0);
    return f0 + (vec3(1.0) - f0) * k;
}
vec3 studio_light(vec3 n, vec3 v, vec3 l, vec3 radiance, vec3 diffuse, vec3 f0, float a2) {
    float nl = clamp(dot(n, l), 0.0, 1.0);
    if (nl <= 0.0) return vec3(0.0);
    vec3 h = normalize(l + v);
    float nv = max(dot(n, v), 1e-4), nh = clamp(dot(n, h), 0.0, 1.0), vh = clamp(dot(v, h), 0.0, 1.0);
    vec3 specular = schlick_fresnel(f0, vh) * (ggx_distribution(a2, nh) * smith_visibility(a2, nl, nv));
    return radiance * nl * (diffuse / 3.14159265 + specular);
}
vec3 studio_tone(vec3 colour, vec3 n, vec3 geometryNormal, vec3 v, vec3 key, float roughness, float metalness) {
    vec3 diffuse = colour * (1.0 - metalness);
    vec3 f0 = mix(vec3(0.04), colour, metalness);
    // rougher where the surface curves fast across a pixel, so highlights don't sparkle on small curved parts
    vec3 bend = fwidth(geometryNormal);
    float r = clamp(roughness + max(bend.x, max(bend.y, bend.z)), 0.06, 1.0);
    float a2 = r * r * r * r;
    vec3 sky = vec3(1.15), ground = vec3(0.048, 0.064, 0.096);
    vec3 c = mix(ground, sky, 0.5 + 0.5 * n.y) * diffuse / 3.14159265;
    c += studio_light(n, v, normalize(key), vec3(2.1), diffuse, f0, a2);
    c += studio_light(n, v, normalize(vec3(-4.0, 2.0, -4.0)), vec3(0.33, 0.48, 0.86), diffuse, f0, a2);
    return c;
}

// A part's colour on screen (sRGB) and its opacity.
vec4 shade_surface(vec3 position, vec3 normal, bool front, vec3 eye, vec4 style,
                     vec3 colour, vec3 emissive, vec4 surface, vec4 flags) {
    vec3 n = lit_normal(normal, position, eye, flags.y > 0.5, flags.z > 0.5, front);
    vec3 v = normalize(eye - position);
    vec3 c = style.x > 0.5
        ? illustrated_tone(colour, n, v, normalize(style.yzw), surface.x, surface.y)
        : studio_tone(colour, n, normalize(normal), v, style.yzw, surface.x, surface.y);
    return vec4(to_srgb(c + emissive), surface.z);
}
// ---- end shared ----
    vec3 band_colour(vec2 uv) {
      int count = int(surface.w);
      if (count <= 0) return vec3(1.0);
      return bands[clamp(int(floor((1.0 - uv.y) * float(count))), 0, count - 1)];
    }
    void main() {
      gl_FragColor = shade_surface(mateWorldPosition, mateNormal, gl_FrontFacing, eye, style,
                                   baseColor * band_colour(mateUV), emissive, surface, flags);
    }
  `;


  const KEY_LIGHT = [3, 5, 4];
  const eyeAt = new THREE.Vector3();

  function illustratedMaterial(spec, standard) {
    const bands = (Array.isArray(spec.bands) ? spec.bands : Array.isArray(spec.colors) ? spec.colors : []).slice(0, 16);
    const uniforms = {
      mateNormalMatrix: { value: new THREE.Matrix3() },
      eye: { value: new THREE.Vector3() },
      style: { value: new THREE.Vector4(1, ...KEY_LIGHT) },
      baseColor: { value: new THREE.Color() },
      emissive: { value: new THREE.Color() },
      surface: { value: new THREE.Vector4(standard.roughness, standard.metalness, standard.opacity, bands.length) },
      flags: { value: new THREE.Vector4(0, spec.flat ? 1 : 0, spec.double ? 1 : 0, 0) },
      bands: { value: Array.from({ length: 16 }, (_, index) => new THREE.Color(bands[index] || '#FFFFFF')) },
    };
    const material = new THREE.ShaderMaterial({
      vertexShader: SHADER_VERTEX, fragmentShader: SHADER_FRAGMENT, uniforms,
      side: standard.side, transparent: standard.transparent, depthWrite: standard.depthWrite,
      opacity: standard.opacity, toneMapped: false, extensions: { derivatives: true },
    });
    Object.assign(material, {
      color: standard.color.clone(), emissive: standard.emissive.clone(), emissiveIntensity: standard.emissiveIntensity,
      roughness: standard.roughness, metalness: standard.metalness,
    });
    material.userData.mateShader = true;
    standard.dispose();
    return material;
  }

  function syncShader(mesh, camera) {
    const material = mesh.material;
    if (!material?.userData.mateShader) return;
    const uniforms = material.uniforms;
    uniforms.mateNormalMatrix.value.getNormalMatrix(mesh.matrixWorld);
    camera.getWorldPosition(eyeAt);
    uniforms.eye.value.copy(eyeAt);
    uniforms.baseColor.value.copy(material.color);
    uniforms.emissive.value.copy(material.emissive).multiplyScalar(material.emissiveIntensity);
    uniforms.surface.value.set(material.roughness, material.metalness, material.opacity, uniforms.surface.value.w);
  }

  function geometryFor(kind, recipe) {
    const built = globalThis.mateThreeBuild(kind, recipe);
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.BufferAttribute(built.positions, 3));
    if (built.normals) geometry.setAttribute('normal', new THREE.BufferAttribute(built.normals, 3));
    if (built.uvs) geometry.setAttribute('uv', new THREE.BufferAttribute(built.uvs, 2));
    if (built.colors) geometry.setAttribute('color', new THREE.BufferAttribute(built.colors, 3));
    if (built.indices) geometry.setIndex(new THREE.BufferAttribute(built.indices, 1));
    if (!built.normals) geometry.computeVertexNormals();
    geometry.computeBoundingBox();
    return geometry;
  }

  // Studio metals need a room to reflect. Illustrated shading does not sample it, so marker
  // stages skip the map. Built once and shared.
  function studioEnvironment(renderer) {
    if (environment) return environment;
    const room = new THREE.Scene();
    room.add(new THREE.Mesh(new THREE.BoxGeometry(10, 10, 10), new THREE.MeshBasicMaterial({ color: 0x9a9ea6, side: THREE.BackSide })));
    const panel = (x, y, z, size, color) => {
      const mesh = new THREE.Mesh(new THREE.PlaneGeometry(size, size), new THREE.MeshBasicMaterial({ color, side: THREE.DoubleSide }));
      mesh.position.set(x, y, z);
      mesh.lookAt(0, 0, 0);
      room.add(mesh);
    };
    panel(-3, 4, 2, 4, 0xffffff);
    panel(4, 2, -2, 3, 0xf0f4ff);
    panel(0, -4.5, 0, 6, 0x50545c);
    environment = new THREE.PMREMGenerator(renderer).fromScene(room, 0.04).texture;
    return environment;
  }

  function pin(element, style) {
    Object.assign(element.style, style);
  }

  function makeStage(element) {
    const unit = globalThis.__mateUnitPx || 1;
    const x = +element.getAttribute('x') * unit;
    const y = +element.getAttribute('y') * unit;
    const w = +element.getAttribute('width') * unit;
    const h = +element.getAttribute('height') * unit;
    const cameraSpec = readJson(element.getAttribute('data-camera'));
    const canvas = document.createElement('canvas');
    pin(canvas, { position: 'absolute', left: x + 'px', top: y + 'px', width: w + 'px', height: h + 'px', pointerEvents: 'none' });
    const labels = document.createElement('div');
    pin(labels, { position: 'absolute', left: x + 'px', top: y + 'px', width: w + 'px', height: h + 'px', pointerEvents: 'none' });
    const leaders = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    leaders.setAttribute('width', w);
    leaders.setAttribute('height', h);
    pin(leaders, { position: 'absolute', left: '0', top: '0', overflow: 'visible' });
    labels.appendChild(leaders);
    root.appendChild(canvas);
    root.appendChild(labels);
    const nativeMetal = globalThis.__heymateNativeMetal === true;
    const renderer = nativeMetal ? MateMetal.create(canvas) : new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true });
    renderer.setPixelRatio(window.devicePixelRatio || 1);
    renderer.setSize(w, h, false);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    const scene = new THREE.Scene();
    scene.add(new THREE.HemisphereLight(0xffffff, 0x8a8f99, 1.4));
    const key = new THREE.DirectionalLight(0xffffff, 2.2);
    key.position.set(-3, 5, 4);
    key.castShadow = true;
    key.shadow.mapSize.set(1024, 1024);
    key.shadow.radius = 6;
    key.shadow.bias = -0.0005;
    scene.add(key);
    const floor = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), new THREE.ShadowMaterial({ opacity: 0.22 }));
    floor.rotation.x = -Math.PI / 2;
    floor.receiveShadow = true;
    scene.add(floor);
    const rim = new THREE.DirectionalLight(0xffffff, 1.2);
    rim.position.set(3, 2, -4);
    scene.add(rim);
    const look = element.getAttribute('data-look') || 'illustrated';
    if (!nativeMetal && look !== 'illustrated') scene.environment = studioEnvironment(renderer);
    const pivot = new THREE.Group();
    scene.add(pivot);
    const camera = new THREE.PerspectiveCamera(cameraSpec.fov || 35, w / h, 0.01, 1000);
    const stage = {
      id: element.id, element, canvas, labels, leaders, renderer, scene, pivot, camera, w, h,
      tilt: degrees(cameraSpec.tilt != null ? cameraSpec.tilt : 15),
      spin: cameraSpec.spin ?? 0.7, yaw: 0,
      parts: new Map(), partOf: new Set(), pending: [], motions: [], labelList: [], ticks: [],
      born: performance.now(), look, radius: 1, centre: new THREE.Vector3(),
      ink: element.getAttribute('data-ink') || '#30333A', key, floor,
    };
    if (nativeMetal) {
      renderer.stage = stage;
      labels.style.visibility = 'hidden';
    }
    stages.set(element.id, stage);
    return stage;
  }

  const measureBox = new THREE.Box3();
  function frame(stage) {
    const savedScale = new Map();
    stage.parts.forEach(part => {
      savedScale.set(part, part.scale.clone());
      part.scale.setScalar(part.userData.scale || 1);
    });
    stage.scene.updateMatrixWorld(true);
    measureBox.makeEmpty();
    stage.parts.forEach(part => { if (part.isMesh) measureBox.expandByObject(part); });
    savedScale.forEach((scale, part) => part.scale.copy(scale));
    stage.scene.updateMatrixWorld(true);
    if (measureBox.isEmpty()) return;
    const sphere = measureBox.getBoundingSphere(new THREE.Sphere());
    stage.centre.copy(sphere.center);
    stage.radius = Math.max(sphere.radius, 1e-3);
    const radius = stage.radius;
    stage.floor.position.set(stage.centre.x, measureBox.min.y - 0.002, stage.centre.z);
    stage.floor.scale.set(radius * 8, radius * 8, 1);
    stage.key.position.set(stage.centre.x - radius * 1.5, stage.centre.y + radius * 4, stage.centre.z + radius * 2);
    stage.key.target.position.copy(stage.centre);
    stage.key.target.updateMatrixWorld();
    Object.assign(stage.key.shadow.camera, { left: -radius * 2, right: radius * 2, top: radius * 2, bottom: -radius * 2, near: 0.01, far: radius * 12 });
    stage.key.shadow.camera.updateProjectionMatrix();
  }

  function addPart(stage, data, at) {
    let obj;
    if (data.kind === 'group') obj = new THREE.Group();
    else {
      try {
        const standard = materialFor(data.material);
        const illustrated = stage.look === 'illustrated' && !globalThis.__heymateNativeMetal;
        const material = illustrated ? illustratedMaterial(data.material || {}, standard) : standard;
        obj = new THREE.Mesh(geometryFor(data.kind, data.recipe || JSON.stringify(data.params || {})), material);
        if (material.userData.mateShader) obj.onBeforeRender = (_renderer, _scene, camera) => syncShader(obj, camera);
      } catch (error) {
        console.warn('[stage3d] part', data.id, error && error.message);
        obj = new THREE.Group();
      }
    }
    obj.name = data.name || data.id;
    if (obj.isMesh) { obj.castShadow = true; obj.receiveShadow = true; }
    const atPosition = data.at || [0, 0, 0];
    const rotate = data.rotate || [0, 0, 0];
    obj.position.set(atPosition[0], atPosition[1], atPosition[2]);
    obj.rotation.set(degrees(rotate[0]), degrees(rotate[1]), degrees(rotate[2]), 'XYZ');
    obj.userData = { id: data.id, base: obj.position.clone(), baseRot: obj.rotation.clone(), scale: +data.scale || 1, grow: at, material: data.material };
    obj.scale.setScalar(1e-4);
    const parent = data.parent && stage.parts.get(data.parent);
    (parent || stage.pivot).add(obj);
    stage.parts.set(data.id, obj);
    stage.partOf.add(obj);
    frame(stage);
  }

  function addLabel(stage, data) {
    const pill = document.createElement('div');
    pill.textContent = data.text;
    pin(pill, {
      position: 'absolute', whiteSpace: 'nowrap',
      font: `600 ${Math.round((data.size || 19) * 0.8)}px -apple-system, 'Barlow', sans-serif`,
      color: '#15171C', background: 'rgba(255,255,255,0.94)', padding: '3px 10px', borderRadius: '999px',
      boxShadow: '0 1px 6px rgba(0,0,0,0.25)', opacity: '0', transition: 'opacity .4s',
    });
    stage.labels.appendChild(pill);
    const line = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    for (const [key, value] of Object.entries({ fill: 'none', stroke: '#FFFFFF', 'stroke-width': 1.6, 'stroke-linecap': 'round', opacity: 0, style: 'filter: drop-shadow(0 0 1.5px rgba(0,0,0,0.7))' })) {
      line.setAttribute(key, value);
    }
    stage.leaders.appendChild(line);
    const side = data.side || (stage.labelList.length % 2 ? 'left' : 'right');
    stage.labelList.push({ div: pill, data, line, side, order: null, y: null });
  }

  function remember(element) {
    const tag = (element.tagName || '').toLowerCase();
    const key = element.__n != null
      ? 'n' + element.__n
      : tag + ':' + (element.id || element.getAttribute('data-part') || element.getAttribute('data-label') || element.getAttribute('data-op') || element.getAttribute('data-tick'));
    if (seen.has(key) || (tag === 'scene3d' && stages.has(element.id))) return;
    seen.add(key);
    const at = performance.now() + beatDelay(element) * 1000;
    if (tag === 'scene3d') { makeStage(element); return; }
    const stage = stages.get(element.getAttribute('data-stage'));
    if (!stage) return;
    const queue = run => stage.pending.push({ at, run });
    if (tag === 'part3d') queue(() => addPart(stage, readJson(element.getAttribute('data-part')), at));
    else if (tag === 'label3d') queue(() => addLabel(stage, readJson(element.getAttribute('data-label'))));
    else if (tag === 'motion3d') queue(() => stage.motions.push(Object.assign({ start: performance.now() }, readJson(element.getAttribute('data-op')))));
    else if (tag === 'camera3d') queue(() => {
      const op = readJson(element.getAttribute('data-op'));
      if (op.tilt != null) stage.tilt = degrees(op.tilt);
      if (op.spin != null) stage.spin = op.spin;
    });
    else if (tag === 'tick3d') queue(() => stage.ticks.push({ id: element.getAttribute('data-tick'), start: performance.now() }));
  }

  function scan(node) {
    if (!node || node.nodeType !== 1) return;
    if (/^(scene3d|part3d|label3d|motion3d|camera3d|tick3d)$/i.test(node.tagName)) remember(node);
    for (const child of node.children || []) scan(child);
  }

  const motionAxis = new THREE.Vector3();
  const motionPoint = new THREE.Vector3();
  const motionQuat = new THREE.Quaternion();
  const motionEuler = new THREE.Euler();

  function applyMotion(stage, motion, now) {
    const obj = stage.parts.get(motion.target);
    if (!obj) return;
    const seconds = (now - motion.start) / 1000;
    const pose = obj.userData;
    const period = motion.period || 6;
    const axis = motionAxis.set(...(motion.axis || [0, 1, 0])).normalize();
    if (motion.kind === 'spin') {
      motionQuat.setFromEuler(pose.baseRot);
      obj.quaternion.setFromAxisAngle(axis, (seconds / period) * Math.PI * 2).premultiply(motionQuat);
    } else if (motion.kind === 'bob') {
      obj.position.copy(pose.base).addScaledVector(axis, Math.sin(seconds / period * Math.PI * 2) * (motion.amount || 0.1));
    } else if (motion.kind === 'pulse') {
      pose.pulse = 1 + Math.sin(seconds / period * Math.PI * 2) * (motion.amount || 0.08);
    } else if (motion.kind === 'orbit') {
      const centre = motionPoint.set(...(motion.center || [0, 0, 0]));
      obj.position.copy(pose.base).sub(centre).applyAxisAngle(axis, seconds / period * Math.PI * 2).add(centre);
    } else if (motion.kind === 'path' && motion.points && motion.points.length > 1) {
      const points = motion.points.map(point => new THREE.Vector3(...point));
      let along = seconds / period;
      along = motion.once ? Math.min(1, along) : along % 1;
      const span = motion.closed ? points.length : points.length - 1;
      const scaled = along * span;
      const index = Math.min(span - 1, Math.floor(scaled));
      obj.position.copy(points[index]).lerp(points[(index + 1) % points.length], scaled - index);
    } else if (motion.kind === 'tween') {
      const k = easeOut(seconds / (motion.period || 0.35));
      if (motion.to) {
        if (!motion.from) motion.from = obj.position.clone();
        obj.position.copy(motion.from).lerp(motionPoint.set(...motion.to), k);
        if (k >= 1) pose.base.copy(obj.position);
      }
      if (motion.rot) {
        if (!motion.fromRot) motion.fromRot = obj.quaternion.clone();
        motionEuler.set(degrees(motion.rot[0]), degrees(motion.rot[1]), degrees(motion.rot[2]));
        obj.quaternion.copy(motion.fromRot).slerp(motionQuat.setFromEuler(motionEuler), k);
      }
    } else if (motion.kind === 'set' && !motion.done) {
      if (motion.scale != null) pose.scale = motion.scale;
      if (motion.show != null) obj.visible = motion.show;
      if (motion.glow != null && obj.material) {
        obj.material.emissive = obj.material.color.clone();
        obj.material.emissiveIntensity = motion.glow;
      }
      if (motion.color && obj.material) obj.material.color.set(motion.color);
      motion.done = true;
    }
  }

  function paintGlow(material, amount) {
    material.emissive = material.color.clone();
    material.emissiveIntensity = amount;
  }

  // A program's tick functions. The app host returns each part's pose as 14 numbers.
  // A page without that host runs the functions here and reads the poses they write.
  function runTicks(stage, now, dt) {
    if (handle && handle.tick3d) {
      if (!stage.ticks.length) return;
      let poses = null;
      try {
        poses = handle.tick3d(stage.id, stage.ticks.map(tick => [tick.id, (now - tick.start) / 1000]), dt);
      } catch (error) {
        console.warn('[stage3d] tick3d', error && error.message);
      }
      if (!poses) return;
      for (let index = 0; index + 13 < poses.length; index += 14) {
        const obj = stage.parts.get(stage.id + 'p' + poses[index]);
        const mask = poses[index + 1];
        if (!obj) continue;
        if (mask & 1) obj.position.set(poses[index + 2], poses[index + 3], poses[index + 4]);
        if (mask & 2) obj.rotation.set(degrees(poses[index + 5]), degrees(poses[index + 6]), degrees(poses[index + 7]), 'XYZ');
        if (mask & 4) obj.userData.scale = poses[index + 8];
        if (mask & 8) obj.visible = poses[index + 9] !== 0;
        if ((mask & 16) && obj.material) paintGlow(obj.material, poses[index + 10]);
        if ((mask & 32) && obj.material) obj.material.color.setRGB(poses[index + 11], poses[index + 12], poses[index + 13], THREE.SRGBColorSpace);
      }
      return;
    }
    const live = handle && handle.live3d ? handle.live3d() : null;
    if (!live || !live.ticks || !stage.ticks.length) return;
    for (const tick of stage.ticks) {
      const fn = live.ticks[tick.id];
      if (typeof fn !== 'function') continue;
      globalThis.__mateInTick3d = true;
      try { fn((now - tick.start) / 1000, dt); }
      catch (error) { delete live.ticks[tick.id]; console.warn('[stage3d] tick stopped', error && error.message); }
      finally { globalThis.__mateInTick3d = false; }
    }
    for (const id in live.anim || {}) {
      const obj = stage.parts.get(id);
      const pose = live.anim[id];
      if (!obj || !pose) continue;
      if (pose.pos) obj.position.set(pose.pos[0], pose.pos[1], pose.pos[2]);
      if (pose.rot) obj.rotation.set(degrees(pose.rot[0]), degrees(pose.rot[1]), degrees(pose.rot[2]), 'XYZ');
      if (pose.scale != null) obj.userData.scale = pose.scale;
      if (pose.show != null) obj.visible = pose.show !== false;
      if (pose.color && obj.material) obj.material.color.set(pose.color);
      if (pose.glow != null && obj.material) paintGlow(obj.material, pose.glow);
    }
  }

  const visitBox = new THREE.Box3();
  const visitPoint = new THREE.Vector3();
  function visit(stage, obj) {
    if (!handle || !handle.onBuild || !obj.isMesh) return false;
    const shown = obj.scale.x;
    obj.scale.setScalar(obj.userData.scale || 1);
    obj.updateMatrixWorld(true);
    visitBox.setFromObject(obj);
    visitBox.getCenter(visitPoint);
    obj.scale.setScalar(shown);
    obj.updateMatrixWorld(true);
    visitPoint.project(stage.camera);
    if (![visitPoint.x, visitPoint.y, visitPoint.z].every(Number.isFinite)
        || Math.abs(visitPoint.x) > 1 || Math.abs(visitPoint.y) > 1 || Math.abs(visitPoint.z) > 1) return false;
    const rect = stage.canvas.getBoundingClientRect();
    const raw = obj.name && obj.name !== obj.userData.id ? obj.name : '';
    const name = /\s(\d+|mirror)$/.test(raw) ? '' : raw.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/_/g, ' ').toLowerCase();
    try {
      handle.onBuild(rect.left + (visitPoint.x + 1) / 2 * rect.width, rect.top + (1 - visitPoint.y) / 2 * rect.height, name);
      return true;
    } catch { return false; }
  }

  function disposeStage(stage) {
    const geometries = new Set();
    const materials = new Set();
    stage.scene.traverse(obj => {
      if (obj.geometry) geometries.add(obj.geometry);
      const list = Array.isArray(obj.material) ? obj.material : [obj.material];
      for (const material of list) if (material) materials.add(material);
    });
    geometries.forEach(geometry => geometry.dispose());
    materials.forEach(material => material.dispose());
    stage.renderer.dispose();
    stage.canvas.remove();
    stage.labels.remove();
    stage.probe?.remove();
    stages.delete(stage.id);
  }

  function syncRectangle(stage) {
    if (!root.querySelectorAll) return true;
    const element = [...root.querySelectorAll('scene3d')].find(candidate => candidate.id === stage.id);
    if (!element) { disposeStage(stage); return false; }
    stage.element = element;
    // scene3d has no layout box of its own. A hidden rect beside it picks up the card's
    // transform, so the WebGL view and clicks follow a drag or a zoom.
    if (!stage.probe) {
      stage.probe = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      stage.probe.setAttribute('visibility', 'hidden');
      stage.probe.setAttribute('pointer-events', 'none');
    }
    if (stage.probe.parentNode !== element.parentNode) element.parentNode.appendChild(stage.probe);
    for (const key of ['x', 'y', 'width', 'height', 'transform']) {
      const value = element.getAttribute(key);
      if (value == null) stage.probe.removeAttribute(key);
      else stage.probe.setAttribute(key, value);
    }
    const rect = stage.probe.getBoundingClientRect();
    stage.suppressed = !(rect.width > 0 && rect.height > 0);
    stage.renderer.setVisible?.(!stage.suppressed);
    stage.canvas.style.visibility = stage.suppressed ? 'hidden' : 'visible';
    if (stage.suppressed) return false;
    for (const overlay of [stage.canvas, stage.labels]) {
      pin(overlay, { left: rect.left + 'px', top: rect.top + 'px', width: rect.width + 'px', height: rect.height + 'px' });
    }
    if (Math.abs(stage.w - rect.width) > 0.5 || Math.abs(stage.h - rect.height) > 0.5) {
      stage.w = rect.width;
      stage.h = rect.height;
      stage.renderer.setSize(stage.w, stage.h, false);
      stage.camera.aspect = stage.w / stage.h;
      stage.camera.updateProjectionMatrix();
      stage.leaders.setAttribute('width', stage.w);
      stage.leaders.setAttribute('height', stage.h);
    }
    return true;
  }

  function growParts(stage, now) {
    stage.parts.forEach(obj => {
      const pose = obj.userData;
      const grown = easeOut((now - pose.grow) / 650);
      obj.scale.setScalar(Math.max(1e-4, grown * (pose.scale || 1) * (pose.pulse || 1)));
    });
  }

  function placeCamera(stage, now, dt) {
    if (now >= (stage.holdUntil || 0)) stage.yaw += dt * stage.spin * 0.5;
    const vertical = degrees(stage.camera.fov) / 2;
    const horizontal = Math.atan(Math.tan(vertical) * stage.camera.aspect);
    const distance = stage.radius / Math.sin(Math.min(vertical, horizontal)) * 1.08;
    stage.camera.position.set(
      stage.centre.x + Math.sin(stage.yaw) * Math.cos(stage.tilt) * distance,
      stage.centre.y + Math.sin(stage.tilt) * distance,
      stage.centre.z + Math.cos(stage.yaw) * Math.cos(stage.tilt) * distance,
    );
    stage.camera.lookAt(stage.centre);
    stage.scene.updateMatrixWorld(true);
    stage.camera.updateMatrixWorld(true);
  }

  function tick() {
    frameRequest = requestAnimationFrame(tick);
    const now = performance.now();
    const dt = Math.min(0.1, (now - last) / 1000);
    last = now;
    for (const stage of stages.values()) {
      if (!syncRectangle(stage)) continue;
      // Same beat keeps insertion order: a group exists before the parts inside it.
      stage.pending.sort((a, b) => a.at - b.at);
      while (stage.pending.length && stage.pending[0].at <= now) stage.pending.shift().run();
      growParts(stage, now);
      for (const motion of stage.motions) applyMotion(stage, motion, now);
      runTicks(stage, now, dt);
      placeCamera(stage, now, dt);
      stage.parts.forEach(obj => {
        const pose = obj.userData;
        if (!pose.visited && now >= pose.grow && now - (stage.lastVisit || 0) > 380 && visit(stage, obj)) {
          pose.visited = true;
          stage.lastVisit = now;
        }
      });
      placeLabels(stage);
      stage.renderer.render(stage.scene, stage.camera);
    }
  }

  const labelPoint = new THREE.Vector3();
  function placeLabels(stage) {
    const placed = { left: [], right: [] };
    for (const label of stage.labelList) {
      const target = label.data.follow ? stage.parts.get(label.data.follow) : null;
      if ((label.data.follow && !target) || (target && !target.visible)) {
        label.div.style.opacity = '0';
        label.line.setAttribute('opacity', '0');
        continue;
      }
      const point = labelPoint.set(...(label.data.point || [0, 0, 0]));
      if (target?.geometry?.boundingBox) target.localToWorld(target.geometry.boundingBox.getCenter(point));
      else if (target) target.getWorldPosition(point);
      point.project(stage.camera);
      placed[label.side].push({ label, ax: (point.x + 1) / 2 * stage.w, ay: (1 - point.y) / 2 * stage.h });
    }
    const gap = 32;
    const margin = 0.14 * stage.w;
    for (const side of ['left', 'right']) {
      for (const item of placed[side]) {
        if (item.label.order == null) item.label.order = item.ay + stage.labelList.indexOf(item.label) * 1e-3;
      }
      const list = placed[side].sort((a, b) => a.label.order - b.label.order);
      let y = -Infinity;
      for (const item of list) { item.y = Math.max(item.ay, y + gap); y = item.y; }
      const overflow = y - (stage.h - 16);
      if (overflow > 0) for (const item of list) item.y -= overflow;
      for (const item of list) {
        item.label.y = item.label.y == null ? item.y : item.label.y + (item.y - item.label.y) * 0.12;
        item.y = item.label.y;
        const x = side === 'left' ? margin : stage.w - margin;
        pin(item.label.div, {
          left: x + 'px', top: item.y + 'px', opacity: '1',
          transform: side === 'left' ? 'translate(-100%, -50%)' : 'translate(0, -50%)',
        });
        item.label.anchorX = item.ax;
        item.label.anchorY = item.ay;
        const leaderX = side === 'left' ? x + 4 : x - 4;
        item.label.line.setAttribute('d', `M${leaderX},${item.y} L${item.ax},${item.ay}`);
        item.label.line.setAttribute('opacity', '0.55');
      }
    }
  }

  function stageAt(x, y) {
    for (const stage of stages.values()) {
      if (stage.suppressed) continue;
      const rect = stage.canvas.getBoundingClientRect();
      if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) return stage;
    }
    return null;
  }

  function turn(stage, dx, dy) {
    stage.yaw -= dx * 0.01;
    stage.tilt = Math.max(-1.3, Math.min(1.3, stage.tilt + dy * 0.008));
    stage.holdUntil = performance.now() + 2500;
  }

  const pickRay = new THREE.Raycaster();
  const pickNdc = new THREE.Vector2();
  const pickView = new THREE.Vector3();
  function hitKept(stage, hit) {
    for (let parent = hit.object; parent; parent = parent.parent) if (!parent.visible) return false;
    if (!globalThis.__heymateNativeMetal) return true;
    const spec = hit.object.userData.material || {};
    if (spec.cutFacing) {
      pickView.copy(stage.camera.position).sub(stage.centre).normalize();
      return hit.point.dot(pickView) <= stage.centre.dot(pickView);
    }
    return !Array.isArray(spec.cut) || hit.point.x * spec.cut[0] + hit.point.y * spec.cut[1] + hit.point.z * spec.cut[2] <= spec.cut[3];
  }

  function pick(stage, x, y) {
    const rect = stage.canvas.getBoundingClientRect();
    pickNdc.set((x - rect.left) / rect.width * 2 - 1, -((y - rect.top) / rect.height) * 2 + 1);
    pickRay.setFromCamera(pickNdc, stage.camera);
    const hit = pickRay.intersectObjects(stage.pivot.children, true).find(candidate => hitKept(stage, candidate));
    if (!hit) return null;
    let obj = hit.object;
    while (obj && !stage.partOf.has(obj)) obj = obj.parent;
    return obj ? String(obj.name || '').replace(/ (mirror|\d+)$/, '') : null;
  }

  globalThis.MateStage3D = {
    stageAt, turn, pick,
    get rects() {
      return [...stages.values()].filter(stage => !stage.suppressed).map(stage => {
        const rect = stage.canvas.getBoundingClientRect();
        return [rect.left, rect.top, rect.width, rect.height];
      });
    },
    attach(stageElement, liveHandle) {
      handle = liveHandle;
      root = stageElement;
      if (observer) observer.disconnect();
      observer = new MutationObserver(list => { for (const record of list) for (const node of record.addedNodes) scan(node); });
      observer.observe(stageElement, { childList: true, subtree: true });
      scan(stageElement);
      if (!frameRequest) frameRequest = requestAnimationFrame(tick);
    },
    get stages() { return stages; },
    reset() {
      for (const stage of stages.values()) disposeStage(stage);
      if (environment) { environment.dispose(); environment = null; }
      stages.clear();
      seen.clear();
    },
  };
})();
