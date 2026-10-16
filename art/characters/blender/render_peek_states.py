import bpy,os
from mathutils import Vector
OUT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for outfit in ['classic','future']:
 bpy.ops.wm.open_mainfile(filepath=os.path.join(OUT,'blender','Milo-'+outfit.title()+'.blend'))
 s=bpy.context.scene;head=bpy.data.objects['CTRL_head']
 for o in s.objects:
  if o.type not in ['MESH','CURVE']:continue
  p=o.parent;belongs=False
  while p:
   if p==head:belongs=True
   p=p.parent
  o.hide_render=not belongs
  if o.name.startswith('Peek '):o.hide_render=False
 cam=s.camera;cam.location=(.25,-10,2.9);cam.rotation_euler=(Vector((0,0,2.39))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=1.95
 s.render.resolution_x=900;s.render.resolution_y=800;s.cycles.samples=32
 for name,frame in {'idle':1,'wave':16,'think':40,'blink':58,'celebrate':76}.items():
  s.frame_set(frame)
  for o in s.objects:
   if o.name.startswith('Peek hand ') and o.name.endswith('-1'):o.location.z=1.93 if name=='wave' else 1.79
  prefix='milo' if outfit=='classic' else 'milo-future'
  suffix='peek' if name=='idle' else 'peek-'+name
  s.render.filepath=os.path.join(OUT,'renders',prefix+'-'+suffix+'.png');bpy.ops.render.render(write_still=True)
