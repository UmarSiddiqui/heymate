// Three.js supplies scene math and recovered mesh generation only. No WebGL context is created.
(function () {
  'use strict';
  let serial = 0;
  const active = new Map();
  const post = body => window.webkit.messageHandlers.heymate.postMessage({ type: 'metal3d', body });
  class MetalStage {
    constructor(canvas) {
      this.canvas = canvas;
      this.token = (globalThis.__heymateMetalSession || 'metal') + '-' + (++serial);
      this.shadowMap = {};
      this.sent = new Set();
      this.inFlight = false;
      active.set(this.token, this);
    }
    setPixelRatio() {}
    setSize() {}
    setVisible(visible) {
      if (!visible && !this.hidden) post({ op: 'hide', id: this.token });
      this.hidden = !visible;
    }
    dispose() {
      active.delete(this.token);
      post({ op: 'remove', id: this.token });
    }
    render(scene, camera) {
      scene.updateMatrixWorld(true); camera.updateMatrixWorld(true);
      // One outstanding GPU frame per stage. Geometry never enters an unbounded message queue.
      if (this.inFlight || !this.stage) return;
      const st = this.stage, meshes = [], geometries = [];
      st.pivot.traverseVisible(mesh => {
        if (!mesh.isMesh) return;
        const g = mesh.geometry, m = mesh.material, spec = mesh.userData.material || {};
        if (!g || !m || m.opacity <= 0) return;
        if (!this.sent.has(g.uuid)) {
          geometries.push({ id: g.uuid, positions: Array.from(g.attributes.position.array),
            normals: Array.from(g.attributes.normal.array), uvs: g.attributes.uv ? Array.from(g.attributes.uv.array) : [],
            colors: g.attributes.color ? Array.from(g.attributes.color.array) : [],
            indices: g.index ? Array.from(g.index.array) : [] });
          this.sent.add(g.uuid);
        }
        const normal = new THREE.Matrix3().getNormalMatrix(mesh.matrixWorld).elements;
        const bands = (spec.bands || spec.colors || []).slice(0, 16).map(c => new THREE.Color(c).toArray());
        const cut = Array.isArray(spec.cut) ? spec.cut.slice(0, 4) : [0, 0, 0, 0];
        if (spec.cutFacing) {
          const n = camera.position.clone().sub(st.centre).normalize();
          cut.splice(0, 4, n.x, n.y, n.z, n.dot(st.centre));
        }
        meshes.push({ geometry: g.uuid, model: mesh.matrixWorld.toArray(), normal: Array.from(normal),
          color: m.color.toArray(), emissive: m.emissive.clone().multiplyScalar(m.emissiveIntensity).toArray(),
          roughness: m.roughness, metalness: m.metalness, opacity: m.opacity,
          vertexColors: !!g.attributes.color, flat: !!spec.flat, double: !!spec.double, bands, cut });
      });
      const r = this.canvas.getBoundingClientRect();
      if (!(r.width > 0 && r.height > 0)) return;
      const labels = st.labelList.filter(l => l.div.style.opacity === '1').map(l => ({
        text: l.data.text, x: parseFloat(l.div.style.left), y: parseFloat(l.div.style.top), side: l.side,
        ax: l.anchorX, ay: l.anchorY, size: Math.round((l.data.size || 19) * 0.8)
      }));
      const vp = new THREE.Matrix4().multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse);
      this.inFlight = true;
      post({ op: 'frame', id: this.token, rect: [r.left, r.top, r.width, r.height],
        viewProjection: vp.toArray(), eye: camera.position.toArray(), illustrated: st.look === 'illustrated',
        ink: new THREE.Color(st.ink).toArray(), geometries, meshes, labels });
    }
  }
  globalThis.MateMetal = { create: canvas => new MetalStage(canvas),
    presented(id, error) {
      const renderer = active.get(id);
      if (renderer) renderer.inFlight = false;
      if (error) console.error('[Metal3D]', error);
    }
  };
})();
