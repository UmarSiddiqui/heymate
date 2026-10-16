import bpy,os,itertools,json
from mathutils import Vector
OUT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bpy.ops.wm.open_mainfile(filepath=os.path.join(OUT,'blender','Milo.blend'))
s=bpy.context.scene;s.frame_set(1);head=bpy.data.objects['CTRL_head']
for o in s.objects:
 if o.type not in ['MESH','CURVE']:continue
 p=o.parent;belongs=False
 while p:
  if p==head:belongs=True
  p=p.parent
 o.hide_render=not belongs
cam=s.camera;cam.location=(.25,-10,2.7);cam.rotation_euler=(Vector((0,0,2.39))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=1.95
s.render.resolution_x=550;s.render.resolution_y=490;s.cycles.samples=16
for o in s.objects:
 if o.name.startswith('Peek '):o.hide_render=False
cam.location=(.25,-10,2.9);cam.rotation_euler=(Vector((0,0,2.39))-cam.location).to_track_quat('-Z','Y').to_euler()
colors={
 'hair':{'tide':(.022,.085,.115),'copper':(.31,.075,.025),'lilac':(.28,.15,.42)},
 'skin':{'sand':(.83,.51,.32),'caramel':(.62,.30,.17),'umber':(.27,.105,.06)},
 'eye':{'sea':(.05,.40,.43),'amber':(.57,.27,.035),'violet':(.26,.17,.57)}}
materials={'hair':bpy.data.materials['Deep tide • hair'],'skin':bpy.data.materials['Warm caramel • skin'],'eye':bpy.data.materials['Sea glass • iris']}
count=0
for style,hair,skin,eye in itertools.product(['sweep','crop'],colors['hair'],colors['skin'],colors['eye']):
 for kind,key in [('hair',hair),('skin',skin),('eye',eye)]:
  c=colors[kind][key];m=materials[kind];m.diffuse_color=(*c,1);m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=(*c,1)
 for o in bpy.data.objects:
  if o.name.startswith('Hair • swept lock') or o.name=='Hair • subtle part':o.hide_render=style=='crop'
 s.render.filepath=os.path.join(OUT,'renders',f'custom-peek-{style}-{hair}-{skin}-{eye}.png');bpy.ops.render.render(write_still=True);count+=1
