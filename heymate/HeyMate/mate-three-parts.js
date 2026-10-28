// Mate's 3D kernel: every part a figure() program makes, built with three.js (mate-three.js, loaded first) into
// the arrays the Metal stage draws. It runs in its own JavaScriptCore context on a background queue
// (MateThreeKernel.swift), never in the drawing engine's: a part's shape is built when its statement runs, long
// before its beat draws it, and cached by its recipe.
//
// mateThreeBuild(kind, recipeJSON) -> { positions, normals, uvs, indices, samples } (typed arrays) or throws.
// Recipes are what the engine's figure() parts send (mate-draw-engine.js api.figure): sizes in world units, `axis`
// for the part's main axis ('x', '-z' or [x, y, z]; most parts stand along y), `stretch` [sx, sy, sz] for a part
// scaled unevenly. Shapes follow the 3D speed bench's three.js lane (lab runtime.js geometryFor) so its programs
// draw the same here.
(function () {
  'use strict';
  const T = globalThis.MateThreeLib;
  const num = (v, d) => (typeof v === 'number' && isFinite(v) ? v : d);
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const pos = (v, d) => Math.max(1e-4, num(v, d));
  const vec3 = p => Array.isArray(p) && p.length >= 3 && p.every(n => typeof n === 'number' && isFinite(n)) ? new T.Vector3(p[0], p[1], p[2]) : null;
  const vec2 = p => Array.isArray(p) && p.length >= 2 && isFinite(p[0]) && isFinite(p[1]) ? new T.Vector2(+p[0], +p[1]) : null;
  // The most any one part may hold, so a runaway recipe (a spring of a thousand coils) can't stall the kernel.
  const MAX_VERTICES = 120000;

  const AXES = { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] };
  function axisVector(axis) {
    if (typeof axis === 'string') {
      const m = /^\s*([+-]?)\s*([xyz])\s*$/i.exec(axis);
      if (!m) return null;
      const a = AXES[m[2].toLowerCase()];
      return new T.Vector3(a[0], a[1], a[2]).multiplyScalar(m[1] === '-' ? -1 : 1);
    }
    const v = vec3(axis);
    return v && v.lengthSq() > 1e-12 ? v.normalize() : null;
  }
  // Turns a part built along its natural axis (y for most) to point along `axis`.
  function turnTo(geometry, axis, natural) {
    const to = axisVector(axis);
    const from = new T.Vector3(...AXES[natural || 'y']);
    if (!to || to.distanceToSquared(from) < 1e-12) return geometry;
    return geometry.applyQuaternion(new T.Quaternion().setFromUnitVectors(from, to));
  }

  // ---------------------------------------------------------------- bevels (three-metal, 2026-10-12)
  // Blender's answers bevel nearly every machined part (19 of 26 scripts on the language bar): a rounded edge catches
  // the light, which is most of why a model reads as real. A bevelled round part is a lathe of its outline with each
  // corner rounded by a quarter arc.
  const BEVEL_STEPS = 4;
  // The corner at (x, y) between the edge coming in and the one going out, rounded by radius b (a quarter-ish arc
  // that starts b back along the incoming edge and ends b along the outgoing one).
  function roundCorner(points, prev, corner, next, b) {
    const ax = prev[0] - corner[0], ay = prev[1] - corner[1], bx = next[0] - corner[0], by = next[1] - corner[1];
    const la = Math.hypot(ax, ay) || 1, lb = Math.hypot(bx, by) || 1;
    const s = [corner[0] + ax / la * b, corner[1] + ay / la * b], e = [corner[0] + bx / lb * b, corner[1] + by / lb * b];
    for (let i = 0; i <= BEVEL_STEPS; i++) {
      const t = i / BEVEL_STEPS, u = 1 - t;
      // A quadratic Bézier with the corner as its control point: tangent to both edges.
      points.push([u * u * s[0] + 2 * u * t * corner[0] + t * t * e[0], u * u * s[1] + 2 * u * t * corner[1] + t * t * e[1]]);
    }
  }
  // A closed or open outline [[x, y], ...] with every corner listed in `rounded` (indices) rounded by b.
  function roundOutline(outline, rounded, b) {
    const points = [];
    outline.forEach((p, i) => {
      if (rounded.includes(i) && i > 0 && i < outline.length - 1) roundCorner(points, outline[i - 1], p, outline[i + 1], b);
      else points.push(p);
    });
    return points.map(([x, y]) => new T.Vector2(Math.max(0, x), y));
  }
  const latheOf = (points, o) => new T.LatheGeometry(points, clamp(Math.round(num(o.seg, 64)), 8, 128), 0, clamp(num(o.arc, 360), 1, 360) * Math.PI / 180);
  // Several indexed geometries as one (position, normal, uv), for parts built from pieces (an arrow's shaft and head).
  function merged(geometries) {
    const positions = [], normals = [], uvs = [], indices = [];
    for (const geometry of geometries) {
      if (!geometry.attributes.normal) geometry.computeVertexNormals();
      const base = positions.length / 3, p = geometry.attributes.position, n = geometry.attributes.normal, uv = geometry.attributes.uv;
      for (let i = 0; i < p.count; i++) {
        positions.push(p.getX(i), p.getY(i), p.getZ(i));
        normals.push(n.getX(i), n.getY(i), n.getZ(i));
        uvs.push(uv ? uv.getX(i) : 0, uv ? uv.getY(i) : 0);
      }
      if (geometry.index) { const index = geometry.index.array; for (let i = 0; i < index.length; i++) indices.push(base + index[i]); }
      else for (let i = 0; i < p.count; i++) indices.push(base + i);
    }
    const out = new T.BufferGeometry();
    out.setAttribute('position', new T.Float32BufferAttribute(positions, 3));
    out.setAttribute('normal', new T.Float32BufferAttribute(normals, 3));
    out.setAttribute('uv', new T.Float32BufferAttribute(uvs, 2));
    out.setIndex(indices);
    return out;
  }
  // A geometry turned inside out by a mirror or a negative scale: its triangles wound the other way again, so they
  // still face out (the stage culls back faces).
  function rewind(g) {
    if (g.index) {
      const index = g.index.array;
      for (let i = 0; i + 2 < index.length; i += 3) { const t = index[i + 1]; index[i + 1] = index[i + 2]; index[i + 2] = t; }
      g.index.needsUpdate = true;
      return;
    }
    for (const name of Object.keys(g.attributes)) {
      const a = g.attributes[name], size = a.itemSize, array = a.array;
      for (let v = 0; v + 2 < a.count; v += 3) for (let k = 0; k < size; k++) {
        const one = (v + 1) * size + k, two = (v + 2) * size + k, t = array[one]; array[one] = array[two]; array[two] = t;
      }
    }
  }
  const bevelOf = (o, limit) => Math.min(Math.max(0, num(o.bevel, 0)), limit);

  // ---------------------------------------------------------------- thickness (Blender's Solidify, three-metal 2026-10-12)
  // A thin sheet (a dome, a membrane, a valve leaflet, a canopy, a shell) given a wall: the surface, a copy pushed in
  // along its normals by `thick` facing the other way, and a rim joining the two round every open edge (19 of 26
  // Blender answers on the language bar did this). A closed part becomes hollow, which shows once it is cut.
  function solidify(g, thickness) {
    if (!g.attributes.normal) g.computeVertexNormals();
    const p = g.attributes.position, count = p.count;
    const index = g.index ? g.index.array : Uint32Array.from({ length: count }, (_, i) => i);
    const triangles = index.length - index.length % 3;
    // Welded points (a seam's or a hard edge's copies are one point), each with its area-weighted normal: the wall is
    // pushed in along it, so it stays one piece across seams.
    const ids = new Uint32Array(count), keys = new Map(), welded = [];
    for (let i = 0; i < count; i++) {
      const key = Math.round(p.getX(i) * 1e5) + ',' + Math.round(p.getY(i) * 1e5) + ',' + Math.round(p.getZ(i) * 1e5);
      let id = keys.get(key);
      if (id === undefined) { id = welded.length; keys.set(key, id); welded.push([p.getX(i), p.getY(i), p.getZ(i), 0, 0, 0]); }
      ids[i] = id;
    }
    for (let t = 0; t < triangles; t += 3) {
      const a = welded[ids[index[t]]], b = welded[ids[index[t + 1]]], c = welded[ids[index[t + 2]]];
      const ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2], vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
      const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      for (const w of [a, b, c]) { w[3] += nx; w[4] += ny; w[5] += nz; }
    }
    for (const w of welded) { const l = Math.hypot(w[3], w[4], w[5]) || 1; w[3] /= l; w[4] /= l; w[5] /= l; }
    const inward = w => [w[0] - w[3] * thickness, w[1] - w[4] * thickness, w[2] - w[5] * thickness];
    // The inside wall: every point pushed in, facing the other way.
    const inner = g.clone();
    const ip = inner.attributes.position, inn = inner.attributes.normal;
    for (let i = 0; i < count; i++) {
      ip.setXYZ(i, ...inward(welded[ids[i]]));
      inn.setXYZ(i, -inn.getX(i), -inn.getY(i), -inn.getZ(i));
    }
    rewind(inner);
    // The rim round every open edge (an edge only one triangle has), wound to face out across the edge.
    const edges = new Map();
    for (let t = 0; t < triangles; t += 3) for (let k = 0; k < 3; k++) {
      const a = ids[index[t + k]], b = ids[index[t + (k + 1) % 3]];
      if (a === b) continue;
      const key = a < b ? a * welded.length + b : b * welded.length + a;
      const e = edges.get(key);
      if (e) e[2]++; else edges.set(key, [a, b, 1]);
    }
    const rim = [];
    for (const [a, b, uses] of edges.values()) {
      if (uses !== 1) continue;
      const A = welded[a].slice(0, 3), B = welded[b].slice(0, 3), Ai = inward(welded[a]), Bi = inward(welded[b]);
      rim.push(...A, ...Ai, ...Bi, ...A, ...Bi, ...B);
    }
    const pieces = [g, inner];
    if (rim.length) {
      const r = new T.BufferGeometry();
      r.setAttribute('position', new T.Float32BufferAttribute(rim, 3));
      r.computeVertexNormals();
      pieces.push(r);
    }
    return merged(pieces);
  }

  // ---------------------------------------------------------------- soft shapes (three-metal 2026-10-12)
  // Balls and sticks melted together with a smooth union (the shader answers' smin, Blender's metaballs): a heart from
  // three balls, a kidney, a cell with its organelles budding off, a tooth, a cloud, vessels joining a chamber. Meshed
  // with surface nets, normals from the field's gradient. The kernel runs JavaScriptCore without its JIT, so the field
  // is sampled only near the surface, each block of it with only the primitives near it, from one flat array, and
  // nothing is allocated per cell (a heart of four primitives builds in about 60 ms there).
  const SOFT_STRIDE = 13;           // per primitive: kind, a xyz, d xyz (b - a), 1/|d|², r1, r2, reach (max r), unused
  function softShape(o) {
    const list = [];
    const finite = v => typeof v === 'number' && isFinite(v);
    for (const b of (Array.isArray(o.balls) ? o.balls : []).slice(0, 64)) {
      const v = Array.isArray(b) ? b : b && typeof b === 'object' ? [...(Array.isArray(b.at) ? b.at : [0, 0, 0]), b.r] : null;
      if (v && v.length >= 4 && v.slice(0, 4).every(finite) && v[3] > 0) list.push([0, v[0], v[1], v[2], 0, 0, 0, 0, v[3], v[3]]);
    }
    for (const s of (Array.isArray(o.sticks) ? o.sticks : []).slice(0, 64)) {
      let v = null;
      if (Array.isArray(s) && s.length >= 7 && typeof s[0] === 'number') v = s;
      else if (Array.isArray(s) && Array.isArray(s[0]) && Array.isArray(s[1])) v = [...s[0], ...s[1], s[2], s[3]];
      else if (s && typeof s === 'object' && Array.isArray(s.from) && Array.isArray(s.to)) v = [...s.from, ...s.to, s.r, s.r2];
      if (!v || !v.slice(0, 7).every(finite) || v[6] <= 0) continue;
      const r2 = finite(v[7]) && v[7] > 0 ? v[7] : v[6];
      const dx = v[3] - v[0], dy = v[4] - v[1], dz = v[5] - v[2], dd = dx * dx + dy * dy + dz * dz;
      list.push([1, v[0], v[1], v[2], dx, dy, dz, dd > 1e-12 ? 1 / dd : 0, v[6], r2]);
    }
    if (!list.length) return null;
    const count = list.length, P = new Float64Array(count * SOFT_STRIDE);
    let meanRadius = 0;
    const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity];
    list.forEach((q, i) => {
      for (let j = 0; j < 10; j++) P[i * SOFT_STRIDE + j] = q[j];
      const reach = Math.max(q[8], q[9]);
      P[i * SOFT_STRIDE + 10] = reach;
      meanRadius += (q[8] + q[9]) / 2;
      for (let a = 0; a < 3; a++) {
        lo[a] = Math.min(lo[a], q[1 + a] - reach, q[1 + a] + q[4 + a] - reach);
        hi[a] = Math.max(hi[a], q[1 + a] + reach, q[1 + a] + q[4 + a] + reach);
      }
    });
    meanRadius /= count;
    const k = clamp(num(o.blend, meanRadius * 0.5), 0, meanRadius * 4), quarterK = k * 0.25, invK = k > 0 ? 1 / k : 0;
    // The smooth union of the listed primitives' distances (negative inside): all of them, or a block's own.
    const everyone = Int32Array.from({ length: count }, (_, i) => i);
    let only = everyone, onlyCount = count;
    const field = (x, y, z) => {
      let best = 1e9;
      for (let j = 0; j < onlyCount; j++) {
        const o = only[j] * SOFT_STRIDE;
        const px = x - P[o + 1], py = y - P[o + 2], pz = z - P[o + 3];
        let d;
        if (P[o] === 0) d = Math.sqrt(px * px + py * py + pz * pz) - P[o + 8];
        else {
          const dx = P[o + 4], dy = P[o + 5], dz = P[o + 6];
          let h = (px * dx + py * dy + pz * dz) * P[o + 7];
          h = h < 0 ? 0 : h > 1 ? 1 : h;
          const qx = px - dx * h, qy = py - dy * h, qz = pz - dz * h;
          d = Math.sqrt(qx * qx + qy * qy + qz * qz) - (P[o + 8] + (P[o + 9] - P[o + 8]) * h);
        }
        if (d < best + k) {
          if (k > 0 && best < 1e8) { let m = k - (best > d ? best - d : d - best); m = m > 0 ? m * invK : 0; best = (best < d ? best : d) - m * m * quarterK; }
          else if (d < best) best = d;
        }
      }
      return best;
    };
    const margin = k * 0.3 + meanRadius * 0.15;
    for (let a = 0; a < 3; a++) { lo[a] -= margin; hi[a] += margin; }
    // How much faster than its distance the field can change: 1 for balls (the smooth union keeps that), a little more
    // round a tapered stick.
    let rate = 1;
    for (const q of list) if (q[0] === 1 && q[7] > 0) rate = Math.max(rate, Math.sqrt(1 + (q[9] - q[8]) * (q[9] - q[8]) * q[7]));
    rate *= 1.05;
    // A block round (x, y, z) reaching `reach` from it: of the primitives its parent block kept, only those that could
    // come within the blend of the field anywhere in it are kept for it (each at most `rate` per unit closer there
    // than at its middle, the field at most that much higher).
    const lists = [0, 1, 2, 3, 4, 5].map(() => new Int32Array(count));
    const nearCentre = new Float64Array(count);
    const focus = (depth, x, y, z, reach) => {
      const from = depth === 0 ? everyone : lists[depth - 1], fromCount = depth === 0 ? count : listCounts[depth - 1];
      let best = 1e9;
      for (let j = 0; j < fromCount; j++) {
        const o = from[j] * SOFT_STRIDE, px = x - P[o + 1], py = y - P[o + 2], pz = z - P[o + 3];
        let d;
        if (P[o] === 0) d = Math.sqrt(px * px + py * py + pz * pz) - P[o + 8];
        else {
          let h = (px * P[o + 4] + py * P[o + 5] + pz * P[o + 6]) * P[o + 7];
          h = h < 0 ? 0 : h > 1 ? 1 : h;
          const qx = px - P[o + 4] * h, qy = py - P[o + 5] * h, qz = pz - P[o + 6] * h;
          d = Math.sqrt(qx * qx + qy * qy + qz * qz) - (P[o + 8] + (P[o + 9] - P[o + 8]) * h);
        }
        nearCentre[j] = d;
        if (d < best) best = d;
      }
      const into = lists[depth], cutoff = best + 2 * rate * reach + k;
      let n = 0;
      for (let j = 0; j < fromCount; j++) if (nearCentre[j] < cutoff) into[n++] = from[j];
      listCounts[depth] = n;
      only = into; onlyCount = n;
    };
    const listCounts = new Int32Array(6);
    // 48 cells on the long side.
    const span = Math.max(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]), step = span / 48;
    return surfaceNets(field, focus, lo, step, [0, 1, 2].map(a => Math.max(2, Math.ceil((hi[a] - lo[a]) / step) + 1)), rate);
  }
  // Naive surface nets: a point in every grid cell the surface crosses (the average of where it crosses the cell's
  // edges), and a quad round every grid edge it crosses, wound to face out (the field is negative inside). The field
  // is sampled where the surface can be, found by halving blocks: 8 cells wide, then 4, 2, 1; a block whose corners
  // all lie on one side, farther from the surface than half its diagonal (the field changes no faster than about its
  // distance, `rate`), can't hold it and is skipped. So only a band about two cells thick round the surface is
  // sampled, each point once, with only the primitives near its block (focus).
  function surfaceNets(field, focus, lo, step, n, rate) {
    const nx = n[0], ny = n[1], nz = n[2], cx = nx - 1, cy = ny - 1, cz = nz - 1;
    const values = new Float32Array(nx * ny * nz), sampled = new Uint8Array(nx * ny * nz);
    const sample = (x, y, z) => {
      const i = x + nx * (y + ny * z);
      if (!sampled[i]) { values[i] = field(lo[0] + x * step, lo[1] + y * step, lo[2] + z * step); sampled[i] = 1; }
      return values[i];
    };
    const cellPoint = new Int32Array(cx * cy * cz).fill(-1);
    const positions = [], normals = [], crossed = [], indices = [];
    const corner = new Float64Array(8);
    // The cube's 12 edges as pairs of corner numbers (corner c is at x = c & 1, y = (c >> 1) & 1, z = c >> 2).
    const EDGE_A = [0, 2, 4, 6, 0, 1, 4, 5, 0, 1, 2, 3], EDGE_B = [1, 3, 5, 7, 2, 3, 6, 7, 4, 5, 6, 7];
    const e = step * 0.5;
    // A cell the surface crosses: its point, and its normal from the field's gradient there.
    const crossCell = (x, y, z) => {
      let sx = 0, sy = 0, sz = 0, crossings = 0;
      for (let k = 0; k < 12; k++) {
        const a = EDGE_A[k], b = EDGE_B[k], va = corner[a], vb = corner[b];
        if ((va < 0) === (vb < 0)) continue;
        const t = va / (va - vb);
        sx += (a & 1) + ((b & 1) - (a & 1)) * t;
        sy += ((a >> 1) & 1) + (((b >> 1) & 1) - ((a >> 1) & 1)) * t;
        sz += (a >> 2) + ((b >> 2) - (a >> 2)) * t;
        crossings++;
      }
      const px = lo[0] + (x + sx / crossings) * step, py = lo[1] + (y + sy / crossings) * step, pz = lo[2] + (z + sz / crossings) * step;
      // The gradient from four samples at a tetrahedron's corners round the point.
      const a = field(px + e, py - e, pz - e), b = field(px - e, py - e, pz + e), c = field(px - e, py + e, pz - e), d = field(px + e, py + e, pz + e);
      const gx = a - b - c + d, gy = -a - b + c + d, gz = -a + b - c + d;
      const gl = Math.sqrt(gx * gx + gy * gy + gz * gz) || 1;
      cellPoint[x + cx * (y + cy * z)] = positions.length / 3;
      positions.push(px, py, pz);
      normals.push(gx / gl, gy / gl, gz / gl);
      crossed.push(x, y, z);
    };
    // A block of `size` cells from (x0, y0, z0), `depth` halvings below a root block.
    const visit = (x0, y0, z0, size, depth) => {
      const x1 = Math.min(x0 + size, cx), y1 = Math.min(y0 + size, cy), z1 = Math.min(z0 + size, cz);
      if (x0 >= x1 || y0 >= y1 || z0 >= z1) return;
      const dx = x1 - x0, dy = y1 - y0, dz = z1 - z0, halfDiagonal = 0.5 * step * Math.sqrt(dx * dx + dy * dy + dz * dz);
      // A block's own primitives (a single cell keeps its block's: the normals' samples stay inside it).
      if (size > 1) focus(depth, lo[0] + (x0 + x1) * 0.5 * step, lo[1] + (y0 + y1) * 0.5 * step, lo[2] + (z0 + z1) * 0.5 * step, halfDiagonal + step);
      let inside = 0, nearest = 1e9;
      for (let c = 0; c < 8; c++) {
        const v = sample(c & 1 ? x1 : x0, (c >> 1) & 1 ? y1 : y0, c >> 2 ? z1 : z0);
        corner[c] = v;
        if (v < 0) inside++;
        const m = v < 0 ? -v : v;
        if (m < nearest) nearest = m;
      }
      if (size === 1) { if (inside !== 0 && inside !== 8) crossCell(x0, y0, z0); return; }
      if ((inside === 0 || inside === 8) && nearest > halfDiagonal * rate) return;
      const half = size >> 1;
      for (let c = 0; c < 8; c++) visit(x0 + (c & 1) * half, y0 + ((c >> 1) & 1) * half, z0 + (c >> 2) * half, half, depth + 1);
    };
    const ROOT = 8;
    for (let z = 0; z < cz; z += ROOT) for (let y = 0; y < cy; y += ROOT) for (let x = 0; x < cx; x += ROOT) visit(x, y, z, ROOT, 0);
    const cell = (x, y, z) => (x < 0 || y < 0 || z < 0 || x >= cx || y >= cy || z >= cz) ? -1 : cellPoint[x + cx * (y + cy * z)];
    const quad = (a, b, c, d, outward) => {
      if (a < 0 || b < 0 || c < 0 || d < 0) return;
      if (outward) indices.push(a, b, c, a, c, d); else indices.push(a, c, b, a, d, c);
    };
    // A quad round every crossed grid edge: each starts at the low corner of a crossed cell (the cell holds it), whose
    // corners were all sampled. Along x the cells round it lie in the (y, z) plane, along y in (z, x), along z in
    // (x, y): counter-clockwise seen from the side the surface faces.
    for (let i = 0; i < crossed.length; i += 3) {
      const x = crossed[i], y = crossed[i + 1], z = crossed[i + 2], base = x + nx * (y + ny * z), here = values[base] < 0;
      if ((values[base + 1] < 0) !== here) quad(cell(x, y - 1, z - 1), cell(x, y, z - 1), cell(x, y, z), cell(x, y - 1, z), here);
      if ((values[base + nx] < 0) !== here) quad(cell(x - 1, y, z - 1), cell(x - 1, y, z), cell(x, y, z), cell(x, y, z - 1), here);
      if ((values[base + nx * ny] < 0) !== here) quad(cell(x - 1, y - 1, z), cell(x, y - 1, z), cell(x, y, z), cell(x - 1, y, z), here);
    }
    const g = new T.BufferGeometry();
    g.setAttribute('position', new T.Float32BufferAttribute(positions, 3));
    g.setAttribute('normal', new T.Float32BufferAttribute(normals, 3));
    g.setIndex(indices);
    return g;
  }

  // ---------------------------------------------------------------- the parts
  const SHAPES = {
    box(o) {
      const s = Array.isArray(o.size) ? o.size : [o.w, o.h, o.d];
      const w = pos(s[0], 1), h = pos(s[1], 1), d = pos(s[2], 1);
      const r = Math.min(num(o.r, num(o.bevel, 0)), Math.min(w, h, d) * 0.45);
      return r > 0.0005 ? new T.RoundedBoxGeometry(w, h, d, 3, r) : new T.BoxGeometry(w, h, d);
    },
    cyl(o) {
      const r = pos(o.r, 0.5), top = Math.max(0, num(o.top, r)), seg = clamp(Math.round(num(o.seg, 48)), 3, 128), h = pos(o.h, 1);
      const arc = clamp(num(o.arc, 360), 1, 360) * Math.PI / 180;
      const b = o.open === true ? 0 : bevelOf(o, Math.min(Math.min(r, top || r) * 0.45, h * 0.45));
      if (b > 0.0005) {
        // Its outline from the bottom's middle, round both rims (a top of 0 is a point, left sharp).
        const outline = [[0, -h / 2], [r, -h / 2], [top, h / 2], [0, h / 2]];
        return turnTo(latheOf(roundOutline(outline, top > 0 ? [1, 2] : [1], b), o), o.axis);
      }
      return turnTo(new T.CylinderGeometry(top, r, h, seg, 1, o.open === true, 0, arc), o.axis);
    },
    cone(o) {
      const r = pos(o.r, 0.5), h = pos(o.h, 1), b = bevelOf(o, Math.min(r, h) * 0.45);
      if (b > 0.0005) return turnTo(latheOf(roundOutline([[0, -h / 2], [r, -h / 2], [0, h / 2]], [1], b), o), o.axis);
      return turnTo(new T.ConeGeometry(r, h, clamp(Math.round(num(o.seg, 48)), 3, 128)), o.axis);
    },
    // A hollow cylinder: a pipe section, a cylinder wall, a ring with thickness.
    tube(o) {
      const r = pos(o.r, 1), inner = clamp(num(o.inner, r * 0.8), 0, r * 0.999), h = pos(o.h, 1);
      const b = bevelOf(o, Math.min((r - inner) * 0.45, h * 0.45));
      if (b > 0.0005) {
        const outline = [[inner, -h / 2 + b * 2], [inner, -h / 2], [r, -h / 2], [r, h / 2], [inner, h / 2], [inner, -h / 2 + b * 2]];
        return turnTo(latheOf(roundOutline(outline, [1, 2, 3, 4], b), o), o.axis);
      }
      const pts = [[inner, -h / 2], [r, -h / 2], [r, h / 2], [inner, h / 2], [inner, -h / 2]].map(([x, y]) => new T.Vector2(x, y));
      return turnTo(latheOf(pts, o), o.axis);
    },
    // A flow arrow: a tube along a smooth curve through points, ending in a cone (air through an engine, blood through
    // a heart, which way a gear turns). r is the shaft's radius; head, headR the cone's length and radius.
    arrow(o) {
      const pts = (Array.isArray(o.points) ? o.points : []).map(vec3).filter(Boolean).slice(0, 200);
      if (pts.length < 2) pts.splice(0, pts.length, new T.Vector3(0, 0, 0), new T.Vector3(1, 0, 0));
      const r = pos(o.r, 0.04), curve = new T.CatmullRomCurve3(pts, false, 'centripetal', 0.2), length = curve.getLength();
      const head = Math.min(pos(o.head, r * 5), length * 0.6), headR = pos(o.headR, r * 2.6);
      const tHead = curve.getUtoTmapping(Math.max(0, (length - head) / length));
      const shaftPoints = [];
      for (let i = 0; i <= 48; i++) shaftPoints.push(curve.getPoint(tHead * i / 48));
      const segments = clamp(Math.round(length / r * 2), 16, 400);
      const shaft = new T.TubeGeometry(new T.CatmullRomCurve3(shaftPoints, false, 'centripetal', 0.2), segments, r, 12, false);
      const base = curve.getPoint(tHead), tip = curve.getPoint(1);
      const direction = tip.clone().sub(base);
      if (direction.lengthSq() < 1e-12) direction.set(1, 0, 0);
      const cone = new T.ConeGeometry(headR, head, 24);
      cone.translate(0, head / 2, 0);
      cone.applyQuaternion(new T.Quaternion().setFromUnitVectors(new T.Vector3(0, 1, 0), direction.normalize()));
      cone.translate(base.x, base.y, base.z);
      const start = new T.SphereGeometry(r, 12, 8);
      start.translate(pts[0].x, pts[0].y, pts[0].z);
      return merged([shaft, cone, start]);
    },
    lathe(o) {
      const profile = (Array.isArray(o.profile) ? o.profile : []).map(vec2).filter(Boolean).map(p => new T.Vector2(Math.max(0, p.x), p.y));
      const pts = profile.length >= 2 ? profile : [[0, 0], [1, 0], [1, 1], [0, 1]].map(([x, y]) => new T.Vector2(x, y));
      return turnTo(new T.LatheGeometry(pts.slice(0, 400), clamp(Math.round(num(o.seg, 64)), 8, 128)), o.axis);
    },
    sphere(o) {
      const r = pos(o.r, 0.5);
      // dome: true keeps the top half (a dome, a cap, an eye's cornea).
      const theta = o.dome === true ? Math.PI / 2 : Math.PI;
      return turnTo(new T.SphereGeometry(r, clamp(Math.round(num(o.seg, 48)), 8, 128), clamp(Math.round(num(o.seg, 48) * 2 / 3), 6, 96), 0, Math.PI * 2, 0, theta), o.axis);
    },
    torus(o) {
      const arc = clamp(num(o.arc, 360), 1, 360) * Math.PI / 180;
      // three's torus lies in the xy plane (its hole along z); a Mate torus lies flat, its hole along y.
      return turnTo(new T.TorusGeometry(pos(o.r, 1), pos(o.tube, 0.2), 24, 72, arc), o.axis || 'y', 'z');
    },
    capsule(o) {
      return turnTo(new T.CapsuleGeometry(pos(o.r, 0.3), Math.max(0, num(o.h, 1)), 8, 24), o.axis);
    },
    // A tube along a smooth curve through points: a hose, a wire, a blood vessel, a strand, a pipe run.
    pipe(o) {
      const pts = (Array.isArray(o.points) ? o.points : []).map(vec3).filter(Boolean).slice(0, 200);
      if (pts.length < 2) pts.splice(0, pts.length, new T.Vector3(0, 0, 0), new T.Vector3(0, 1, 0));
      const closed = o.closed === true && pts.length >= 3;
      const curve = new T.CatmullRomCurve3(pts, closed, 'centripetal', 0.2);
      const segments = clamp(pts.length * 24, 24, 2400);
      return new T.TubeGeometry(curve, segments, pos(o.r, 0.1), clamp(Math.round(num(o.seg, 16)), 4, 32), closed);
    },
    spring(o) {
      const r = pos(o.r, 0.5), h = pos(o.h, 2), coils = clamp(num(o.coils, 8), 0.25, 60);
      class Helix extends T.Curve {
        getPoint(t, v = new T.Vector3()) { const a = t * coils * Math.PI * 2; return v.set(r * Math.cos(a), -h / 2 + h * t, r * Math.sin(a)); }
      }
      return turnTo(new T.TubeGeometry(new Helix(), Math.round(clamp(coils * 40, 16, 2400)), pos(o.wire, 0.06), 10, false), o.axis);
    },
    // A spur gear lying in the xy plane (its axle along z), `teeth` round its rim, an axle hole when `hole` > 0.
    gear(o) {
      const teeth = clamp(Math.round(num(o.teeth, 16)), 6, 200), r = pos(o.r, 1), depth = clamp(num(o.tooth, r * 0.14), r * 0.02, r * 0.5);
      const width = pos(o.w, 0.3), s = new T.Shape();
      for (let i = 0; i < teeth * 4; i++) {
        const a = (i / (teeth * 4)) * Math.PI * 2, rr = (i % 4 < 2) ? r : r - depth;
        const x = rr * Math.cos(a), y = rr * Math.sin(a);
        if (i) s.lineTo(x, y); else s.moveTo(x, y);
      }
      const hole = num(o.hole, 0);
      if (hole > 0 && hole < r - depth) { const p = new T.Path(); p.absarc(0, 0, hole, 0, Math.PI * 2, true); s.holes.push(p); }
      const bevel = typeof o.bevel === 'number' ? Math.min(Math.max(0, o.bevel), width * 0.45, depth * 0.45) : Math.min(0.02, width * 0.2);
      const g = new T.ExtrudeGeometry(s, { depth: width, bevelEnabled: true, bevelSize: bevel, bevelThickness: bevel, bevelSegments: 2, curveSegments: 4 });
      g.translate(0, 0, -width / 2);
      return turnTo(g, o.axis || 'z', 'z');
    },
    // A flat shape pushed into depth: [[x, y], ...] (or SVG path data in `d`), lying in the xy plane, depth along z.
    extrude(o) {
      const depth = pos(o.depth, 0.3), shapes = shapesFrom(o);
      const bevel = o.bevel === false ? 0 : typeof o.bevel === 'number' ? Math.min(Math.max(0, o.bevel), depth * 0.45) : Math.min(0.015, depth * 0.2);
      const g = new T.ExtrudeGeometry(shapes, { depth, bevelEnabled: bevel > 0, bevelSize: bevel, bevelThickness: bevel, bevelSegments: typeof o.bevel === 'number' ? 3 : 2, curveSegments: 12 });
      g.translate(0, 0, -depth / 2);
      return turnTo(g, o.axis || 'z', 'z');
    },
    // An organic lump: a cell, an organelle, a folded protein, a rock, a cloud. Given balls ([x, y, z, r]) and sticks
    // ([x1, y1, z1, x2, y2, z2, r, r2]), it is those melted together, blend wide (softShape).
    blob(o) {
      const soft = (Array.isArray(o.balls) && o.balls.length) || (Array.isArray(o.sticks) && o.sticks.length) ? softShape(o) : null;
      if (soft) return soft;
      const g = T.mergeVertices(new T.IcosahedronGeometry(1, clamp(Math.round(num(o.detail, 5)), 2, 8)).deleteAttribute('normal').deleteAttribute('uv'));
      const position = g.attributes.position, v = new T.Vector3();
      const seed = num(o.seed, 1), lumps = clamp(num(o.lumps, 0.12), 0, 0.22);
      const size = Array.isArray(o.size) ? o.size : [num(o.r, 1), num(o.r, 1) * num(o.squash, 1), num(o.r, 1)];
      const sx = pos(size[0], 1), sy = pos(size[1], 1), sz = pos(size[2], 1);
      for (let i = 0; i < position.count; i++) {
        v.fromBufferAttribute(position, i);
        const n = Math.sin(v.x * 3.1 + seed) * Math.sin(v.y * 2.7 + seed * 1.7) * Math.sin(v.z * 3.3 + seed * 0.6);
        const k = 1 + lumps * n;
        position.setXYZ(i, v.x * sx * k, v.y * sy * k, v.z * sz * k);
      }
      g.computeVertexNormals();
      return g;
    },
    // A faceted solid: a crystal, a gem, a die, an atom model's cage. faces 4, 6, 8, 12 or 20.
    poly(o) {
      const r = pos(o.r, 0.5), detail = clamp(Math.round(num(o.detail, 0)), 0, 3), faces = Math.round(num(o.faces, 20));
      const g = faces === 4 ? new T.TetrahedronGeometry(r, detail) : faces === 6 ? new T.BoxGeometry(r * 1.15, r * 1.15, r * 1.15)
        : faces === 8 ? new T.OctahedronGeometry(r, detail) : faces === 12 ? new T.DodecahedronGeometry(r, detail) : new T.IcosahedronGeometry(r, detail);
      return turnTo(g, o.axis);
    },
    // A surface z = f(u, v) the engine sampled into a grid of points (rows of [x, y, z]).
    surface(o) {
      const rows = (Array.isArray(o.grid) ? o.grid : []).map(row => (Array.isArray(row) ? row : []).map(vec3)).filter(row => row.length >= 2 && row.every(Boolean));
      const columns = rows.length ? Math.min(...rows.map(r => r.length)) : 0;
      if (rows.length < 2 || columns < 2) return new T.PlaneGeometry(1, 1);
      const positions = [], uvs = [], indices = [];
      for (let j = 0; j < rows.length; j++) for (let i = 0; i < columns; i++) {
        const p = rows[j][i]; positions.push(p.x, p.y, p.z); uvs.push(i / (columns - 1), j / (rows.length - 1));
      }
      for (let j = 0; j < rows.length - 1; j++) for (let i = 0; i < columns - 1; i++) {
        const a = j * columns + i, b = a + columns;
        indices.push(a, b, a + 1, b, b + 1, a + 1);
      }
      const g = new T.BufferGeometry();
      g.setAttribute('position', new T.Float32BufferAttribute(positions, 3));
      g.setAttribute('uv', new T.Float32BufferAttribute(uvs, 2));
      g.setIndex(indices);
      g.computeVertexNormals();
      return g;
    },
  };
  // The same parts under the names the old scene3d() and three.js use.
  SHAPES.cylinder = SHAPES.cyl;

  // SVG path data (M L H V C S Q T A Z, absolute and relative) or a point list -> three.js Shapes (holes by winding).
  function shapesFrom(o) {
    if (typeof o.d === 'string' && o.d.trim()) {
      const unit = num(o.unit, 0.01), path = new T.ShapePath();
      parsePathData(o.d.slice(0, 20000), path, unit);
      const shapes = path.toShapes(true);
      if (shapes.length) return shapes;
    }
    const pts = (Array.isArray(o.shape) ? o.shape : []).map(vec2).filter(Boolean).slice(0, 2000);
    const s = new T.Shape(pts.length >= 3 ? pts : [new T.Vector2(0, 0), new T.Vector2(1, 0), new T.Vector2(1, 1)]);
    for (const hole of Array.isArray(o.holes) ? o.holes : []) {
      const hp = (Array.isArray(hole) ? hole : []).map(vec2).filter(Boolean);
      if (hp.length >= 3) s.holes.push(new T.Path(hp));
    }
    return [s];
  }
  // y is flipped: SVG's y runs down the screen, a shape's y runs up.
  function parsePathData(d, path, unit) {
    const tokens = d.match(/[a-zA-Z]|-?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?/g) || [];
    let i = 0, cmd = '', x = 0, y = 0, sx = 0, sy = 0, lastCx = null, lastCy = null, lastKind = '';
    const P = (px, py) => [px * unit, -py * unit];
    const nextNum = () => { const t = tokens[i++]; return t === undefined ? NaN : parseFloat(t); };
    const isNum = () => i < tokens.length && !/^[a-zA-Z]$/.test(tokens[i]);
    let guard = 0;
    while (i < tokens.length && guard++ < 20000) {
      if (/^[a-zA-Z]$/.test(tokens[i])) cmd = tokens[i++];
      else if (!cmd) { i++; continue; }
      const rel = cmd === cmd.toLowerCase(), C = cmd.toUpperCase();
      const ax = v => rel ? x + v : v, ay = v => rel ? y + v : v;
      if (C === 'Z') { path.currentPath && path.currentPath.closePath(); x = sx; y = sy; lastKind = 'Z'; continue; }
      if (!isNum()) continue;
      if (C === 'M') {
        x = ax(nextNum()); y = ay(nextNum()); sx = x; sy = y; path.moveTo(...P(x, y)); cmd = rel ? 'l' : 'L'; lastKind = 'M';
      } else if (C === 'L') { x = ax(nextNum()); y = ay(nextNum()); path.lineTo(...P(x, y)); lastKind = 'L';
      } else if (C === 'H') { x = rel ? x + nextNum() : nextNum(); path.lineTo(...P(x, y)); lastKind = 'L';
      } else if (C === 'V') { y = rel ? y + nextNum() : nextNum(); path.lineTo(...P(x, y)); lastKind = 'L';
      } else if (C === 'C' || C === 'S') {
        let c1x, c1y;
        if (C === 'C') { c1x = ax(nextNum()); c1y = ay(nextNum()); }
        else { c1x = lastKind === 'C' && lastCx !== null ? 2 * x - lastCx : x; c1y = lastKind === 'C' && lastCy !== null ? 2 * y - lastCy : y; }
        const c2x = ax(nextNum()), c2y = ay(nextNum()), ex = ax(nextNum()), ey = ay(nextNum());
        path.bezierCurveTo(...P(c1x, c1y), ...P(c2x, c2y), ...P(ex, ey));
        lastCx = c2x; lastCy = c2y; x = ex; y = ey; lastKind = 'C';
      } else if (C === 'Q' || C === 'T') {
        let qx, qy;
        if (C === 'Q') { qx = ax(nextNum()); qy = ay(nextNum()); }
        else { qx = lastKind === 'Q' && lastCx !== null ? 2 * x - lastCx : x; qy = lastKind === 'Q' && lastCy !== null ? 2 * y - lastCy : y; }
        const ex = ax(nextNum()), ey = ay(nextNum());
        path.quadraticCurveTo(...P(qx, qy), ...P(ex, ey));
        lastCx = qx; lastCy = qy; x = ex; y = ey; lastKind = 'Q';
      } else if (C === 'A') {
        const rx = Math.abs(nextNum()), ry = Math.abs(nextNum()), rot = nextNum() * Math.PI / 180, large = nextNum(), sweep = nextNum();
        const ex = ax(nextNum()), ey = ay(nextNum());
        arcTo(path, x, y, rx, ry, rot, large, sweep, ex, ey, P);
        x = ex; y = ey; lastKind = 'A';
      } else { i++; }
      if (![x, y].every(isFinite)) break;
    }
  }
  // SVG's endpoint arc as short cubic Béziers (the SVG spec's centre parameterisation).
  function arcTo(path, x1, y1, rx, ry, phi, large, sweep, x2, y2, P) {
    if (!rx || !ry) { path.lineTo(...P(x2, y2)); return; }
    const cos = Math.cos(phi), sin = Math.sin(phi);
    const dx = (x1 - x2) / 2, dy = (y1 - y2) / 2, x1p = cos * dx + sin * dy, y1p = -sin * dx + cos * dy;
    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) { rx *= Math.sqrt(lambda); ry *= Math.sqrt(lambda); }
    const sign = (large ? 1 : 0) === (sweep ? 1 : 0) ? -1 : 1;
    const num_ = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p, den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    const coef = sign * Math.sqrt(Math.max(0, num_ / (den || 1)));
    const cxp = coef * (rx * y1p) / ry, cyp = coef * -(ry * x1p) / rx;
    const cx = cos * cxp - sin * cyp + (x1 + x2) / 2, cy = sin * cxp + cos * cyp + (y1 + y2) / 2;
    const angle = (ux, uy, vx, vy) => Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    let t1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry), dt = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep && dt > 0) dt -= 2 * Math.PI; else if (sweep && dt < 0) dt += 2 * Math.PI;
    const n = Math.max(1, Math.ceil(Math.abs(dt) / (Math.PI / 2))), step = dt / n, k = 4 / 3 * Math.tan(step / 4);
    for (let s = 0; s < n; s++) {
      const a = t1 + s * step, b = a + step;
      const e = (t) => [cx + rx * Math.cos(t) * cos - ry * Math.sin(t) * sin, cy + rx * Math.cos(t) * sin + ry * Math.sin(t) * cos];
      const d = (t) => [-rx * Math.sin(t) * cos - ry * Math.cos(t) * sin, -rx * Math.sin(t) * sin + ry * Math.cos(t) * cos];
      const [ax_, ay_] = e(a), [bx, by] = e(b), [dax, day] = d(a), [dbx, dby] = d(b);
      path.bezierCurveTo(...P(ax_ + k * dax, ay_ + k * day), ...P(bx - k * dbx, by - k * dby), ...P(bx, by));
    }
  }

  // ---------------------------------------------------------------- packing for the Metal stage
  // Up to `max` points that frame the part: its extremes on every axis, then evenly spread vertices.
  function framingSamples(p, max) {
    const n = p.length / 3;
    if (n <= max) return new Float32Array(p);
    const picks = new Set();
    for (let axis = 0; axis < 3; axis++) {
      let lo = 0, hi = 0;
      for (let i = 1; i < n; i++) { if (p[i * 3 + axis] < p[lo * 3 + axis]) lo = i; if (p[i * 3 + axis] > p[hi * 3 + axis]) hi = i; }
      picks.add(lo); picks.add(hi);
    }
    const stride = n / (max - picks.size);
    for (let k = 0; picks.size < max && k * stride < n; k++) picks.add(Math.floor(k * stride));
    const out = new Float32Array(picks.size * 3); let o = 0;
    for (const i of picks) { out[o++] = p[i * 3]; out[o++] = p[i * 3 + 1]; out[o++] = p[i * 3 + 2]; }
    return out;
  }
  function pack(g) {
    if (!g.attributes.normal) g.computeVertexNormals();
    const position = g.attributes.position.array;
    const count = g.attributes.position.count;
    if (count > MAX_VERTICES) throw new Error('part too detailed (' + count + ' vertices)');
    let indices;
    if (g.index) indices = g.index.array instanceof Uint32Array ? g.index.array : Uint32Array.from(g.index.array);
    else { indices = new Uint32Array(count); for (let i = 0; i < count; i++) indices[i] = i; }
    return {
      positions: position instanceof Float32Array ? position : Float32Array.from(position),
      normals: g.attributes.normal.array,
      uvs: g.attributes.uv ? g.attributes.uv.array : null,
      indices,
      samples: framingSamples(position, 600),
    };
  }

  globalThis.mateThreeKinds = Object.keys(SHAPES);
  globalThis.mateThreeBuild = function (kind, recipeJSON) {
    const make = SHAPES[kind];
    if (!make) throw new Error('unknown 3D part "' + kind + '"');
    const recipe = JSON.parse(recipeJSON || '{}');
    let g = make(recipe);
    // thick: a wall that thick (Blender's Solidify): a sheet gets a rim, a closed part goes hollow.
    const thick = num(recipe.thick, 0);
    if (thick > 0) g = solidify(g, Math.min(thick, 10));
    // An uneven scale, then a mirror (figure() mirror: 'x' sends its copy with mirror [-1, 1, 1]); a negative one
    // turns the part inside out, so its triangles are wound back.
    const stretch = vec3(recipe.stretch), mirror = vec3(recipe.mirror);
    const sx = (stretch ? stretch.x || 1 : 1) * (mirror ? Math.sign(mirror.x) || 1 : 1);
    const sy = (stretch ? stretch.y || 1 : 1) * (mirror ? Math.sign(mirror.y) || 1 : 1);
    const sz = (stretch ? stretch.z || 1 : 1) * (mirror ? Math.sign(mirror.z) || 1 : 1);
    if (sx !== 1 || sy !== 1 || sz !== 1) g.scale(sx, sy, sz);
    if (sx * sy * sz < 0) rewind(g);
    return pack(g);
  };
})();
