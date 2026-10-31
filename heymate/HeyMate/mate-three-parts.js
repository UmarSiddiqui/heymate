// HeyMate's 3D part builder.
//
// The drawing engine describes each figure() part as a kind plus a JSON recipe. This file turns a recipe into the
// triangle arrays the 3D stage uploads. It loads after mate-three.js (globalThis.MateThreeLib) and exposes:
//
//   mateThreeKinds                     the part kinds it can build
//   mateThreeBuild(kind, recipeJSON)   -> { positions, normals, uvs, indices, samples } (typed arrays), or throws
//
// Guarantees: a part is closed unless its recipe asks for a sheet (an open cylinder, a dome, a surface), every
// triangle faces the way its normals point, and the same recipe always builds the same arrays (parts are cached by
// recipe). Keys every kind accepts: axis ('x', '-z' or [x, y, z]; parts stand along y unless noted), thick (a wall
// that thick), stretch [sx, sy, sz] and mirror [±1, ±1, ±1].
(function () {
  'use strict';
  const L = globalThis.MateThreeLib;
  // A runaway recipe (a spring of a thousand coils) fails instead of stalling the page.
  const VERTEX_LIMIT = 120000;
  const TAU = Math.PI * 2;

  // ---------------------------------------------------------------- reading recipes
  const isNum = v => typeof v === 'number' && Number.isFinite(v);
  const numOr = (v, fallback) => (isNum(v) ? v : fallback);
  const within = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);
  const size = (v, fallback) => Math.max(1e-4, numOr(v, fallback));
  const whole = (v, fallback, lo, hi) => within(Math.round(numOr(v, fallback)), lo, hi);
  const sweepOf = o => within(numOr(o.arc, 360), 1, 360) * Math.PI / 180;
  const numeric = x => (typeof x === 'number' || (typeof x === 'string' && x.trim() !== '')) && Number.isFinite(+x);
  const point3 = v => Array.isArray(v) && v.length >= 3 && isNum(v[0]) && isNum(v[1]) && isNum(v[2]) ? new L.Vector3(v[0], v[1], v[2]) : null;
  const point2 = v => Array.isArray(v) && v.length >= 2 && numeric(v[0]) && numeric(v[1]) ? new L.Vector2(+v[0], +v[1]) : null;
  // Points from a recipe list, with repeats dropped (a curve through the same point twice has no direction there).
  function pathPoints(list, limit) {
    const out = [];
    for (const p of (Array.isArray(list) ? list : []).map(point3)) {
      if (p && (!out.length || out[out.length - 1].distanceToSquared(p) > 1e-12)) out.push(p);
      if (out.length === limit) break;
    }
    return out;
  }

  const UNIT = { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] };
  function direction(axis) {
    if (typeof axis === 'string') {
      // 'x', '+y', '-z' (any case, spaces allowed)
      const name = axis.replace(/\s+/g, '').toLowerCase(), letter = name.slice(-1), sign = name.slice(0, -1);
      if (!UNIT[letter] || !['', '+', '-'].includes(sign)) return null;
      const v = new L.Vector3().fromArray(UNIT[letter]);
      return sign === '-' ? v.negate() : v;
    }
    const v = point3(axis);
    return v && v.lengthSq() > 1e-12 ? v.normalize() : null;
  }
  // Turns a part built along `built` (y unless given) to lie along the recipe's axis.
  function aim(g, axis, built = 'y') {
    const to = direction(axis), from = new L.Vector3().fromArray(UNIT[built]);
    if (to && to.distanceToSquared(from) > 1e-12) g.applyQuaternion(new L.Quaternion().setFromUnitVectors(from, to));
    return g;
  }

  // ---------------------------------------------------------------- building meshes
  // Vertices with normals and uvs, and triangles that turn to face the way their corners' normals point, so no
  // generator here has to get winding right by hand. Triangles with no area are dropped.
  class Mesh {
    constructor() { this.p = []; this.n = []; this.t = []; this.ix = []; }
    vertex(x, y, z, nx, ny, nz, u = 0, v = 0) {
      this.p.push(x, y, z); this.n.push(nx, ny, nz); this.t.push(u, v);
      return this.p.length / 3 - 1;
    }
    tri(a, b, c) {
      const p = this.p, n = this.n;
      const ux = p[b * 3] - p[a * 3], uy = p[b * 3 + 1] - p[a * 3 + 1], uz = p[b * 3 + 2] - p[a * 3 + 2];
      const vx = p[c * 3] - p[a * 3], vy = p[c * 3 + 1] - p[a * 3 + 1], vz = p[c * 3 + 2] - p[a * 3 + 2];
      const fx = uy * vz - uz * vy, fy = uz * vx - ux * vz, fz = ux * vy - uy * vx;
      if (fx * fx + fy * fy + fz * fz < 1e-24) return;
      const facing = fx * (n[a * 3] + n[b * 3] + n[c * 3]) + fy * (n[a * 3 + 1] + n[b * 3 + 1] + n[c * 3 + 1]) + fz * (n[a * 3 + 2] + n[b * 3 + 2] + n[c * 3 + 2]);
      if (facing >= 0) this.ix.push(a, b, c); else this.ix.push(a, c, b);
    }
    quad(a, b, c, d) { this.tri(a, b, c); this.tri(a, c, d); }
    geometry() { return arrays(this.p, this.n, this.t, this.ix); }
  }
  function arrays(positions, normals, uvs, indices) {
    const g = new L.BufferGeometry();
    g.setAttribute('position', new L.Float32BufferAttribute(positions, 3));
    if (normals) g.setAttribute('normal', new L.Float32BufferAttribute(normals, 3));
    if (uvs) g.setAttribute('uv', new L.Float32BufferAttribute(uvs, 2));
    g.setIndex(indices);
    return g;
  }
  function indexed(g) {
    if (!g.index) g.setIndex(Array.from({ length: g.attributes.position.count }, (_, i) => i));
    return g;
  }
  // Several geometries as one indexed geometry (position, normal, uv).
  function join(parts) {
    const p = [], n = [], t = [], ix = [];
    for (const g of parts) {
      if (!g.attributes.normal) g.computeVertexNormals();
      const gp = g.attributes.position, gn = g.attributes.normal, gt = g.attributes.uv, first = p.length / 3;
      for (let i = 0; i < gp.count; i++) {
        p.push(gp.getX(i), gp.getY(i), gp.getZ(i));
        n.push(gn.getX(i), gn.getY(i), gn.getZ(i));
        t.push(gt ? gt.getX(i) : 0, gt ? gt.getY(i) : 0);
      }
      if (g.index) for (const i of g.index.array) ix.push(first + i);
      else for (let i = 0; i < gp.count; i++) ix.push(first + i);
    }
    return arrays(p, n, t, ix);
  }
  // Reverses every triangle: the inside of a wall, or a part a mirror turned inside out.
  function flip(g) {
    const index = indexed(g).index;
    for (let i = 0; i + 2 < index.count; i += 3) {
      const b = index.getX(i + 1);
      index.setX(i + 1, index.getX(i + 2));
      index.setX(i + 2, b);
    }
    index.needsUpdate = true;
    return g;
  }

  // ---------------------------------------------------------------- revolving a profile
  // Spins a profile [[r, y], ...] round the y axis by `sweep`. A bend sharper than `crease` degrees keeps a hard edge (each side
  // its own normal), so a cylinder's rim reads crisp and a vase's belly stays smooth. A partial sweep is closed with
  // flat faces at both cuts unless `open`, like a slice taken out of a cake.
  function revolve(profile, segments, sweep = TAU, open = false, crease = 35) {
    const creaseCos = Math.cos(crease * Math.PI / 180);
    const pts = [];
    for (const [r, y] of profile) {
      const q = [Math.max(0, r), y];
      if (!pts.length || Math.hypot(q[0] - pts[pts.length - 1][0], q[1] - pts[pts.length - 1][1]) > 1e-9) pts.push(q);
    }
    if (pts.length < 2) pts.splice(0, pts.length, [0, 0], [1, 0], [1, 1], [0, 1]);
    // Each segment's outward normal in the (r, y) plane, for a profile running counter-clockwise (up the outside).
    const segNormal = i => {
      const dr = pts[i + 1][0] - pts[i][0], dy = pts[i + 1][1] - pts[i][1], l = Math.hypot(dr, dy);
      return [dy / l, -dr / l];
    };
    const rows = [];
    let travelled = 0;
    const total = pts.reduce((s, p, i) => (i ? s + Math.hypot(p[0] - pts[i - 1][0], p[1] - pts[i - 1][1]) : 0), 0) || 1;
    for (let i = 0; i < pts.length; i++) {
      if (i) travelled += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
      const before = i > 0 ? segNormal(i - 1) : null, after = i < pts.length - 1 ? segNormal(i) : null, v = travelled / total;
      if (before && after && before[0] * after[0] + before[1] * after[1] < creaseCos) {
        rows.push({ r: pts[i][0], y: pts[i][1], n: before, v, joined: true }, { r: pts[i][0], y: pts[i][1], n: after, v, joined: false });
      } else {
        const a = before || after, b = after || before, l = Math.hypot(a[0] + b[0], a[1] + b[1]) || 1;
        rows.push({ r: pts[i][0], y: pts[i][1], n: [(a[0] + b[0]) / l, (a[1] + b[1]) / l], v, joined: true });
      }
    }
    const mesh = new Mesh(), full = sweep >= TAU - 1e-9, columns = segments + 1;
    const ring = [];
    for (const row of rows) {
      const ids = [];
      for (let j = 0; j < columns; j++) {
        const phi = (j % segments === 0 && full) ? 0 : j / segments * sweep, s = Math.sin(phi), c = Math.cos(phi);
        ids.push(mesh.vertex(row.r * s, row.y, row.r * c, row.n[0] * s, row.n[1], row.n[0] * c, j / segments, row.v));
      }
      ring.push(ids);
    }
    for (let i = 1; i < rows.length; i++) {
      if (!rows[i].joined) continue;
      for (let j = 0; j < segments; j++) mesh.quad(ring[i - 1][j], ring[i - 1][j + 1], ring[i][j + 1], ring[i][j]);
    }
    if (!full && !open) capCuts(mesh, pts, sweep);
    return mesh.geometry();
  }
  // The two flat faces a partial sweep leaves: the profile's outline (closed back along the axis) at each cut.
  function capCuts(mesh, pts, sweep) {
    const outline = pts.map(([r, y]) => new L.Vector2(r, y));
    const first = outline[0], last = outline[outline.length - 1];
    if (first.distanceTo(last) < 1e-9) outline.pop();
    if (outline.length < 3) return;
    const triangles = L.ShapeUtils.triangulateShape(outline, []);
    for (const phi of [0, sweep]) {
      const s = Math.sin(phi), c = Math.cos(phi), facing = phi === 0 ? -1 : 1;
      // The cut's normal is the sweep's direction of travel there, pointing away from the solid.
      const nx = c * facing, nz = -s * facing;
      const ids = outline.map(p => mesh.vertex(p.x * s, p.y, p.x * c, nx, 0, nz, p.x, p.y));
      for (const [a, b, d] of triangles) mesh.tri(ids[a], ids[b], ids[d]);
    }
  }
  // A profile with its listed corners rounded: each becomes a circular arc meeting both edges `b` from the corner
  // (less where an edge is too short to give that much).
  function rounded(profile, corners, b, steps = 6) {
    const out = [];
    profile.forEach((c, i) => {
      if (!corners.includes(i) || i === 0 || i === profile.length - 1) { out.push(c); return; }
      const p = profile[i - 1], n = profile[i + 1];
      const lp = Math.hypot(p[0] - c[0], p[1] - c[1]), ln = Math.hypot(n[0] - c[0], n[1] - c[1]);
      if (lp < 1e-9 || ln < 1e-9) { out.push(c); return; }
      const u = [(p[0] - c[0]) / lp, (p[1] - c[1]) / lp], w = [(n[0] - c[0]) / ln, (n[1] - c[1]) / ln];
      const cosAngle = within(u[0] * w[0] + u[1] * w[1], -1, 1), half = Math.acos(cosAngle) / 2;
      if (half > Math.PI / 2 - 1e-3) { out.push(c); return; }      // a straight run has no corner to round
      const back = Math.min(b, lp * 0.5, ln * 0.5), bl = Math.hypot(u[0] + w[0], u[1] + w[1]) || 1;
      const centre = [c[0] + (u[0] + w[0]) / bl * back / Math.cos(half), c[1] + (u[1] + w[1]) / bl * back / Math.cos(half)];
      const start = [c[0] + u[0] * back, c[1] + u[1] * back], end = [c[0] + w[0] * back, c[1] + w[1] * back];
      const a0 = Math.atan2(start[1] - centre[1], start[0] - centre[0]);
      let turn = Math.atan2(end[1] - centre[1], end[0] - centre[0]) - a0;
      if (turn > Math.PI) turn -= TAU; else if (turn < -Math.PI) turn += TAU;
      const radius = Math.hypot(start[0] - centre[0], start[1] - centre[1]);
      for (let k = 0; k <= steps; k++) {
        const a = a0 + turn * k / steps;
        out.push([centre[0] + radius * Math.cos(a), centre[1] + radius * Math.sin(a)]);
      }
    });
    return out;
  }
  const bevelOf = (o, limit) => Math.min(Math.max(0, numOr(o.bevel, 0)), limit);
  const segmentsOf = (o, fallback) => whole(o.seg, fallback, 3, 128);

  // ---------------------------------------------------------------- tubes along curves
  // A round tube of radius r along a curve, `along` rings of `around` sides. Ends: 'round' (half a ball, a hose's or a
  // wire's end), 'flat' (a disc, a cut pipe) or 'none'. A closed curve needs no ends.
  function sweepTube(curve, r, along, around, { closed = false, ends = 'round' } = {}) {
    const frames = curve.computeFrenetFrames(along, closed), mesh = new Mesh();
    const rings = [];
    const ringAt = (centre, N, B, radius, tilt, T, v) => {
      const ids = [];
      for (let j = 0; j <= around; j++) {
        const a = (j % around) / around * TAU, c = Math.cos(a), s = Math.sin(a);
        const dx = N.x * c + B.x * s, dy = N.y * c + B.y * s, dz = N.z * c + B.z * s;
        const nc = Math.cos(tilt), ns = Math.sin(tilt);
        ids.push(mesh.vertex(centre.x + dx * radius, centre.y + dy * radius, centre.z + dz * radius,
          dx * nc + T.x * ns, dy * nc + T.y * ns, dz * nc + T.z * ns, v, j / around));
      }
      return ids;
    };
    // A closed curve's last ring is its first, so the seam shares vertices and can't open.
    for (let i = 0; i < along; i++) rings.push(ringAt(curve.getPointAt(i / along), frames.normals[i], frames.binormals[i], r, 0, frames.tangents[i], i / along));
    rings.push(closed ? rings[0] : ringAt(curve.getPointAt(1), frames.normals[along], frames.binormals[along], r, 0, frames.tangents[along], 1));
    for (let i = 1; i < rings.length; i++) for (let j = 0; j < around; j++) mesh.quad(rings[i - 1][j], rings[i - 1][j + 1], rings[i][j + 1], rings[i][j]);
    if (!closed && ends !== 'none') {
      for (const [i, sign] of [[0, -1], [along, 1]]) {
        const centre = curve.getPointAt(i / along), T = frames.tangents[i].clone().multiplyScalar(sign);
        const N = frames.normals[i], B = frames.binormals[i], base = rings[i];
        if (ends === 'flat') {
          const mid = mesh.vertex(centre.x, centre.y, centre.z, T.x, T.y, T.z);
          const rim = ringAt(centre, N, B, r, Math.PI / 2, T, i / along);
          for (let j = 0; j < around; j++) mesh.tri(mid, rim[j], rim[j + 1]);
          continue;
        }
        const steps = Math.max(3, Math.round(around / 4));
        let previous = base;
        for (let k = 1; k < steps; k++) {
          const phi = k / steps * Math.PI / 2;
          const at = centre.clone().addScaledVector(T, r * Math.sin(phi));
          const next = ringAt(at, N, B, r * Math.cos(phi), phi, T, i / along);
          for (let j = 0; j < around; j++) mesh.quad(previous[j], previous[j + 1], next[j + 1], next[j]);
          previous = next;
        }
        const tip = centre.clone().addScaledVector(T, r);
        const apex = mesh.vertex(tip.x, tip.y, tip.z, T.x, T.y, T.z);
        for (let j = 0; j < around; j++) mesh.tri(previous[j], previous[j + 1], apex);
      }
    }
    return mesh.geometry();
  }
  class Section extends L.Curve {       // the stretch [0, until] of another curve, by length
    constructor(curve, until) { super(); this.curve = curve; this.until = until; }
    getPoint(t, target = new L.Vector3()) { return this.curve.getPointAt(t * this.until, target); }
  }
  class Helix extends L.Curve {
    constructor(r, h, turns) { super(); this.r = r; this.h = h; this.turns = turns; }
    getPoint(t, target = new L.Vector3()) {
      const a = t * this.turns * TAU;
      return target.set(this.r * Math.cos(a), -this.h / 2 + this.h * t, this.r * Math.sin(a));
    }
  }
  class Circle extends L.Curve {        // in the xz plane, starting on +x
    constructor(r, sweep) { super(); this.r = r; this.sweep = sweep; }
    getPoint(t, target = new L.Vector3()) {
      const a = t * this.sweep;
      return target.set(this.r * Math.cos(a), 0, -this.r * Math.sin(a));
    }
  }
  const smoothThrough = (pts, closed = false) => new L.CatmullRomCurve3(pts, closed, 'centripetal');

  // ---------------------------------------------------------------- walls (Solidify)
  // A sheet given thickness: the surface, a copy pushed in along the welded, area-weighted normals, and a strip
  // joining them round every open edge. A closed part becomes hollow, which shows once it is cut.
  function wall(g, thickness) {
    g = indexed(g);
    if (!g.attributes.normal) g.computeVertexNormals();
    const p = g.attributes.position, index = g.index.array, triangles = index.length - index.length % 3;
    const id = new Uint32Array(p.count), seen = new Map(), at = [];
    for (let i = 0; i < p.count; i++) {
      const key = Math.round(p.getX(i) * 1e5) + '|' + Math.round(p.getY(i) * 1e5) + '|' + Math.round(p.getZ(i) * 1e5);
      let k = seen.get(key);
      if (k === undefined) { k = at.length; seen.set(key, k); at.push([p.getX(i), p.getY(i), p.getZ(i), 0, 0, 0]); }
      id[i] = k;
    }
    for (let t = 0; t < triangles; t += 3) {
      const a = at[id[index[t]]], b = at[id[index[t + 1]]], c = at[id[index[t + 2]]];
      const ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2], vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
      const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      for (const q of [a, b, c]) { q[3] += nx; q[4] += ny; q[5] += nz; }
    }
    const pushed = at.map(q => {
      const l = Math.hypot(q[3], q[4], q[5]) || 1;
      return [q[0] - q[3] / l * thickness, q[1] - q[4] / l * thickness, q[2] - q[5] / l * thickness];
    });
    const inner = g.clone(), ip = inner.attributes.position, inormal = inner.attributes.normal;
    for (let i = 0; i < p.count; i++) {
      ip.setXYZ(i, ...pushed[id[i]]);
      inormal.setXYZ(i, -inormal.getX(i), -inormal.getY(i), -inormal.getZ(i));
    }
    flip(inner);
    // Open edges: used by one triangle only. Each keeps the direction its triangle runs it in.
    const edges = new Map(), m = at.length;
    for (let t = 0; t < triangles; t += 3) for (let k = 0; k < 3; k++) {
      const a = id[index[t + k]], b = id[index[t + (k + 1) % 3]];
      if (a === b) continue;
      const key = a < b ? a * m + b : b * m + a, e = edges.get(key);
      if (e) e.uses++; else edges.set(key, { a, b, uses: 1 });
    }
    const strip = [];
    for (const { a, b, uses } of edges.values()) {
      if (uses !== 1) continue;
      const A = at[a].slice(0, 3), B = at[b].slice(0, 3), Ai = pushed[a], Bi = pushed[b];
      // The surface runs a -> b, so the strip runs b -> a along the outside and a -> b along the inside.
      strip.push(...B, ...A, ...Ai, ...B, ...Ai, ...Bi);
    }
    const parts = [g, inner];
    if (strip.length) {
      const s = new L.BufferGeometry();
      s.setAttribute('position', new L.Float32BufferAttribute(strip, 3));
      s.computeVertexNormals();
      parts.push(s);
    }
    return join(parts);
  }

  // ---------------------------------------------------------------- soft shapes
  // Balls and sticks melted together: the smooth union of their distances, meshed with surface nets. Each vertex is
  // then pulled onto the true surface (two Newton steps along the field's gradient), and its normal is that
  // gradient, so a blob shades smoothly instead of showing the grid it was found on.
  // A ball is [x, y, z, r] or { at: [x, y, z], r }. A stick is [x1, y1, z1, x2, y2, z2, r, r2?], [[x1, y1, z1],
  // [x2, y2, z2], r, r2?] or { from, to, r, r2? }; r2 (the far end's radius) defaults to r. 64 of each at most.
  const listOf = v => (Array.isArray(v) ? v.slice(0, 64) : []);
  function ballNumbers(b) {
    if (Array.isArray(b)) return b;
    if (!b || typeof b !== 'object') return null;
    const [x = 0, y = 0, z = 0] = Array.isArray(b.at) ? b.at : [];
    return [x, y, z, b.r];
  }
  function stickNumbers(s) {
    if (Array.isArray(s)) return Array.isArray(s[0]) && Array.isArray(s[1]) ? s[0].concat(s[1], [s[2], s[3]]) : s;
    if (s && typeof s === 'object' && Array.isArray(s.from) && Array.isArray(s.to)) return s.from.concat(s.to, [s.r, s.r2]);
    return null;
  }
  function softParts(o) {
    const prims = [];
    for (const v of listOf(o.balls).map(ballNumbers)) {
      if (!v || !v.slice(0, 4).every(isNum) || v.length < 4 || !(v[3] > 0)) continue;
      prims.push({ a: v.slice(0, 3), d: [0, 0, 0], r1: v[3], r2: v[3] });
    }
    for (const v of listOf(o.sticks).map(stickNumbers)) {
      if (!v || v.length < 7 || !v.slice(0, 7).every(isNum) || !(v[6] > 0)) continue;
      const far = isNum(v[7]) && v[7] > 0 ? v[7] : v[6];
      prims.push({ a: v.slice(0, 3), d: [0, 1, 2].map(k => v[3 + k] - v[k]), r1: v[6], r2: far });
    }
    return prims;
  }
  function softBody(o) {
    const prims = softParts(o);
    if (!prims.length) return null;
    const n = prims.length, F = new Float64Array(n * 9);   // a xyz, d xyz, 1/|d|², r1, r2
    let mean = 0, slope = 1;
    const boxes = [];
    prims.forEach((q, i) => {
      const dd = q.d[0] ** 2 + q.d[1] ** 2 + q.d[2] ** 2;
      F.set([...q.a, ...q.d, dd > 1e-12 ? 1 / dd : 0, q.r1, q.r2], i * 9);
      mean += (q.r1 + q.r2) / 2;
      // A tapered stick's distance can change a little faster than 1 per unit moved.
      if (dd > 1e-12) slope = Math.max(slope, Math.sqrt(1 + (q.r2 - q.r1) ** 2 / dd));
      const reach = Math.max(q.r1, q.r2);
      boxes.push([[0, 1, 2].map(a => Math.min(q.a[a], q.a[a] + q.d[a]) - reach), [0, 1, 2].map(a => Math.max(q.a[a], q.a[a] + q.d[a]) + reach)]);
    });
    mean /= n;
    slope *= 1.05;
    const k = within(numOr(o.blend, mean * 0.5), 0, mean * 4), quarterK = k / 4;
    // The polynomial smooth minimum of the listed primitives' distances (each a ball, or a stick whose radius runs
    // from r1 to r2). A primitive farther than the blend from the best so far changes nothing, which is what makes
    // per-block candidate lists exact near the surface.
    const blendScale = k > 0 ? quarterK / (k * k) : 0;
    function field(list, x, y, z) {
      let best = 1e30;
      for (let i = 0, count = list.length; i < count; i++) {
        const o9 = list[i] * 9;
        const px = x - F[o9], py = y - F[o9 + 1], pz = z - F[o9 + 2], dx = F[o9 + 3], dy = F[o9 + 4], dz = F[o9 + 5];
        let h = (px * dx + py * dy + pz * dz) * F[o9 + 6];
        h = h < 0 ? 0 : h > 1 ? 1 : h;
        const qx = px - dx * h, qy = py - dy * h, qz = pz - dz * h;
        const d = Math.sqrt(qx * qx + qy * qy + qz * qz) - (F[o9 + 7] + (F[o9 + 8] - F[o9 + 7]) * h);
        if (i === 0) { best = d; continue; }
        const gap = k - (best > d ? best - d : d - best);
        best = (best < d ? best : d) - (gap > 0 ? gap * gap * blendScale : 0);
      }
      return best;
    }
    const cells = isNum(o.detail) ? within(Math.round(o.detail * 10), 24, 80) : 48;
    const lo = [0, 1, 2].map(a => Math.min(...boxes.map(b => b[0][a]))), hi = [0, 1, 2].map(a => Math.max(...boxes.map(b => b[1][a])));
    const span = Math.max(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]) + k, step = span / cells, pad = k * 0.5 + step * 2;
    const origin = lo.map(v => v - pad), dims = [0, 1, 2].map(a => Math.max(2, Math.ceil((hi[a] - lo[a] + 2 * pad) / step) + 1));
    const [nx, ny, nz] = dims;
    // Blocks of BLOCK cells. Each keeps the primitives whose box, grown by the blend and a few cells, reaches it.
    const BLOCK = 8, bx = Math.ceil(nx / BLOCK), by = Math.ceil(ny / BLOCK), bz = Math.ceil(nz / BLOCK);
    const grow = k + step * 3, lists = new Array(bx * by * bz);
    for (let z = 0; z < bz; z++) for (let y = 0; y < by; y++) for (let x = 0; x < bx; x++) {
      const bl = [x, y, z].map((c, a) => origin[a] + c * BLOCK * step), bh = bl.map(v => v + BLOCK * step);
      const list = [];
      boxes.forEach(([blo, bhi], j) => { if ([0, 1, 2].every(a => blo[a] - grow <= bh[a] && bhi[a] + grow >= bl[a])) list.push(j); });
      lists[x + bx * (y + by * z)] = Int32Array.from(list);
    }
    // Grid samples, each taken once. A block's list is exact for points up to a few cells outside it, so whichever
    // block asks first may take it.
    const values = new Float32Array(nx * ny * nz), sampled = new Uint8Array(nx * ny * nz);
    const value = (x, y, z, list) => {
      const i = x + nx * (y + ny * z);
      if (!sampled[i]) { values[i] = field(list, origin[0] + x * step, origin[1] + y * step, origin[2] + z * step); sampled[i] = 1; }
      return values[i];
    };
    // A vertex in every cell the surface crosses, pulled onto the surface.
    const vertexOf = new Int32Array((nx - 1) * (ny - 1) * (nz - 1)).fill(-1), crossed = [], mesh = new Mesh(), e = step * 0.25;
    // The field's gradient from four samples at a tetrahedron's corners round the point.
    const gradient = (list, x, y, z) => {
      const a = field(list, x + e, y - e, z - e), b = field(list, x - e, y - e, z + e), c = field(list, x - e, y + e, z - e), d = field(list, x + e, y + e, z + e);
      return [(a - b - c + d) / (4 * e), (-a - b + c + d) / (4 * e), (-a + b - c + d) / (4 * e)];
    };
    const corner = new Float64Array(8);
    const cellVertex = (x, y, z, list) => {
      let sx = 0, sy = 0, sz = 0, hits = 0;
      for (let c = 0; c < 8; c++) corner[c] = value(x + (c & 1), y + ((c >> 1) & 1), z + (c >> 2), list);
      for (let c = 0; c < 8; c++) for (const axisBit of [1, 2, 4]) {
        if (c & axisBit) continue;
        const va = corner[c], vb = corner[c | axisBit];
        if ((va < 0) === (vb < 0)) continue;
        const t = va / (va - vb);
        sx += (c & 1) + (axisBit === 1 ? t : 0); sy += ((c >> 1) & 1) + (axisBit === 2 ? t : 0); sz += (c >> 2) + (axisBit === 4 ? t : 0);
        hits++;
      }
      let px = origin[0] + (x + sx / hits) * step, py = origin[1] + (y + sy / hits) * step, pz = origin[2] + (z + sz / hits) * step;
      // One Newton step onto the surface (never farther than a cell), then the normal where it lands.
      let g = gradient(list, px, py, pz);
      const f = field(list, px, py, pz), gg = g[0] * g[0] + g[1] * g[1] + g[2] * g[2];
      if (gg > 1e-12) {
        const move = f / gg * Math.min(1, step / (Math.abs(f) / Math.sqrt(gg) + 1e-12));
        px -= g[0] * move; py -= g[1] * move; pz -= g[2] * move;
        g = gradient(list, px, py, pz);
      }
      const gl = Math.hypot(g[0], g[1], g[2]) || 1;
      return mesh.vertex(px, py, pz, g[0] / gl, g[1] / gl, g[2] / gl);
    };
    // Only a thin band round the surface is sampled: a block whose middle is farther from the surface than any of its
    // corners can be (the field changes at most `slope` per unit) can't hold it and is skipped; the rest are halved
    // down to single cells.
    const visit = (x0, y0, z0, span, list) => {
      const x1 = Math.min(x0 + span, nx - 1), y1 = Math.min(y0 + span, ny - 1), z1 = Math.min(z0 + span, nz - 1);
      if (x0 >= x1 || y0 >= y1 || z0 >= z1) return;
      if (span > 1) {
        const half = Math.hypot(x1 - x0, y1 - y0, z1 - z0) * step / 2;
        const f = field(list, origin[0] + (x0 + x1) / 2 * step, origin[1] + (y0 + y1) / 2 * step, origin[2] + (z0 + z1) / 2 * step);
        if (Math.abs(f) > slope * half) return;
        const s = span >> 1;
        for (let c = 0; c < 8; c++) visit(x0 + (c & 1) * s, y0 + ((c >> 1) & 1) * s, z0 + (c >> 2) * s, s, list);
        return;
      }
      const inside = value(x0, y0, z0, list) < 0;
      let mixed = false;
      for (let c = 1; c < 8 && !mixed; c++) mixed = (value(x0 + (c & 1), y0 + ((c >> 1) & 1), z0 + (c >> 2), list) < 0) !== inside;
      if (!mixed) return;
      vertexOf[x0 + (nx - 1) * (y0 + (ny - 1) * z0)] = cellVertex(x0, y0, z0, list);
      crossed.push(x0, y0, z0);
    };
    for (let z = 0; z < bz; z++) for (let y = 0; y < by; y++) for (let x = 0; x < bx; x++) {
      const list = lists[x + bx * (y + by * z)];
      if (list.length) visit(x * BLOCK, y * BLOCK, z * BLOCK, BLOCK, list);
    }
    const cell = (x, y, z) => x < 0 || y < 0 || z < 0 || x >= nx - 1 || y >= ny - 1 || z >= nz - 1 ? -1 : vertexOf[x + (nx - 1) * (y + (ny - 1) * z)];
    const sign = (x, y, z) => values[x + nx * (y + ny * z)] < 0;   // every corner of a crossed cell was sampled
    const face = (a, b, c, d) => { if (a >= 0 && b >= 0 && c >= 0 && d >= 0) mesh.quad(a, b, c, d); };
    // A quad round every grid edge with a sign change, joining the four cells that share it (each edge belongs to
    // the cell at its low end, which was crossed). Mesh.tri orients it by the gradient normals.
    for (let i = 0; i < crossed.length; i += 3) {
      const x = crossed[i], y = crossed[i + 1], z = crossed[i + 2], inside = sign(x, y, z);
      if (sign(x + 1, y, z) !== inside) face(cell(x, y - 1, z - 1), cell(x, y, z - 1), cell(x, y, z), cell(x, y - 1, z));
      if (sign(x, y + 1, z) !== inside) face(cell(x - 1, y, z - 1), cell(x, y, z - 1), cell(x, y, z), cell(x - 1, y, z));
      if (sign(x, y, z + 1) !== inside) face(cell(x - 1, y - 1, z), cell(x, y - 1, z), cell(x, y, z), cell(x - 1, y, z));
    }
    return mesh.geometry();
  }

  // A seeded random source, so a blob's lumps are the same every time its recipe is built.
  function seeded(seed) {
    let s = (Math.floor(seed * 1000) ^ 0x9e3779b9) >>> 0;
    return { random() { s = (s + 0x6d2b79f5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; } };
  }

  // ---------------------------------------------------------------- SVG path data
  // M L H V C S Q T A Z, absolute and relative, with repeated arguments. y is flipped (SVG's y runs down the
  // screen, a shape's runs up) and every coordinate is scaled by `unit`.
  function readPathData(d, unit) {
    const path = new L.ShapePath(), tokens = d.match(/[a-zA-Z]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/g) || [];
    const at = (x, y) => [x * unit, -y * unit];
    let i = 0, command = '', x = 0, y = 0, startX = 0, startY = 0, control = null, previous = '';
    const more = () => i < tokens.length && !/^[a-zA-Z]$/.test(tokens[i]);
    const next = () => +tokens[i++];
    for (let guard = 0; i < tokens.length && guard < 20000; guard++) {
      if (/^[a-zA-Z]$/.test(tokens[i])) command = tokens[i++];
      else if (!command) { i++; continue; }
      const relative = command !== command.toUpperCase(), kind = command.toUpperCase();
      const X = v => (relative ? x + v : v), Y = v => (relative ? y + v : v);
      if (kind === 'Z') {
        if (path.currentPath) path.currentPath.closePath();
        x = startX; y = startY; previous = 'Z'; control = null;
        continue;
      }
      if (!more()) continue;
      const need = { M: 2, L: 2, H: 1, V: 1, C: 6, S: 4, Q: 4, T: 2, A: 7 }[kind];
      if (!need || tokens.length - i < need) { i++; continue; }
      if (kind === 'M') {
        x = X(next()); y = Y(next()); startX = x; startY = y;
        path.moveTo(...at(x, y));
        command = relative ? 'l' : 'L';      // more pairs after a move are lines
        control = null;
      } else if (kind === 'L' || kind === 'H' || kind === 'V') {
        if (kind !== 'V') x = kind === 'H' ? X(next()) : X(next());
        if (kind === 'L') y = Y(next()); else if (kind === 'V') y = Y(next());
        path.lineTo(...at(x, y));
        control = null;
      } else if (kind === 'C' || kind === 'S') {
        const reflect = previous === 'C' && control;
        const c1 = kind === 'C' ? [X(next()), Y(next())] : reflect ? [2 * x - control[0], 2 * y - control[1]] : [x, y];
        const c2 = [X(next()), Y(next())], end = [X(next()), Y(next())];
        path.bezierCurveTo(...at(...c1), ...at(...c2), ...at(...end));
        control = c2; [x, y] = end;
      } else if (kind === 'Q' || kind === 'T') {
        const reflect = previous === 'Q' && control;
        const c = kind === 'Q' ? [X(next()), Y(next())] : reflect ? [2 * x - control[0], 2 * y - control[1]] : [x, y];
        const end = [X(next()), Y(next())];
        path.quadraticCurveTo(...at(...c), ...at(...end));
        control = c; [x, y] = end;
      } else {
        const rx = Math.abs(next()), ry = Math.abs(next()), tilt = next() * Math.PI / 180, large = next() !== 0, sweep = next() !== 0;
        const end = [X(next()), Y(next())];
        for (const [px, py] of arcPoints(x, y, rx, ry, tilt, large, sweep, end[0], end[1])) path.lineTo(...at(px, py));
        control = null; [x, y] = end;
      }
      previous = kind === 'S' ? 'C' : kind === 'T' ? 'Q' : kind;
      if (!Number.isFinite(x) || !Number.isFinite(y)) break;
    }
    return path;
  }
  // An SVG endpoint arc as points no more than 7.5° apart (centre found as the SVG spec's appendix describes).
  function arcPoints(x1, y1, rx, ry, tilt, large, sweep, x2, y2) {
    if (rx < 1e-12 || ry < 1e-12 || (x1 === x2 && y1 === y2)) return [[x2, y2]];
    const c = Math.cos(tilt), s = Math.sin(tilt), hx = (x1 - x2) / 2, hy = (y1 - y2) / 2;
    const px = c * hx + s * hy, py = -s * hx + c * hy;
    const grow = px * px / (rx * rx) + py * py / (ry * ry);
    if (grow > 1) { rx *= Math.sqrt(grow); ry *= Math.sqrt(grow); }
    const top = rx * rx * ry * ry - rx * rx * py * py - ry * ry * px * px, bottom = rx * rx * py * py + ry * ry * px * px;
    const scale = (large === sweep ? -1 : 1) * Math.sqrt(Math.max(0, top / (bottom || 1)));
    const cpx = scale * rx * py / ry, cpy = -scale * ry * px / rx;
    const cx = c * cpx - s * cpy + (x1 + x2) / 2, cy = s * cpx + c * cpy + (y1 + y2) / 2;
    const angle = (ux, uy) => Math.atan2(uy, ux);
    const from = angle((px - cpx) / rx, (py - cpy) / ry);
    let turn = angle((-px - cpx) / rx, (-py - cpy) / ry) - from;
    if (sweep && turn < 0) turn += TAU; else if (!sweep && turn > 0) turn -= TAU;
    const steps = Math.max(2, Math.ceil(Math.abs(turn) / (7.5 * Math.PI / 180))), out = [];
    for (let k = 1; k <= steps; k++) {
      const a = from + turn * k / steps, ex = rx * Math.cos(a), ey = ry * Math.sin(a);
      out.push(k === steps ? [x2, y2] : [cx + c * ex - s * ey, cy + s * ex + c * ey]);
    }
    return out;
  }
  // Outline points with repeats (and a closing copy of the first point) removed: extruding a duplicate leaves a crack.
  function clean(points) {
    const out = [];
    for (const p of points) if (!out.length || out[out.length - 1].distanceToSquared(p) > 1e-14) out.push(p);
    while (out.length > 1 && out[0].distanceToSquared(out[out.length - 1]) <= 1e-14) out.pop();
    return out;
  }
  // The recipe's flat shapes: SVG path data in `d`, or a point list `shape` with optional `holes`.
  function flatShapes(o) {
    let shapes = [];
    if (typeof o.d === 'string' && o.d.trim()) shapes = readPathData(o.d.slice(0, 20000), numOr(o.unit, 0.01)).toShapes(true);
    if (!shapes.length) {
      const outline = (Array.isArray(o.shape) ? o.shape : []).map(point2).filter(Boolean).slice(0, 2000);
      const s = new L.Shape(outline.length >= 3 ? outline : [new L.Vector2(0, 0), new L.Vector2(1, 0), new L.Vector2(1, 1)]);
      for (const hole of Array.isArray(o.holes) ? o.holes : []) {
        const h = (Array.isArray(hole) ? hole : []).map(point2).filter(Boolean);
        if (h.length >= 3) s.holes.push(new L.Path(h));
      }
      shapes = [s];
    }
    return shapes.map(s => {
      const { shape, holes } = s.extractPoints(12), out = new L.Shape(clean(shape));
      for (const h of holes) { const c = clean(h); if (c.length >= 3) out.holes.push(new L.Path(c)); }
      return out;
    }).filter(s => s.curves.length >= 2);
  }
  function extruded(shapes, depth, bevel, bevelSegments) {
    const g = new L.ExtrudeGeometry(shapes, { depth, bevelEnabled: bevel > 0, bevelSize: bevel, bevelThickness: bevel, bevelSegments, curveSegments: 12 });
    return g.translate(0, 0, -depth / 2);
  }

  // ---------------------------------------------------------------- kinds
  const KINDS = {
    box(o) {
      const s = Array.isArray(o.size) ? o.size : [o.w, o.h, o.d];
      const w = size(s[0], 1), h = size(s[1], 1), d = size(s[2], 1);
      const r = Math.min(numOr(o.r, numOr(o.bevel, 0)), Math.min(w, h, d) * 0.45);
      return r > 5e-4 ? new L.RoundedBoxGeometry(w, h, d, 4, r) : new L.BoxGeometry(w, h, d);
    },
    cyl(o) {
      const r = size(o.r, 0.5), top = Math.max(0, numOr(o.top, r)), h = size(o.h, 1), open = o.open === true;
      const b = open ? 0 : bevelOf(o, Math.min(Math.min(r, top || r), h) * 0.45);
      let profile = open ? [[r, -h / 2], [top, h / 2]] : [[0, -h / 2], [r, -h / 2], [top, h / 2], [0, h / 2]];
      if (b > 5e-4) profile = rounded(profile, top > 0 ? [1, 2] : [1], b);
      return aim(revolve(profile, segmentsOf(o, 48), sweepOf(o), open), o.axis);
    },
    cone(o) {
      const r = size(o.r, 0.5), h = size(o.h, 1), b = bevelOf(o, Math.min(r, h) * 0.45);
      let profile = [[0, -h / 2], [r, -h / 2], [0, h / 2]];
      if (b > 5e-4) profile = rounded(profile, [1], b);
      return aim(revolve(profile, segmentsOf(o, 48), sweepOf(o)), o.axis);
    },
    // A cylinder with a hole down its middle (`inner` is the hole's radius): a pipe length, a bearing, a thick ring.
    tube(o) {
      const r = size(o.r, 1), inner = within(numOr(o.inner, r * 0.8), 0, r * 0.999), h = size(o.h, 1);
      const b = bevelOf(o, Math.min((r - inner), h) * 0.45);
      // Counter-clockwise from halfway up the inside wall, so the seam sits on a flat stretch.
      let profile = [[inner, 0], [inner, -h / 2], [r, -h / 2], [r, h / 2], [inner, h / 2], [inner, 0]];
      if (b > 5e-4) profile = rounded(profile, [1, 2, 3, 4], b);
      return aim(revolve(profile, segmentsOf(o, 64), sweepOf(o)), o.axis);
    },
    // A flow arrow: a round-ended shaft along a smooth curve through points, ending in a cone (air through an engine,
    // blood through a heart, which way a gear turns). r is the shaft's radius; head and headR the cone's length and radius.
    arrow(o) {
      const pts = pathPoints(o.points, 200);
      if (pts.length < 2) pts.splice(0, pts.length, pts[0] || new L.Vector3(), (pts[0] || new L.Vector3()).clone().add(new L.Vector3(1, 0, 0)));
      const r = size(o.r, 0.04), curve = smoothThrough(pts), length = curve.getLength();
      const head = Math.min(size(o.head, r * 5), length * 0.6), headR = size(o.headR, r * 2.6);
      const until = Math.max(1e-3, (length - head) / length);
      const shaft = sweepTube(new Section(curve, until), r, within(Math.round(length * until / r * 2), 16, 400), 16, { ends: 'flat' });
      // The flat end sits under the cone's base; round off the tail instead.
      const tail = sweepTube(new Section(curve, Math.min(until, r / length)), r, 1, 16, { ends: 'round' });
      const base = curve.getPointAt(until), tip = curve.getPointAt(1), heading = tip.clone().sub(base);
      if (heading.lengthSq() < 1e-12) heading.copy(curve.getTangentAt(1));
      const cone = revolve([[0, 0], [headR, 0], [0, head]], 32);
      cone.applyQuaternion(new L.Quaternion().setFromUnitVectors(new L.Vector3(0, 1, 0), heading.normalize()));
      cone.translate(base.x, base.y, base.z);
      return join([shaft, tail, cone]);
    },
    lathe(o) {
      const profile = (Array.isArray(o.profile) ? o.profile : []).map(point2).filter(Boolean).slice(0, 400).map(p => [Math.max(0, p.x), p.y]);
      // A hand-written profile is a few points standing for a smooth curve: only near-right-angle bends stay sharp.
      return aim(revolve(profile.length >= 2 ? profile : [[0, 0], [1, 0], [1, 1], [0, 1]], whole(o.seg, 64, 8, 128), TAU, true, 65), o.axis);
    },
    sphere(o) {
      const r = size(o.r, 0.5), seg = numOr(o.seg, 48);
      // dome: true keeps the top half (a dome, a cap, an eye's cornea), open underneath.
      return aim(new L.SphereGeometry(r, whole(seg, 48, 8, 128), whole(seg * 2 / 3, 32, 6, 96), 0, TAU, 0, o.dome === true ? Math.PI / 2 : Math.PI), o.axis);
    },
    // Lies flat, its hole along y. A partial arc gets flat ends, like a cut length of hose.
    torus(o) {
      const sweep = sweepOf(o), full = sweep >= TAU - 1e-9;
      const g = sweepTube(new Circle(size(o.r, 1), sweep), size(o.tube, 0.2), Math.max(8, Math.round(72 * sweep / TAU)), 24, { closed: full, ends: 'flat' });
      return aim(g, o.axis || 'y');
    },
    capsule(o) {
      return aim(new L.CapsuleGeometry(size(o.r, 0.3), Math.max(0, numOr(o.h, 1)), 8, 24), o.axis);
    },
    // A tube along a smooth curve through points, with round ends: a hose, a wire, a blood vessel, a strand, a pipe run.
    pipe(o) {
      const pts = pathPoints(o.points, 200);
      if (pts.length < 2) pts.splice(0, pts.length, new L.Vector3(0, 0, 0), new L.Vector3(0, 1, 0));
      const closed = o.closed === true && pts.length >= 3;
      return sweepTube(smoothThrough(pts, closed), size(o.r, 0.1), within(pts.length * 24, 24, 2400), whole(o.seg, 16, 4, 32), { closed });
    },
    spring(o) {
      const r = size(o.r, 0.5), h = size(o.h, 2), coils = within(numOr(o.coils, 8), 0.25, 60);
      return aim(sweepTube(new Helix(r, h, coils), size(o.wire, 0.06), Math.round(within(coils * 40, 16, 2400)), 12), o.axis);
    },
    // A spur gear lying in the xy plane (its axle along z): `teeth` round its rim, each with flanks that bulge a
    // little and a rounded tip, and an axle hole when `hole` > 0.
    gear(o) {
      const teeth = whole(o.teeth, 16, 6, 200), r = size(o.r, 1), depth = within(numOr(o.tooth, r * 0.14), r * 0.02, r * 0.5);
      const width = size(o.w, 0.3), root = r - depth, pitch = TAU / teeth;
      const tipHalf = pitch * 0.16, baseHalf = pitch * 0.27, outline = [];
      const polar = (a, rr) => new L.Vector2(rr * Math.cos(a), rr * Math.sin(a));
      for (let t = 0; t < teeth; t++) {
        const c = t * pitch;
        // Up one flank (bulging: halfway up it has already closed 70% of the gap to the tip), across the tip, down.
        const flank = s => (baseHalf - (baseHalf - tipHalf) * Math.sin(s * Math.PI / 2));
        outline.push(polar(c - flank(0), root), polar(c - flank(0.5), root + depth * 0.5), polar(c - tipHalf, r));
        outline.push(polar(c + tipHalf, r), polar(c + flank(0.5), root + depth * 0.5), polar(c + flank(0), root));
        outline.push(polar(c + pitch / 2, root));
      }
      const shape = new L.Shape(clean(outline)), hole = numOr(o.hole, 0);
      if (hole > 0 && hole < root) { const p = new L.Path(); p.absarc(0, 0, hole, 0, TAU, true); shape.holes.push(p); }
      const bevel = isNum(o.bevel) ? Math.min(Math.max(0, o.bevel), width * 0.45, depth * 0.45) : Math.min(0.02, width * 0.2);
      return aim(extruded([shape], width, bevel, 2), o.axis || 'z', 'z');
    },
    // An outline in the xy plane (points in `shape` with optional `holes`, or SVG path data in `d`) given `depth` along z.
    extrude(o) {
      const depth = size(o.depth, 0.3);
      const bevel = o.bevel === false ? 0 : isNum(o.bevel) ? Math.min(Math.max(0, o.bevel), depth * 0.45) : Math.min(0.015, depth * 0.2);
      const shapes = flatShapes(o);
      return aim(extruded(shapes.length ? shapes : [new L.Shape([new L.Vector2(0, 0), new L.Vector2(1, 0), new L.Vector2(1, 1)])], depth, bevel, isNum(o.bevel) ? 3 : 2), o.axis || 'z', 'z');
    },
    // An organic lump: a cell, an organelle, a rock, a cloud. Given balls ([x, y, z, r]) and sticks
    // ([x1, y1, z1, x2, y2, z2, r, r2]) it is those melted together (blend sets how wide the melt is); otherwise a
    // sphere of radius r (or size [x, y, z], squash) roughened by smooth noise of strength `lumps`.
    blob(o) {
      const soft = softBody(o);
      if (soft) return soft;   // balls or sticks given
      const g = L.mergeVertices(new L.IcosahedronGeometry(1, whole(o.detail, 5, 2, 8) + 3).deleteAttribute('normal').deleteAttribute('uv'));
      const noise = new L.SimplexNoise(seeded(numOr(o.seed, 1))), lumps = within(numOr(o.lumps, 0.12), 0, 0.22);
      const r = numOr(o.r, 1), s = Array.isArray(o.size) ? o.size : [r, r * numOr(o.squash, 1), r];
      const sx = size(s[0], 1), sy = size(s[1], 1), sz = size(s[2], 1), p = g.attributes.position;
      for (let i = 0; i < p.count; i++) {
        const x = p.getX(i), y = p.getY(i), z = p.getZ(i);
        // A few broad lobes with a faint second layer: a potato or a cell, not gravel.
        const bump = noise.noise3d(x * 0.55, y * 0.55, z * 0.55) + noise.noise3d(x * 1.2 + 7, y * 1.2, z * 1.2) * 0.2;
        const k = 1 + lumps * bump;
        p.setXYZ(i, x * sx * k, y * sy * k, z * sz * k);
      }
      g.computeVertexNormals();
      return g;
    },
    // A regular solid with 4, 6, 8, 12 or 20 faces (20 unless said): gems, dice, crystals, cages.
    poly(o) {
      const r = size(o.r, 0.5), detail = whole(o.detail, 0, 0, 3), faces = Math.round(numOr(o.faces, 20));
      const g = faces === 4 ? new L.TetrahedronGeometry(r, detail) : faces === 6 ? new L.BoxGeometry(r * 1.15, r * 1.15, r * 1.15)
        : faces === 8 ? new L.OctahedronGeometry(r, detail) : faces === 12 ? new L.DodecahedronGeometry(r, detail) : new L.IcosahedronGeometry(r, detail);
      return aim(g, o.axis);
    },
    // A sheet through a grid of points the engine sampled (rows of [x, y, z]), such as z = f(u, v).
    surface(o) {
      const rows = (Array.isArray(o.grid) ? o.grid : []).map(row => (Array.isArray(row) ? row : []).map(point3)).filter(row => row.length >= 2 && row.every(Boolean));
      const columns = rows.length ? Math.min(...rows.map(row => row.length)) : 0;
      if (rows.length < 2 || columns < 2) return new L.PlaneGeometry(1, 1);
      const p = [], t = [], ix = [];
      rows.forEach((row, j) => { for (let i = 0; i < columns; i++) { p.push(row[i].x, row[i].y, row[i].z); t.push(i / (columns - 1), j / (rows.length - 1)); } });
      for (let j = 0; j + 1 < rows.length; j++) for (let i = 0; i + 1 < columns; i++) {
        const a = j * columns + i, b = a + columns;
        ix.push(a, b, a + 1, b, b + 1, a + 1);
      }
      const g = arrays(p, null, t, ix);
      g.computeVertexNormals();
      return g;
    },
  };
  KINDS.cylinder = KINDS.cyl;           // the name three.js and the old scene3d() use

  // ---------------------------------------------------------------- packing for the stage
  // Up to `max` points that frame the part, for the camera: the extremes along each axis first, then vertices taken
  // at an even stride.
  function framing(p, max) {
    const n = p.length / 3;
    if (n <= max) return Float32Array.from(p);
    const keep = new Set();
    for (let a = 0; a < 3; a++) {
      let low = 0, high = 0;
      for (let i = 1; i < n; i++) {
        if (p[i * 3 + a] < p[low * 3 + a]) low = i;
        if (p[i * 3 + a] > p[high * 3 + a]) high = i;
      }
      keep.add(low).add(high);
    }
    const stride = n / (max - keep.size);
    for (let k = 0; keep.size < max && k * stride < n; k++) keep.add(Math.floor(k * stride));
    const out = new Float32Array(keep.size * 3);
    let o = 0;
    for (const i of keep) { out[o++] = p[i * 3]; out[o++] = p[i * 3 + 1]; out[o++] = p[i * 3 + 2]; }
    return out;
  }
  function pack(g) {
    indexed(g);
    if (!g.attributes.normal) g.computeVertexNormals();
    const count = g.attributes.position.count;
    if (count > VERTEX_LIMIT) throw new Error('part too detailed (' + count + ' vertices)');
    const positions = Float32Array.from(g.attributes.position.array), normals = Float32Array.from(g.attributes.normal.array);
    for (let i = 0; i < positions.length; i++) if (!Number.isFinite(positions[i]) || !Number.isFinite(normals[i])) throw new Error('part has invalid geometry');
    return {
      positions, normals,
      uvs: g.attributes.uv ? Float32Array.from(g.attributes.uv.array) : null,
      indices: Uint32Array.from(g.index.array),
      samples: framing(positions, 600),
    };
  }

  globalThis.mateThreeKinds = Object.keys(KINDS);
  globalThis.mateThreeBuild = function (kind, recipeJSON) {
    const make = Object.prototype.hasOwnProperty.call(KINDS, kind) ? KINDS[kind] : null;
    if (!make) throw new Error(`unknown 3D part "${kind}"`);
    const recipe = JSON.parse(recipeJSON || '{}') || {};
    let g = make(recipe);
    const thick = numOr(recipe.thick, 0);
    if (thick > 0) g = wall(g, Math.min(thick, 10));
    // An uneven scale, then a mirror (figure()'s mirror: 'x' sends its copy with mirror [-1, 1, 1]). A negative scale
    // turns the part inside out, so its triangles are reversed to face out again.
    const stretch = point3(recipe.stretch), mirror = point3(recipe.mirror);
    const factor = a => (stretch ? stretch.getComponent(a) || 1 : 1) * (mirror ? Math.sign(mirror.getComponent(a)) || 1 : 1);
    const sx = factor(0), sy = factor(1), sz = factor(2);
    if (sx !== 1 || sy !== 1 || sz !== 1) g.scale(sx, sy, sz);
    if (sx * sy * sz < 0) flip(g);
    return pack(g);
  };
})();
