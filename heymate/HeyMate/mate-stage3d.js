// HeyMate's stage for 3D drawings. In the app, MateMetal renders recovered geometry through
// native Metal; Three.js supplies scene math only. Standalone browser fixtures retain WebGL.
// The parts come from ReferenceRenderer's recovered kernel (mate-three.js + mate-three-parts.js).
// The drawing VM emits scene3d/part3d/label3d/motion3d/camera3d/tick3d elements;
// this adapter owns beat timing, camera framing, labels and interaction for both renderers.
(function () {
  'use strict';
  const stages = new Map();
  let handle = null, root = null, observer = null, frameRequest = 0;

  const json = s => { try { return JSON.parse(s || '{}'); } catch (e) { return {}; } };
  const rad = d => (+d || 0) * Math.PI / 180;
  // When an element's beat starts: the delay of its CSS animation, from the moment it was added.
  const delayOf = e => {
    const m = /([\d.]+)s\s+both/.exec((e.style && e.style.animation) || '');
    return m ? parseFloat(m[1]) : 0;
  };

  const MATERIALS = {
    steel: { color: 0xb8bcc4, metalness: 0.9, roughness: 0.32 },
    alu: { color: 0xd4d7dc, metalness: 0.85, roughness: 0.38 },
    aluminum: { color: 0xd4d7dc, metalness: 0.85, roughness: 0.38 },
    aluminium: { color: 0xd4d7dc, metalness: 0.85, roughness: 0.38 },
    titanium: { color: 0x9a9c9f, metalness: 0.85, roughness: 0.4 },
    chrome: { color: 0xeeeeee, metalness: 1, roughness: 0.08 },
    brass: { color: 0xc9a14a, metalness: 0.9, roughness: 0.3 },
    copper: { color: 0xc77a4a, metalness: 0.9, roughness: 0.3 },
    gold: { color: 0xe6c25a, metalness: 1, roughness: 0.22 },
    iron: { color: 0x5c5f63, metalness: 0.7, roughness: 0.6 },
    metal: { color: 0xa8acb2, metalness: 0.85, roughness: 0.35 },
    black: { color: 0x222326, metalness: 0.2, roughness: 0.5 },
    rubber: { color: 0x2a2a2c, metalness: 0, roughness: 0.9 },
    glass: { color: 0xcfe8ff, metalness: 0, roughness: 0.05, opacity: 0.35 },
    water: { color: 0x5aa8f5, metalness: 0, roughness: 0.1, opacity: 0.55 },
    wood: { color: 0xa0673d, metalness: 0, roughness: 0.75 },
    ceramic: { color: 0xf3efe6, metalness: 0, roughness: 0.35 },
    paper: { color: 0xfaf5ea, metalness: 0, roughness: 0.95 },
    gloss: { color: 0xdddddd, metalness: 0.1, roughness: 0.25 },
    paint: { color: 0xdddddd, metalness: 0.3, roughness: 0.35 },
    plastic: { color: 0xdddddd, metalness: 0, roughness: 0.45 },
    soft: { color: 0xdddddd, metalness: 0, roughness: 0.8 },
    matte: { color: 0xdddddd, metalness: 0, roughness: 0.9 },
    glow: { color: 0xffb930, metalness: 0, roughness: 0.5, glow: 1 },
  };

  function materialFor(spec) {
    spec = spec || {};
    const base = MATERIALS[spec.mat] || MATERIALS.gloss;
    const colour = spec.color || spec.tint;
    const m = new THREE.MeshStandardMaterial({
      color: colour ? new THREE.Color(colour) : new THREE.Color(base.color),
      metalness: spec.metalness != null ? spec.metalness : base.metalness,
      roughness: spec.roughness != null ? spec.roughness : base.roughness,
      side: spec.double || (globalThis.__heymateNativeMetal && spec.cut) ? THREE.DoubleSide : THREE.FrontSide,
      flatShading: !!spec.flat,
    });
    const opacity = spec.opacity != null ? spec.opacity : base.opacity;
    if (opacity != null && opacity < 1) { m.transparent = true; m.opacity = opacity; m.depthWrite = false; }
    const glow = spec.glow != null ? +spec.glow : base.glow || 0;
    if (glow > 0 || spec.emissive) {
      m.emissive = new THREE.Color(spec.emissive || colour || base.color);
      m.emissiveIntensity = spec.emissiveIntensity != null ? spec.emissiveIntensity : Math.max(glow, 0.6);
    }
    return m;
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
  // The key light comes from up, right and forward: the same direction the app's renderer gives its shader.
  const KEY_LIGHT = [3, 5, 4];

  // An illustrated part's material: the standard material's settings (colour, glow, roughness, metal, opacity,
  // sides) drawn with HeyMate's shading. Ticks and edits keep changing color, emissive and the rest as on any material;
  // each draw hands the current values to the shader.
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
      bands: { value: Array.from({ length: 16 }, (_, i) => new THREE.Color(bands[i] || '#FFFFFF')) },
    };
    const material = new THREE.ShaderMaterial({
      vertexShader: SHADER_VERTEX, fragmentShader: SHADER_FRAGMENT, uniforms,
      side: standard.side, transparent: standard.transparent, depthWrite: standard.depthWrite,
      opacity: standard.opacity, toneMapped: false, extensions: { derivatives: true },
    });
    Object.assign(material, { color: standard.color.clone(), emissive: standard.emissive.clone(), emissiveIntensity: standard.emissiveIntensity,
      roughness: standard.roughness, metalness: standard.metalness });
    material.userData.mateShader = true;
    standard.dispose();
    return material;
  }
  const eyeAt = new THREE.Vector3();
  function syncShader(mesh, camera) {
    const material = mesh.material;
    if (!material?.userData.mateShader) return;
    const u = material.uniforms, strength = material.emissiveIntensity;
    u.mateNormalMatrix.value.getNormalMatrix(mesh.matrixWorld);
    camera.getWorldPosition(eyeAt); u.eye.value.copy(eyeAt);
    u.baseColor.value.copy(material.color);
    u.emissive.value.copy(material.emissive).multiplyScalar(strength);
    u.surface.value.set(material.roughness, material.metalness, material.opacity, u.surface.value.w);
  }

  function geometryFor(kind, recipe) {
    const built = globalThis.mateThreeBuild(kind, recipe);
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(built.positions, 3));
    if (built.normals) g.setAttribute('normal', new THREE.BufferAttribute(built.normals, 3));
    if (built.uvs) g.setAttribute('uv', new THREE.BufferAttribute(built.uvs, 2));
    if (built.colors) g.setAttribute('color', new THREE.BufferAttribute(built.colors, 3));
    if (built.indices) g.setIndex(new THREE.BufferAttribute(built.indices, 1));
    if (!built.normals) g.computeVertexNormals();
    g.computeBoundingBox();
    return g;
  }

  // Metals need something to reflect: a soft studio room (light walls, two bright panels), made once.
  let environment = null;
  function studioEnvironment(renderer) {
    if (environment) return environment;
    const room = new THREE.Scene();
    room.add(new THREE.Mesh(new THREE.BoxGeometry(10, 10, 10), new THREE.MeshBasicMaterial({ color: 0x9a9ea6, side: THREE.BackSide })));
    const panel = (x, y, z, s, c) => { const m = new THREE.Mesh(new THREE.PlaneGeometry(s, s), new THREE.MeshBasicMaterial({ color: c, side: THREE.DoubleSide })); m.position.set(x, y, z); m.lookAt(0, 0, 0); room.add(m); };
    panel(-3, 4, 2, 4, 0xffffff); panel(4, 2, -2, 3, 0xf0f4ff); panel(0, -4.5, 0, 6, 0x50545c);
    environment = new THREE.PMREMGenerator(renderer).fromScene(room, 0.04).texture;
    return environment;
  }

  function makeStage(e) {
    // The stage's rectangle is in canvas units (the screenshot's pixels); the page is in points.
    const u = globalThis.__mateUnitPx || 1;
    const x = +e.getAttribute('x') * u, y = +e.getAttribute('y') * u, w = +e.getAttribute('width') * u, h = +e.getAttribute('height') * u;
    const camera3 = json(e.getAttribute('data-camera'));
    const canvas = document.createElement('canvas');
    Object.assign(canvas.style, { position: 'absolute', left: x + 'px', top: y + 'px', width: w + 'px', height: h + 'px', pointerEvents: 'none' });
    const labels = document.createElement('div');
    Object.assign(labels.style, { position: 'absolute', left: x + 'px', top: y + 'px', width: w + 'px', height: h + 'px', pointerEvents: 'none' });
    const leaders = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    leaders.setAttribute('width', w); leaders.setAttribute('height', h);
    Object.assign(leaders.style, { position: 'absolute', left: '0', top: '0', overflow: 'visible' });
    labels.appendChild(leaders);
    root.appendChild(canvas); root.appendChild(labels);
    const nativeMetal = globalThis.__heymateNativeMetal === true;
    const renderer = nativeMetal ? MateMetal.create(canvas) : new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true });
    renderer.setPixelRatio(window.devicePixelRatio || 1);
    renderer.setSize(w, h, false);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    const scene = new THREE.Scene();
    // A studio: soft sky light, a key from above left, a rim from behind.
    scene.add(new THREE.HemisphereLight(0xffffff, 0x8a8f99, 1.4));
    const key = new THREE.DirectionalLight(0xffffff, 2.2); key.position.set(-3, 5, 4); scene.add(key);
    key.castShadow = true; key.shadow.mapSize.set(1024, 1024); key.shadow.radius = 6; key.shadow.bias = -0.0005;
    // The figure stands on the screen: only its soft shadow is drawn, on an invisible floor under it.
    const floor = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), new THREE.ShadowMaterial({ opacity: 0.22 }));
    floor.rotation.x = -Math.PI / 2; floor.receiveShadow = true; scene.add(floor);
    const rim = new THREE.DirectionalLight(0xffffff, 1.2); rim.position.set(3, 2, -4); scene.add(rim);
    if (!nativeMetal) scene.environment = studioEnvironment(renderer);
    const pivot = new THREE.Group(); scene.add(pivot);
    const camera = new THREE.PerspectiveCamera(camera3.fov || 35, w / h, 0.01, 1000);
    const st = { id: e.id, element: e, canvas, labels, leaders, renderer, scene, pivot, camera, w, h, tilt: rad(camera3.tilt != null ? camera3.tilt : 15),
      spin: camera3.spin ?? 0.7, yaw: 0, parts: new Map(), pending: [], motions: [], labelList: [], ticks: [], born: performance.now(),
      look: e.getAttribute('data-look') || 'illustrated', radius: 1, centre: new THREE.Vector3(), ink: e.getAttribute('data-ink') || '#30333A', key, floor };
    if (nativeMetal) { renderer.stage = st; labels.style.visibility = 'hidden'; }
    stages.set(e.id, st);
    return st;
  }

  // Frame the camera on everything built so far (kept steady once parts stop arriving).
  function frame(st) {
    const box = new THREE.Box3();
    // A child inherits its group's growing scale. Measure the complete
    // hierarchy at its final size, then restore the animation poses.
    const scales = new Map();
    st.parts.forEach(p => { scales.set(p, p.scale.clone()); p.scale.setScalar(p.userData.scale || 1); });
    st.scene.updateMatrixWorld(true);
    st.parts.forEach(p => {
      if (!p.isMesh) return;
      box.expandByObject(p);
    });
    scales.forEach((scale, p) => p.scale.copy(scale));
    st.scene.updateMatrixWorld(true);
    if (box.isEmpty()) return;
    const sphere = box.getBoundingSphere(new THREE.Sphere());
    st.centre.copy(sphere.center); st.radius = Math.max(sphere.radius, 1e-3);
    const r = st.radius;
    st.floor.position.set(st.centre.x, box.min.y - 0.002, st.centre.z); st.floor.scale.set(r * 8, r * 8, 1);
    st.key.position.set(st.centre.x - r * 1.5, st.centre.y + r * 4, st.centre.z + r * 2); st.key.target.position.copy(st.centre); st.key.target.updateMatrixWorld();
    Object.assign(st.key.shadow.camera, { left: -r * 2, right: r * 2, top: r * 2, bottom: -r * 2, near: 0.01, far: r * 12 });
    st.key.shadow.camera.updateProjectionMatrix();
  }

  function addPart(st, data, at) {
    let obj;
    if (data.kind === 'group') obj = new THREE.Group();
    else {
      try {
        const standard = materialFor(data.material);
        const material = st.look === 'illustrated' && !globalThis.__heymateNativeMetal ? illustratedMaterial(data.material || {}, standard) : standard;
        obj = new THREE.Mesh(geometryFor(data.kind, data.recipe || JSON.stringify(data.params || {})), material);
        if (material.userData.mateShader) obj.onBeforeRender = (_renderer, _scene, camera) => syncShader(obj, camera);
      }
      catch (err) { console.warn('[stage3d] part', data.id, err && err.message); obj = new THREE.Group(); }
    }
    obj.name = data.name || data.id;
    if (obj.isMesh) { obj.castShadow = true; obj.receiveShadow = true; }
    const p = data.at || [0, 0, 0], r = data.rotate || [0, 0, 0];
    obj.position.set(p[0], p[1], p[2]);
    obj.rotation.set(rad(r[0]), rad(r[1]), rad(r[2]), 'XYZ');
    obj.userData = { id: data.id, base: obj.position.clone(), baseRot: obj.rotation.clone(), scale: +data.scale || 1, grow: at, material: data.material };
    obj.scale.setScalar(1e-4);
    const parent = data.parent && st.parts.get(data.parent);
    (parent || st.pivot).add(obj);
    st.parts.set(data.id, obj);
    frame(st);
  }

  function addLabel(st, data, fill) {
    const div = document.createElement('div');
    div.textContent = data.text;
    // A name pill: reads on any screen, light or dark, the way ReferenceRenderer names things it points at.
    Object.assign(div.style, { position: 'absolute', whiteSpace: 'nowrap', font: `600 ${Math.round((data.size || 19) * 0.8)}px -apple-system, 'Barlow', sans-serif`,
      color: '#15171C', background: 'rgba(255,255,255,0.94)', padding: '3px 10px', borderRadius: '999px',
      boxShadow: '0 1px 6px rgba(0,0,0,0.25)', opacity: '0', transition: 'opacity .4s' });
    st.labels.appendChild(div);
    const line = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    Object.entries({ fill: 'none', stroke: '#FFFFFF', 'stroke-width': 1.6, 'stroke-linecap': 'round', opacity: 0, style: 'filter: drop-shadow(0 0 1.5px rgba(0,0,0,0.7))' }).forEach(([k, v]) => line.setAttribute(k, v));
    st.leaders.appendChild(line);
    const side = data.side || (st.labelList.length % 2 ? 'left' : 'right');
    st.labelList.push({ div, data, line, side, order: null, y: null });
  }

  // The canvas re-sends an element it already sent when it changes (the same render number): it is the same stage,
  // part, label or motion, so it is taken once.
  const seen = new Set();
  function onElement(e) {
    const tag = (e.tagName || '').toLowerCase();
    const key = e.__n != null ? 'n' + e.__n : tag + ':' + (e.id || e.getAttribute('data-part') || e.getAttribute('data-label') || e.getAttribute('data-op') || e.getAttribute('data-tick'));
    if (seen.has(key) || (tag === 'scene3d' && stages.has(e.id))) return;
    seen.add(key);
    const at = performance.now() + delayOf(e) * 1000;
    if (tag === 'scene3d') { makeStage(e); return; }
    const st = stages.get(e.getAttribute('data-stage'));
    if (!st) return;
    if (tag === 'part3d') st.pending.push({ at, run: () => addPart(st, json(e.getAttribute('data-part')), at) });
    else if (tag === 'label3d') st.pending.push({ at, run: () => addLabel(st, json(e.getAttribute('data-label')), e.getAttribute('fill')) });
    else if (tag === 'motion3d') st.pending.push({ at, run: () => st.motions.push(Object.assign({ start: performance.now() }, json(e.getAttribute('data-op')))) });
    else if (tag === 'camera3d') st.pending.push({ at, run: () => { const op = json(e.getAttribute('data-op')); if (op.tilt != null) st.tilt = rad(op.tilt); if (op.spin != null) st.spin = op.spin; } });
    else if (tag === 'tick3d') st.pending.push({ at, run: () => st.ticks.push({ id: e.getAttribute('data-tick'), start: performance.now() }) });
  }

  function scan(node) {
    if (!node || node.nodeType !== 1) return;
    if (/^(scene3d|part3d|label3d|motion3d|camera3d|tick3d)$/i.test(node.tagName)) onElement(node);
    for (const c of node.children || []) scan(c);
  }

  const easeOut = t => 1 - Math.pow(1 - Math.min(1, Math.max(0, t)), 3);

  function applyMotion(st, m, now) {
    const obj = st.parts.get(m.target); if (!obj) return;
    const t = (now - m.start) / 1000, u = obj.userData, period = m.period || 6;
    const axis = new THREE.Vector3(...(m.axis || [0, 1, 0])).normalize();
    if (m.kind === 'spin') obj.quaternion.setFromAxisAngle(axis, (t / period) * Math.PI * 2).premultiply(new THREE.Quaternion().setFromEuler(u.baseRot));
    else if (m.kind === 'bob') obj.position.copy(u.base).addScaledVector(axis, Math.sin(t / period * Math.PI * 2) * (m.amount || 0.1));
    else if (m.kind === 'pulse') u.pulse = 1 + Math.sin(t / period * Math.PI * 2) * (m.amount || 0.08);
    else if (m.kind === 'orbit') {
      const c = new THREE.Vector3(...(m.center || [0, 0, 0]));
      obj.position.copy(u.base).sub(c).applyAxisAngle(axis, t / period * Math.PI * 2).add(c);
    } else if (m.kind === 'path' && m.points && m.points.length > 1) {
      const pts = m.points.map(p => new THREE.Vector3(...p));
      let f = t / period; f = m.once ? Math.min(1, f) : f % 1;
      const n = m.closed ? pts.length : pts.length - 1, s = f * n, i = Math.min(n - 1, Math.floor(s));
      obj.position.copy(pts[i]).lerp(pts[(i + 1) % pts.length], s - i);
    } else if (m.kind === 'tween') {
      const k = easeOut(t / (m.period || 0.35));
      if (m.to) { if (!m.from) m.from = obj.position.clone(); obj.position.copy(m.from).lerp(new THREE.Vector3(...m.to), k); if (k >= 1) u.base.copy(obj.position); }
      if (m.rot) { if (!m.fromRot) m.fromRot = obj.quaternion.clone(); obj.quaternion.copy(m.fromRot).slerp(new THREE.Quaternion().setFromEuler(new THREE.Euler(rad(m.rot[0]), rad(m.rot[1]), rad(m.rot[2]))), k); }
    } else if (m.kind === 'set' && !m.done) {
      if (m.scale != null) u.scale = m.scale;
      if (m.show != null) obj.visible = m.show;
      if (m.glow != null && obj.material) { obj.material.emissive = obj.material.color.clone(); obj.material.emissiveIntensity = m.glow; }
      if (m.color && obj.material) obj.material.color.set(m.color);
      m.done = true;
    }
  }

  // The program's tick((t, dt) => ...) functions, run the way ReferenceRenderer's mateCanvas.tick3d runs them.
  function runTicks(st, now, dt) {
    // ReferenceRenderer's canvas: mateCanvas.tick3d runs the ticks and hands back each part's pose, 14 numbers a part.
    if (handle && handle.tick3d) {
      if (!st.ticks.length) return;
      let poses = null;
      try { poses = handle.tick3d(st.id, st.ticks.map(tk => [tk.id, (now - tk.start) / 1000]), dt); } catch (err) { console.warn('[stage3d] tick3d', err && err.message); }
      if (!poses) return;
      for (let i = 0; i + 13 < poses.length; i += 14) {
        const obj = st.parts.get(st.id + 'p' + poses[i]), mask = poses[i + 1]; if (!obj) continue;
        if (mask & 1) obj.position.set(poses[i + 2], poses[i + 3], poses[i + 4]);
        if (mask & 2) obj.rotation.set(rad(poses[i + 5]), rad(poses[i + 6]), rad(poses[i + 7]), 'XYZ');
        if (mask & 4) obj.userData.scale = poses[i + 8];
        if (mask & 8) obj.visible = poses[i + 9] !== 0;
        if ((mask & 16) && obj.material) { obj.material.emissive = obj.material.color.clone(); obj.material.emissiveIntensity = poses[i + 10]; }
        if ((mask & 32) && obj.material) obj.material.color.setRGB(poses[i + 11], poses[i + 12], poses[i + 13], THREE.SRGBColorSpace);
      }
      return;
    }
    const live = handle && handle.live3d ? handle.live3d() : null;
    if (!live || !live.ticks || !st.ticks.length) return;
    for (const tk of st.ticks) {
      const fn = live.ticks[tk.id]; if (typeof fn !== 'function') continue;
      globalThis.__mateInTick3d = true;
      try { fn((now - tk.start) / 1000, dt); } catch (err) { delete live.ticks[tk.id]; console.warn('[stage3d] tick stopped', err && err.message); }
      finally { globalThis.__mateInTick3d = false; }
    }
    for (const id in live.anim || {}) {
      const obj = st.parts.get(id), a = live.anim[id]; if (!obj || !a) continue;
      if (a.pos) obj.position.set(a.pos[0], a.pos[1], a.pos[2]);
      if (a.rot) obj.rotation.set(rad(a.rot[0]), rad(a.rot[1]), rad(a.rot[2]), 'XYZ');
      if (a.scale != null) obj.userData.scale = a.scale;
      if (a.show != null) obj.visible = a.show !== false;
      if (a.color && obj.material) obj.material.color.set(a.color);
      if (a.glow != null && obj.material) { obj.material.emissive = obj.material.color.clone(); obj.material.emissiveIntensity = a.glow; }
    }
  }

  // ReferenceRenderer's cursor builds the model: as each part starts growing, the cursor flies to where it lands and names it.
  const visitBox = new THREE.Box3(), visitPoint = new THREE.Vector3();
  function visit(st, obj) {
    if (!handle || !handle.onBuild || !obj.isMesh) return false;
    const shown = obj.scale.x;
    obj.scale.setScalar(obj.userData.scale || 1); obj.updateMatrixWorld(true);
    visitBox.setFromObject(obj); visitBox.getCenter(visitPoint);
    obj.scale.setScalar(shown); obj.updateMatrixWorld(true);
    visitPoint.project(st.camera);
    if (![visitPoint.x, visitPoint.y, visitPoint.z].every(Number.isFinite)
        || Math.abs(visitPoint.x) > 1 || Math.abs(visitPoint.y) > 1 || Math.abs(visitPoint.z) > 1) return false;
    const r = st.canvas.getBoundingClientRect();
    // Named after its variable (lowerWing → "lower wing"); a copy ("rings 3") or an unnamed part flies without a caption.
    const raw = obj.name && obj.name !== obj.userData.id ? obj.name : '';
    const name = /\s(\d+|mirror)$/.test(raw) ? '' : raw.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/_/g, ' ').toLowerCase();
    try {
      handle.onBuild(r.left + (visitPoint.x + 1) / 2 * r.width, r.top + (1 - visitPoint.y) / 2 * r.height, name);
      return true;
    } catch (_) { return false; }
  }

  let last = performance.now();
  function disposeStage(st) {
    const geometries = new Set(), materials = new Set();
    st.scene.traverse(obj => {
      if (obj.geometry) geometries.add(obj.geometry);
      for (const material of (Array.isArray(obj.material) ? obj.material : [obj.material])) if (material) materials.add(material);
    });
    geometries.forEach(g => g.dispose()); materials.forEach(m => m.dispose());
    st.renderer.dispose(); st.canvas.remove(); st.labels.remove(); st.probe?.remove();
    stages.delete(st.id);
  }
  function syncRectangle(st) {
    if (!root.querySelectorAll) return true; // Non-DOM math harness.
    const element = [...root.querySelectorAll('scene3d')].find(e => e.id === st.id);
    if (!element) { disposeStage(st); return false; }
    st.element = element;
    // scene3d is an unknown SVG element: it has no layout box. Measure a
    // hidden rect beside it so SVG ancestor transforms, card drags and zoom
    // affect WebGL and picking exactly as they affect the drawn card.
    if (!st.probe) {
      st.probe = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      st.probe.setAttribute('visibility', 'hidden'); st.probe.setAttribute('pointer-events', 'none');
    }
    if (st.probe.parentNode !== element.parentNode) element.parentNode.appendChild(st.probe);
    for (const key of ['x', 'y', 'width', 'height', 'transform']) {
      const value = element.getAttribute(key);
      if (value == null) st.probe.removeAttribute(key); else st.probe.setAttribute(key, value);
    }
    const r = st.probe.getBoundingClientRect();
    st.suppressed = !(r.width > 0 && r.height > 0);
    st.renderer.setVisible?.(!st.suppressed);
    st.canvas.style.visibility = st.suppressed ? 'hidden' : 'visible';
    if (st.suppressed) return false;
    for (const overlay of [st.canvas, st.labels]) Object.assign(overlay.style, {
      left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px'
    });
    if (Math.abs(st.w - r.width) > 0.5 || Math.abs(st.h - r.height) > 0.5) {
      st.w = r.width; st.h = r.height;
      st.renderer.setSize(st.w, st.h, false);
      st.camera.aspect = st.w / st.h; st.camera.updateProjectionMatrix();
      st.leaders.setAttribute('width', st.w); st.leaders.setAttribute('height', st.h);
    }
    return true;
  }
  function tick() {
    frameRequest = requestAnimationFrame(tick);
    const now = performance.now(), dt = Math.min(0.1, (now - last) / 1000); last = now;
    for (const st of stages.values()) {
      if (!syncRectangle(st)) continue;
      // Preserve insertion order within a beat: groups must exist before
      // their children and labels/motions before their first rendered frame.
      st.pending.sort((a, b) => a.at - b.at);
      while (st.pending.length && st.pending[0].at <= now) st.pending.shift().run();
      st.parts.forEach(obj => {
        const u = obj.userData, grow = easeOut((now - u.grow) / 650);
        obj.scale.setScalar(Math.max(1e-4, grow * (u.scale || 1) * (u.pulse || 1)));
      });
      for (const m of st.motions) applyMotion(st, m, now);
      runTicks(st, now, dt);
      // The figure turns on its own; the camera stands back far enough to keep it framed.
      if (now >= (st.holdUntil || 0)) st.yaw += dt * st.spin * 0.5;
      const vertical = rad(st.camera.fov) / 2;
      const horizontal = Math.atan(Math.tan(vertical) * st.camera.aspect);
      const dist = st.radius / Math.sin(Math.min(vertical, horizontal)) * 1.08;
      st.camera.position.set(st.centre.x + Math.sin(st.yaw) * Math.cos(st.tilt) * dist, st.centre.y + Math.sin(st.tilt) * dist, st.centre.z + Math.cos(st.yaw) * Math.cos(st.tilt) * dist);
      st.camera.lookAt(st.centre);
      // Native renderer does not update scene matrices as a WebGL side effect.
      st.scene.updateMatrixWorld(true); st.camera.updateMatrixWorld(true);
      // Projection needs this frame's camera and parent transforms. Empty
      // groups never consume a visit, and an offscreen part can retry later.
      st.parts.forEach(obj => {
        const u = obj.userData;
        if (!u.visited && now >= u.grow && now - (st.lastVisit || 0) > 380 && visit(st, obj)) {
          u.visited = true; st.lastVisit = now;
        }
      });
      placeLabels(st);
      st.renderer.render(st.scene, st.camera);
    }
  }

  // Labels stand in the margins, left or right (fixed per label, so they don't jump as the figure turns), stacked
  // at least a line apart in the order of what they point at, each tied to its part by a thin leader.
  function placeLabels(st) {
    const placed = { left: [], right: [] };
    for (const l of st.labelList) {
      const target = l.data.follow ? st.parts.get(l.data.follow) : null;
      if ((l.data.follow && !target) || (target && !target.visible)) { l.div.style.opacity = '0'; l.line.setAttribute('opacity', '0'); continue; }
      const v = new THREE.Vector3(...(l.data.point || [0, 0, 0]));
      if (target?.geometry?.boundingBox) target.localToWorld(target.geometry.boundingBox.getCenter(v));
      else if (target) target.getWorldPosition(v);
      v.project(st.camera);
      placed[l.side].push({ l, ax: (v.x + 1) / 2 * st.w, ay: (1 - v.y) / 2 * st.h });
    }
    const gap = 32, margin = 0.14 * st.w;
    for (const side of ['left', 'right']) {
      // Order is settled once, when a label first shows (top to bottom by its part then), so labels never swap
      // places as the figure turns; positions ease toward their targets instead of jumping frame to frame.
      for (const p of placed[side]) if (p.l.order == null) p.l.order = p.ay + st.labelList.indexOf(p.l) * 1e-3;
      const list = placed[side].sort((p, q) => p.l.order - q.l.order);
      let y = -Infinity;
      for (const p of list) { p.y = Math.max(p.ay, y + gap); y = p.y; }
      const overflow = y - (st.h - 16);
      if (overflow > 0) for (const p of list) p.y -= overflow;
      for (const p of list) {
        p.l.y = p.l.y == null ? p.y : p.l.y + (p.y - p.l.y) * 0.12;
        p.y = p.l.y;
        const x = side === 'left' ? margin : st.w - margin;
        Object.assign(p.l.div.style, { left: x + 'px', top: p.y + 'px', opacity: '1', transform: side === 'left' ? 'translate(-100%, -50%)' : 'translate(0, -50%)' });
        p.l.anchorX = p.ax; p.l.anchorY = p.ay;
        const lx = side === 'left' ? x + 4 : x - 4;
        p.l.line.setAttribute('d', `M${lx},${p.y} L${p.ax},${p.ay}`);
        p.l.line.setAttribute('opacity', '0.55');
      }
    }
  }

  // The user's hands on a figure: which stage is under a point, a drag turns it (its own spin waits a moment after),
  // and a click names the part under the pointer.
  function stageAt(x, y) {
    for (const st of stages.values()) {
      if (st.suppressed) continue;
      const r = st.canvas.getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return st;
    }
    return null;
  }
  function turn(st, dx, dy) {
    st.yaw -= dx * 0.01;
    st.tilt = Math.max(-1.3, Math.min(1.3, st.tilt + dy * 0.008));
    st.holdUntil = performance.now() + 2500;
  }
  function pick(st, x, y) {
    const r = st.canvas.getBoundingClientRect();
    const ray = new THREE.Raycaster();
    ray.setFromCamera(new THREE.Vector2((x - r.left) / r.width * 2 - 1, -((y - r.top) / r.height) * 2 + 1), st.camera);
    const hit = ray.intersectObjects(st.pivot.children, true).find(hit => {
      for (let parent = hit.object; parent; parent = parent.parent) if (!parent.visible) return false;
      if (!globalThis.__heymateNativeMetal) return true;
      const spec = hit.object.userData.material || {};
      if (spec.cutFacing) return hit.point.dot(st.camera.position.clone().sub(st.centre).normalize()) <= st.centre.dot(st.camera.position.clone().sub(st.centre).normalize());
      return !Array.isArray(spec.cut) || hit.point.x * spec.cut[0] + hit.point.y * spec.cut[1] + hit.point.z * spec.cut[2] <= spec.cut[3];
    });
    if (!hit) return null;
    let o = hit.object;
    while (o && ![...st.parts.values()].includes(o)) o = o.parent;
    return o ? String(o.name || '').replace(/ (mirror|\d+)$/, '') : null;
  }

  globalThis.MateStage3D = {
    stageAt, turn, pick,
    get rects() { return [...stages.values()].filter(st => !st.suppressed).map(st => { const r = st.canvas.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; }); },
    attach(stageElement, liveHandle) {
      handle = liveHandle; root = stageElement;
      if (observer) observer.disconnect();
      observer = new MutationObserver(list => { for (const r of list) for (const n of r.addedNodes) scan(n); });
      observer.observe(stageElement, { childList: true, subtree: true });
      scan(stageElement);
      if (!frameRequest) frameRequest = requestAnimationFrame(tick);
    },
    get stages() { return stages; },
    // A new drawing: every stage goes.
    reset() {
      for (const st of stages.values()) disposeStage(st);
      if (environment) { environment.dispose(); environment = null; }
      stages.clear(); seen.clear();
    },
  };
})();
