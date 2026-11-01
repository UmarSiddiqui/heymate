# HeyMate "Tide" mate: a matte ceramic pebble with capsule eyes, built from the brand blob.
# Renders a 10 s performance (300 frames @ 30 fps) as transparent PNGs with a shadow catcher.
#   Blender -b -P scripts/mate-character.py -- <out_dir> [preview]
import bpy, math, sys
from mathutils import Vector

argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
OUT = argv[0] if argv else '/tmp/mate'
PREVIEW = len(argv) > 1 and argv[1] == 'preview'

bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = 'CYCLES'
sc.cycles.device = 'GPU'
prefs = bpy.context.preferences.addons['cycles'].preferences
prefs.compute_device_type = 'METAL'
prefs.get_devices()
if hasattr(prefs, 'kernel_optimization_level'): prefs.kernel_optimization_level = 'OFF'  # optimized-kernel compile crashed Blender 5.2 on Metal
for d in prefs.devices: d.use = True
sc.cycles.samples = 24 if PREVIEW else 40
sc.cycles.use_denoising = True
sc.render.resolution_x = sc.render.resolution_y = 1080
sc.render.film_transparent = True
sc.render.image_settings.file_format = 'PNG'
sc.render.image_settings.color_mode = 'RGBA'
sc.view_settings.view_transform = 'AgX'
sc.view_settings.look = 'AgX - Medium High Contrast'
sc.render.fps = 30
sc.frame_start, sc.frame_end = 1, 300

def hexcol(h, a=1.0):
	h = h.lstrip('#'); c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
	return [x ** 2.2 for x in c] + [a]

# ---------- materials
def mat(name, color, rough, coat=0.0, sss=0.0):
	m = bpy.data.materials.new(name); m.use_nodes = True
	b = m.node_tree.nodes['Principled BSDF']
	b.inputs['Base Color'].default_value = hexcol(color)
	b.inputs['Roughness'].default_value = rough
	b.inputs['Coat Weight'].default_value = coat
	b.inputs['Coat Roughness'].default_value = 0.35
	b.inputs['Subsurface Weight'].default_value = sss
	b.inputs['Subsurface Radius'].default_value = (0.3, 0.25, 0.2)
	b.inputs['Subsurface Scale'].default_value = 0.08
	return m

ceramic = mat('Ceramic tide', '#8FC3BB', 0.5, coat=0.15, sss=0.12)
ink = mat('Eye ink', '#071512', 0.12, coat=0.6)

# ---------- body: brand blob as a soft pebble
bpy.ops.mesh.primitive_uv_sphere_add(segments=96, ring_count=64, radius=1)
body = bpy.context.object; body.name = 'Mate body'
for v in body.data.vertices:
	x, y, z = v.co
	# asymmetric pebble: wider at right, flatter base, slight lean like the 2D mark
	sq = lambda c, n=2.7: math.copysign(abs(c) ** (2 / n), c)  # superellipse: rounder-square pebble
	x, y, z = sq(x), sq(y, 2.2), sq(z)
	v.co.x = x * (1.12 + 0.06 * z)
	v.co.y = y * 0.78
	v.co.z = z * (0.92 if z > 0 else 0.8) + 0.07 * x * z - 0.04 * x
bpy.ops.object.shade_smooth()
sub = body.modifiers.new('Subsurf', 'SUBSURF'); sub.levels = 1; sub.render_levels = 2
body.data.materials.append(ceramic)

# ---------- eyes: tilted capsules seated on the front of the pebble
eyes = []
for i, (ex, tilt, h) in enumerate([(-0.3, 9, 0.46), (0.3, 7, 0.4)]):
	bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=32, radius=1)
	e = bpy.context.object; e.name = f'Eye {i}'
	e.scale = (0.1, 0.035, h / 2)
	e.location = (ex, -0.765, 0.14)
	e.rotation_euler = (0, math.radians(tilt), 0)
	bpy.ops.object.shade_smooth()
	e.data.materials.append(ink)
	e.parent = body
	eyes.append(e)

# ---------- shadow catcher floor + studio
bpy.ops.mesh.primitive_plane_add(size=30, location=(0, 0, -0.9))
floor = bpy.context.object; floor.name = 'Shadow catcher'; floor.is_shadow_catcher = True

def area(name, loc, rot, size, power, color):
	bpy.ops.object.light_add(type='AREA', location=loc, rotation=[math.radians(r) for r in rot])
	l = bpy.context.object; l.name = name
	l.data.size = size; l.data.energy = power; l.data.color = hexcol(color)[:3]
	return l

