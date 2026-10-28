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


  // Direct port of the shipped DaVinci Metal fragment functions, retained in
  // scripts/native-shaders/davinci.metal (SHA-256 in its provenance.json).
  // The function bodies below change only MSL/GLSL syntax and resource ABI.
  // Swift renderer/outline passes and native material presets are not recovered here.
  const DAVINCI_VERTEX = `
    varying vec3 nativeWorldPosition;
    varying vec3 nativeNormal;
    varying vec2 nativeUV;
    uniform mat3 nativeNormalMatrix;
    void main() {
      vec4 world = modelMatrix * vec4(position, 1.0);
      nativeWorldPosition = world.xyz;
      nativeNormal = normalize(nativeNormalMatrix * normal);
      nativeUV = uv;
      gl_Position = projectionMatrix * viewMatrix * world;
    }
  `;
  const DAVINCI_FRAGMENT = `
    #define saturate(value) clamp(value, 0.0, 1.0)
    struct VertexOut { vec3 worldPosition; vec3 normal; vec2 uv; vec4 color; };
    struct FrameUniforms { vec4 eye; vec4 style; };
    struct ObjectUniforms { vec4 baseColor; vec4 emissive; vec4 surface; vec4 flags; vec4 bands[16]; };
    varying vec3 nativeWorldPosition;
    varying vec3 nativeNormal;
    varying vec2 nativeUV;
    uniform FrameUniforms frame;
    uniform ObjectUniforms object;
const float RECIPROCAL_PI = 0.3183098861837907;
float D_GGX(float alpha, float dotNH) {
    float a2 = alpha * alpha;
    float denominator = dotNH * dotNH * (a2 - 1.0) + 1.0;
    return RECIPROCAL_PI * a2 / (denominator * denominator);
}
float V_GGX_SmithCorrelated(float alpha, float dotNL, float dotNV) {
    float a2 = alpha * alpha;
    float gv = dotNL * sqrt(a2 + (1.0 - a2) * dotNV * dotNV);
    float gl = dotNV * sqrt(a2 + (1.0 - a2) * dotNL * dotNL);
    return 0.5 / max(gv + gl, 1e-6);
}
vec3 F_Schlick(vec3 f0, float f90, float dotVH) {
    float fresnel = exp2((-5.55473 * dotVH - 6.98316) * dotVH);
    return f0 * (1.0 - fresnel) + f90 * fresnel;
}
vec3 BRDF_GGX(vec3 lightDirection, vec3 viewDirection, vec3 normal, vec3 specularColor, float roughness) {
    float alpha = roughness * roughness;
    vec3 halfDirection = normalize(lightDirection + viewDirection);
    float dotNL = saturate(dot(normal, lightDirection));
    float dotNV = saturate(dot(normal, viewDirection));
    float dotNH = saturate(dot(normal, halfDirection));
    float dotVH = saturate(dot(viewDirection, halfDirection));
    return F_Schlick(specularColor, 1.0, dotVH) * (V_GGX_SmithCorrelated(alpha, dotNL, dotNV) * D_GGX(alpha, dotNH));
}
vec3 sRGBFromLinear(vec3 value) {
    return mix(pow(max(value, 0.0), vec3(0.41666)) * 1.055 - 0.055, value * 12.92, vec3(lessThanEqual(value, vec3(0.0031308))));
}
vec4 davinci_fragment(VertexOut vertexData, bool isFrontFacing, FrameUniforms frame, ObjectUniforms object) {
    vec3 normal = normalize(vertexData.normal);
    if (object.flags.y > 0.5) {
        normal = normalize(cross(dFdx(vertexData.worldPosition), dFdy(vertexData.worldPosition)));
        if (dot(normal, frame.eye.xyz - vertexData.worldPosition) < 0.0) normal = -normal;
    } else if (object.flags.z > 0.5 && !isFrontFacing) {
        normal = -normal;
    }
    vec4 base = object.baseColor;
    if (object.flags.x > 0.5) base.rgb *= vertexData.color.rgb;
    int bandCount = int(object.surface.w);
    if (bandCount > 0) {
        int band = clamp(int(floor((1.0 - vertexData.uv.y) * float(bandCount))), 0, bandCount - 1);
        base.rgb *= object.bands[band].rgb;
    }
    float metalness = object.surface.y;
    vec3 diffuseColor = base.rgb * (1.0 - metalness);
    vec3 specularColor = mix(vec3(0.04), base.rgb, metalness);
    vec3 geometryNormal = normalize(vertexData.normal);
    vec3 variation = max(abs(dFdx(geometryNormal)), abs(dFdy(geometryNormal)));
    float roughness = min(max(object.surface.x, 0.0525) + max(max(variation.x, variation.y), variation.z), 1.0);

    vec3 viewDirection = normalize(frame.eye.xyz - vertexData.worldPosition);
    if (frame.style.x > 0.5) {
        // Mate's illustrated look, like its marker drawings: the colour flat where the light
        // falls, one cool darker tone where it does not (a soft edge between), a small white
        // highlight on glossy parts, metal with a deeper shade and a brighter shine.
        vec3 light = normalize(frame.style.yzw);
        float facing = dot(normal, light);
        float lit = smoothstep(-0.08, 0.14, facing);
        vec3 colour = base.rgb;
        vec3 shade = colour * mix(vec3(0.50, 0.53, 0.66), vec3(0.30, 0.32, 0.42), metalness);
        vec3 tone = mix(shade, colour, lit);
        // Turned right away from the light: a touch deeper still, so round things stay round.
        tone *= mix(0.86, 1.0, smoothstep(-0.75, -0.35, facing));
        vec3 halfway = normalize(light + viewDirection);
        float shininess = saturate(1.0 - object.surface.x);
        float highlight = smoothstep(0.985 - 0.06 * metalness - 0.03 * (1.0 - shininess), 0.995 - 0.06 * metalness, dot(normal, halfway));
        tone = mix(tone, vec3(1.0), highlight * (0.35 + 0.55 * shininess));
        tone += object.emissive.rgb;
        return vec4(sRGBFromLinear(tone), base.a * object.surface.z);
    }
    // Hemisphere light: sky white, ground #3a4658, intensity 1.2 (indirect diffuse).
    vec3 sky = vec3(1.0) * 1.2;
    vec3 ground = vec3(0.04231, 0.06124, 0.09758) * 1.2;
    vec3 irradiance = mix(ground, sky, 0.5 * normal.y + 0.5);
    vec3 outgoing = irradiance * diffuseColor * RECIPROCAL_PI;
    // Key light: white × 2.2 from (3, 5, 4). Rim light: #9fc4ff × 0.9 from (-4, 2, -4).
    vec3 directions[2]; directions[0] = normalize(vec3(3.0, 5.0, 4.0)); directions[1] = normalize(vec3(-4.0, 2.0, -4.0));
    vec3 colors[2]; colors[0] = vec3(2.2); colors[1] = vec3(0.34670, 0.55201, 1.0) * 0.9;
    for (int index = 0; index < 2; index++) {
        float dotNL = saturate(dot(normal, directions[index]));
        vec3 lightIrradiance = dotNL * colors[index];
        outgoing += lightIrradiance * diffuseColor * RECIPROCAL_PI;
        outgoing += lightIrradiance * BRDF_GGX(directions[index], viewDirection, normal, specularColor, roughness);
    }
    outgoing += object.emissive.rgb;
    return vec4(sRGBFromLinear(outgoing), base.a * object.surface.z);
}
    void main() {
      VertexOut vertexData;
      vertexData.worldPosition = nativeWorldPosition;
      vertexData.normal = nativeNormal;
      vertexData.uv = nativeUV;
      vertexData.color = vec4(1.0);
      gl_FragColor = davinci_fragment(vertexData, gl_FrontFacing, frame, object);
    }
  `;

  function illustratedMaterial(spec, standard) {
    const bands = (Array.isArray(spec.bands) ? spec.bands : Array.isArray(spec.colors) ? spec.colors : []).slice(0, 16);
    const uniforms = {
      nativeNormalMatrix: { value: new THREE.Matrix3() },
      frame: { value: {
        eye: new THREE.Vector4(),
        // Native style uniform is host-owned. This adapter uses the exact
        // physical shader key direction; native illustrated host defaults are unproved.
        style: new THREE.Vector4(1, 3, 5, 4),
      } },
      object: { value: {
        baseColor: new THREE.Vector4(), emissive: new THREE.Vector4(),
        surface: new THREE.Vector4(standard.roughness, standard.metalness, standard.opacity, bands.length),
        flags: new THREE.Vector4(0, spec.flat ? 1 : 0, spec.double ? 1 : 0, 0),
        bands: Array.from({ length: 16 }, (_, i) => {
          const color = new THREE.Color(bands[i] || '#FFFFFF');
          return new THREE.Vector4(color.r, color.g, color.b, 1);
        }),
      } },
    };
    const material = new THREE.ShaderMaterial({
      vertexShader: DAVINCI_VERTEX, fragmentShader: DAVINCI_FRAGMENT, uniforms,
      side: standard.side, transparent: standard.transparent, depthWrite: standard.depthWrite,
      opacity: standard.opacity, toneMapped: false, extensions: { derivatives: true },
    });
    // Keep the existing part/tick color and glow ABI. Every draw synchronizes
    // those values; animations do not write stale copies of uniforms.
    material.color = standard.color.clone(); material.emissive = standard.emissive.clone();
    material.emissiveIntensity = standard.emissiveIntensity;
    material.roughness = standard.roughness; material.metalness = standard.metalness;
    material.userData.nativeDaVinci = true;
    standard.dispose();
    return material;
  }

  function updateNativeMaterial(mesh, camera) {
    const material = mesh.material;
    if (!material?.userData.nativeDaVinci) return;
    const uniforms = material.uniforms, color = material.color, emissive = material.emissive;
    uniforms.nativeNormalMatrix.value.getNormalMatrix(mesh.matrixWorld);
    const eye = new THREE.Vector3(); camera.getWorldPosition(eye);
    uniforms.frame.value.eye.set(eye.x, eye.y, eye.z, 1);
    uniforms.object.value.baseColor.set(color.r, color.g, color.b, 1);
    const strength = material.emissiveIntensity;
    uniforms.object.value.emissive.set(emissive.r * strength, emissive.g * strength, emissive.b * strength, 0);
    uniforms.object.value.surface.set(material.roughness, material.metalness, material.opacity, uniforms.object.value.surface.w);
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
        if (material.userData.nativeDaVinci) obj.onBeforeRender = (_renderer, _scene, camera) => updateNativeMaterial(obj, camera);
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
