// What the 3D part builder (HeyMate/mate-three-parts.js) takes from three.js, and nothing else. Anything added here
// must be used there: scripts/three_parts_tests.mjs checks the two lists match.
export {
  BoxGeometry, BufferGeometry, CapsuleGeometry, CatmullRomCurve3, Curve, DodecahedronGeometry, ExtrudeGeometry,
  Float32BufferAttribute, IcosahedronGeometry, OctahedronGeometry, Path, PlaneGeometry, Quaternion, Shape, ShapePath,
  ShapeUtils, SphereGeometry, TetrahedronGeometry, Vector2, Vector3,
} from 'three';
export { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
export { SimplexNoise } from 'three/addons/math/SimplexNoise.js';
export { mergeVertices } from 'three/addons/utils/BufferGeometryUtils.js';
