"""Render portrait gaze layers without modifying the source .blend files.
Run: Blender --background --python art/characters/blender/render_portrait_gaze.py
"""
import bpy
import itertools
import json
from pathlib import Path
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

ROOT = Path(__file__).resolve().parents[3]
SOURCE = Path(__file__).resolve().parent
ASSETS = ROOT / 'heymate/HeyMate/Assets.xcassets'
COLORS = {
    'hair': {'tide': (.022, .085, .115), 'copper': (.31, .075, .025), 'lilac': (.28, .15, .42)},
    'skin': {'sand': (.83, .51, .32), 'caramel': (.62, .30, .17), 'umber': (.27, .105, .06)},
    'eye': {'sea': (.05, .40, .43), 'amber': (.57, .27, .035), 'violet': (.26, .17, .57)},
}
MATERIALS = {'hair': 'Deep tide • hair', 'skin': 'Warm caramel • skin', 'eye': 'Sea glass • iris'}
EYE_PARTS = ('Iris ', 'Pupil ', 'Eye light ')
metadata = {}


def palette(pack, hair, skin, eye='sea'):
    for kind, key in [('hair', hair), ('skin', skin), ('eye', eye)]:
        color = COLORS[kind][key]
        if pack == 'Nova' and kind == 'hair' and key == 'tide':
            color = (.018, .035, .065)
        material = bpy.data.materials[MATERIALS[kind]]
        material.diffuse_color = (*color, 1)
        material.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (*color, 1)


def render(name):
    directory = ASSETS / (name + '.imageset')
    directory.mkdir(parents=True, exist_ok=True)
    bpy.context.scene.render.filepath = str(directory / 'character.png')
    bpy.ops.render.render(write_still=True)
    (directory / 'Contents.json').write_text(json.dumps({
        'images': [{'filename': 'character.png', 'idiom': 'universal'}],
        'info': {'author': 'xcode', 'version': 1},
    }, indent=2) + '\n')
    print('PORTRAIT_GAZE_RENDERED ' + name, flush=True)


for pack in ['Milo', 'Nova']:
    # Match the files and camera that produced the existing head portraits.
    bpy.ops.wm.open_mainfile(filepath=str(SOURCE / ('Milo.blend' if pack == 'Milo' else 'Nova-Classic.blend')))
    scene = bpy.context.scene
    scene.frame_set(1)
    scene.cycles.samples = 16
    scene.render.resolution_x = 550
    scene.render.resolution_y = 600
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    head = bpy.data.objects['CTRL_head']
    camera = scene.camera
    camera.location = (.25, -10, 2.7)
    camera.rotation_euler = (Vector((0, 0, 2.39)) - camera.location).to_track_quat('-Z', 'Y').to_euler()
    camera.data.ortho_scale = 1.95
    if pack == 'Nova':
        for obj in scene.objects:
            if obj.name.startswith('Nova bun • coil 0'):
                obj.location.z = .60
                obj.scale = (.27, .25, .22)
            if obj.name.startswith('Nova bun • coil 1'):
                obj.location.z = .76
                obj.scale = (.19, .19, .17)
    bpy.context.view_layer.update()
    centers = []
    for side in [-1, 1]:
        point = world_to_camera_view(scene, camera, bpy.data.objects['Eye white ' + str(side)].matrix_world.translation)
        centers.append([point.x, 1-point.y])
    metadata[pack] = {'eyeCenters': centers, 'ellipseWidth': .526/1.95, 'ellipseHeight': .63/(1.95*600/550)}

    for eye in COLORS['eye']:
        palette(pack, 'tide', 'caramel', eye)
        for obj in scene.objects:
            if obj.type in ['MESH', 'CURVE']:
                obj.hide_render = not obj.name.startswith(EYE_PARTS)
        render(pack + 'GazeHeadEyes-' + eye)

    for style, hair, skin in itertools.product(['sweep', 'crop'], COLORS['hair'], COLORS['skin']):
        palette(pack, hair, skin)
        for obj in scene.objects:
            if obj.type not in ['MESH', 'CURVE']:
                continue
            ancestor = obj.parent
            belongs = False
            while ancestor:
                if ancestor == head:
                    belongs = True
                    break
                ancestor = ancestor.parent
            obj.hide_render = not belongs or obj.name.startswith(EYE_PARTS + ('Peek ', 'Accessory '))
            if pack == 'Milo' and (obj.name.startswith('Hair • swept lock') or obj.name == 'Hair • subtle part'):
                obj.hide_render = style == 'crop'
            if obj.name.startswith('Nova bob •'):
                obj.hide_render = style != 'sweep'
            if obj.name.startswith('Nova bun •'):
                obj.hide_render = style != 'crop'
        render(pack + 'GazeHead-' + style + '-' + hair + '-' + skin)

(SOURCE / 'portrait-gaze-geometry.json').write_text(json.dumps(metadata, indent=2) + '\n')
print('PORTRAIT_GAZE_COMPLETE', flush=True)