area('Key soft', (-3.2, -3.4, 4.2), (48, 0, -40), 4.0, 520, '#FFF4EA')
area('Rim cool', (3.4, 2.8, 2.6), (-60, 0, 130), 2.5, 700, '#A8CBFA')
area('Fill low', (2.8, -4, 0.3), (85, 0, 35), 5, 160, '#EAF2FE')
w = bpy.data.worlds.new('World'); sc.world = w; w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = hexcol('#0B111C')
w.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.35

bpy.ops.object.camera_add(location=(0, -7.2, 0.55), rotation=(math.radians(88), 0, 0))
cam = bpy.context.object; sc.camera = cam; cam.data.lens = 70
cam.data.dof.use_dof = True; cam.data.dof.focus_object = body; cam.data.dof.aperture_fstop = 4

# ---------- performance
def key(obj, f, **props):
	for k, v in props.items():
		setattr(obj, k, v); obj.keyframe_insert(k, frame=f)

def blink(f):
	for e in eyes:
		sy = e.scale.z
		key(e, f - 3, scale=(e.scale.x, e.scale.y, sy))
		key(e, f, scale=(e.scale.x * 1.1, e.scale.y, sy * 0.12))
		key(e, f + 4, scale=(e.scale.x, e.scale.y, sy))

R = math.radians
# enter: rise from below with squash and stretch
key(body, 1, location=(0, 0, -2.6), scale=(0.9, 0.9, 1.15), rotation_euler=(0, 0, 0))
key(body, 16, location=(0, 0, 0.25), scale=(0.94, 0.94, 1.1))
key(body, 24, location=(0, 0, 0), scale=(1.08, 1.08, 0.88))
key(body, 32, scale=(0.98, 0.98, 1.03))
key(body, 40, location=(0, 0, 0), scale=(1, 1, 1))
blink(56)
# listen: tilt and gentle bobs
key(body, 70, rotation_euler=(0, 0, 0), location=(0, 0, 0))
key(body, 86, rotation_euler=(0, R(-7), R(-6)), location=(0, 0, 0.05))
key(body, 104, location=(0, 0, -0.02))
key(body, 120, rotation_euler=(0, R(-7), R(-6)), location=(0, 0, 0.04))
# glance right toward the content
key(body, 134, rotation_euler=(0, R(3), R(24)), location=(0.05, 0, 0.02))
for e, x0 in zip(eyes, (-0.3, 0.3)):
	key(e, 120, location=(x0, -0.765, 0.14))
	key(e, 134, location=(x0 + 0.08, -0.75, 0.16))
blink(176)
# back to camera, delighted squint + hop
for e, x0 in zip(eyes, (-0.3, 0.3)):
	key(e, 206, location=(x0 + 0.08, -0.75, 0.16), scale=tuple(e.scale))
	key(e, 220, location=(x0, -0.765, 0.16), scale=(e.scale.x * 1.2, e.scale.y, e.scale.z * 0.42))
	key(e, 252, scale=(e.scale.x * 1.2, e.scale.y, e.scale.z * 0.42))
	key(e, 262, scale=(0.1, 0.035, (0.46 if e.name == 'Eye 0' else 0.4) / 2))
key(body, 206, rotation_euler=(0, R(3), R(24)), location=(0.05, 0, 0.02), scale=(1, 1, 1))
key(body, 216, rotation_euler=(0, 0, 0), location=(0, 0, 0), scale=(1.07, 1.07, 0.9))
key(body, 226, location=(0, 0, 0.32), scale=(0.95, 0.95, 1.07))
key(body, 236, location=(0, 0, 0), scale=(1.06, 1.06, 0.92))
key(body, 246, scale=(1, 1, 1))
# idle float to the end
key(body, 270, location=(0, 0, 0.06))
key(body, 300, location=(0, 0, 0))
blink(284)

for o in [body] + eyes:
	if o.animation_data and o.animation_data.action:
		for fc in getattr(o.animation_data.action, 'fcurves', []):
			for kp in fc.keyframe_points: kp.interpolation = 'BEZIER'; kp.easing = 'AUTO'

bpy.ops.wm.save_as_mainfile(filepath=f'{OUT}/mate-character.blend')
if PREVIEW:
	for f in (40, 100, 150, 225):
		sc.frame_set(f); sc.render.filepath = f'{OUT}/preview-{f:03d}.png'
		bpy.ops.render.render(write_still=True)
else:
	sc.render.filepath = f'{OUT}/frames/mate-'
	sc.render.use_overwrite = False  # resume after a crash
	bpy.ops.render.render(animation=True)
