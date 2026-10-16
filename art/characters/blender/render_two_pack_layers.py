import bpy,os,itertools,math,json
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view
OUT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)));R=os.path.join(OUT,'renders')
COLORS={'hair':{'tide':(.022,.085,.115),'copper':(.31,.075,.025),'lilac':(.28,.15,.42)},'skin':{'sand':(.83,.51,.32),'caramel':(.62,.30,.17),'umber':(.27,.105,.06)},'eye':{'sea':(.05,.40,.43),'amber':(.57,.27,.035),'violet':(.26,.17,.57)}}
DONE=set()  # Fresh renders must not inherit a previous session's resume list.
MAT={'hair':'Deep tide • hair','skin':'Warm caramel • skin','eye':'Sea glass • iris'}
def palette(pack,h,sk,e):
 for kind,key in [('hair',h),('skin',sk),('eye',e)]:
  c=COLORS[kind][key]
  if pack=='Nova' and kind=='hair' and key=='tide':c=(.018,.035,.065)
  m=bpy.data.materials[MAT[kind]];m.diffuse_color=(*c,1);m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=(*c,1)
def style(pack,st):
 for o in bpy.context.scene.objects:
  if pack=='Milo' and (o.name.startswith('Hair • swept lock') or o.name=='Hair • subtle part'):o.hide_render=st=='crop'
  if o.name.startswith('Nova bob •'):o.hide_render=st!='sweep'
  if o.name.startswith('Nova bun •'):o.hide_render=st!='crop'
def descendant(o,head):
 p=o.parent
 while p:
  if p==head:return True
  p=p.parent
 return False
def view(kind):
 s=bpy.context.scene;head=bpy.data.objects['CTRL_head'];cam=s.camera
 for o in s.objects:
  if o.type in ['MESH','CURVE']:
   if kind=='body':o.hide_render=bool(o.get('initial_hidden',False))
   else:o.hide_render=not descendant(o,head)
   if o.name.startswith('Peek '):o.hide_render=kind!='peek'
   if o.name.startswith('Accessory '):o.hide_render=True
 if kind=='body':
  cam.location=(1,-10,3.2);target=(0,0,1.65);cam.data.ortho_scale=3.8;s.render.resolution_x=550;s.render.resolution_y=610
 elif kind=='head':
  cam.location=(.25,-10,2.7);target=(0,0,2.39);cam.data.ortho_scale=1.95;s.render.resolution_x=550;s.render.resolution_y=600
 else:
  cam.location=(.25,-10,2.9);target=(0,0,2.39);cam.data.ortho_scale=1.95;s.render.resolution_x=550;s.render.resolution_y=490
 cam.rotation_euler=(Vector(target)-cam.location).to_track_quat('-Z','Y').to_euler();bpy.context.view_layer.update()
def render(name):
 if name in DONE and 'Accessory-' not in name:return
 s=bpy.context.scene;s.render.filepath=os.path.join(R,name+'.png');bpy.ops.render.render(write_still=True)
def mat(name,c,metal=.0):
 m=bpy.data.materials.new(name);m.use_nodes=True;m.diffuse_color=(*c,1);p=m.node_tree.nodes['Principled BSDF'];p.inputs['Base Color'].default_value=(*c,1);p.inputs['Roughness'].default_value=.32;p.inputs['Metallic'].default_value=metal;return m
def accessories():
 for o in list(bpy.context.scene.objects):
  if o.name.startswith('Accessory '):bpy.data.objects.remove(o,do_unlink=True)
 head=bpy.data.objects['CTRL_head'];s=bpy.context.scene;fabric=mat('Accessory • cobalt cap',(.035,.10,.20));silver=mat('Accessory • pearl trim',(.65,.80,.83),.35);glass=mat('Accessory • smoked lens',(.012,.025,.035),.3)
 def sphere(name,loc,scale,m):
  bpy.ops.mesh.primitive_uv_sphere_add(segments=40,ring_count=24);o=bpy.context.object;o.name='Accessory '+name;o.parent=head;o.location=loc;o.scale=scale;o.data.materials.append(m)
  for p in o.data.polygons:p.use_smooth=True
  o.hide_render=True;o.hide_set(True)
 def curve(name,pts,r,m):
  c=bpy.data.curves.new(name,'CURVE');c.dimensions='3D';c.bevel_depth=r;c.bevel_resolution=4;c.resolution_u=24;sp=c.splines.new('BEZIER');sp.bezier_points.add(len(pts)-1)
  for b,p in zip(sp.bezier_points,pts):b.co=p;b.handle_left_type='AUTO';b.handle_right_type='AUTO'
  o=bpy.data.objects.new('Accessory '+name,c);s.collection.objects.link(o);o.parent=head;c.materials.append(m);o.hide_render=True;o.hide_set(True)
 sphere('orbitcap crown',(0,.045,.68),(.77,.56,.20),fabric)
 sphere('orbitcap visor',(0,-.46,.57),(.72,.30,.055),fabric)
 curve('orbitcap seam',[(-.65,-.28,.68),(0,-.50,.81),(.65,-.28,.68)],.012,silver)
 curve('orbitcap orbit',[(.09*math.cos(i*2*math.pi/32),-.505,.73+.055*math.sin(i*2*math.pi/32)) for i in range(33)],.012,silver)
 sphere('orbitcap dot',(.10,-.523,.77),(.021,.012,.021),silver)
 for x in [-1,1]:
  sphere('sunglasses lens '+str(x),(x*.278,-.57,.005),(.254,.038,.293),glass)
  curve('sunglasses frame '+str(x),[(x*.278+.263*math.cos(i*2*math.pi/40),-.606,.005+.30*math.sin(i*2*math.pi/40)) for i in range(41)],.014,silver)
  curve('sunglasses arm '+str(x),[(x*.54,-.59,.04),(x*.66,-.35,.05),(x*.66,.015,.025)],.018,fabric)
 curve('sunglasses bridge',[(-.045,-.61,.075),(0,-.625,.095),(.045,-.61,.075)],.018,silver)

def load(pack,outfit):
 bpy.ops.wm.open_mainfile(filepath=os.path.join(OUT,'blender',pack+'-'+outfit.title()+'.blend'));s=bpy.context.scene;s.frame_set(1);s.cycles.samples=16
 for o in s.objects:
  if o.type in ['MESH','CURVE']:o['initial_hidden']=o.hide_render

 for o in s.objects:
  if o.name.startswith('Nova bun • coil 0'):o.location.z=.60;o.scale=(.27,.25,.22)
  if o.name.startswith('Nova bun • coil 1'):o.location.z=.76;o.scale=(.19,.19,.17)
 accessories();return s
metadata={}
for pack in ['Milo','Nova']:
 s=load(pack,'classic');head=bpy.data.objects['CTRL_head']
 if pack=='Milo':bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT,'blender','Milo-Classic-Accessories.blend'))
 else:bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT,'blender','Nova-Classic.blend'))
 for kind in ['head','peek','body']:
  view(kind)
  for acc in ['orbitcap','sunglasses']:
   for o in s.objects:
    if o.type in ['MESH','CURVE']:o.hide_render=not o.name.startswith('Accessory '+acc)
   render(pack+'Accessory-'+acc+'-'+kind)
 # Independent eye layer keeps original white contours in base artwork.
 view('peek');bpy.context.view_layer.update()
 points=[]
 for x in [-1,1]:
  obj=bpy.data.objects['Eye white '+str(x)];p=world_to_camera_view(s,s.camera,obj.matrix_world.translation);points.append([p.x,1-p.y])
 metadata[pack]={'eyeCenters':points,'ellipseWidth':.526/1.95,'ellipseHeight':.63/(1.95*490/550)}
 with open(os.path.join(OUT,'blender','gaze-geometry.json'),'w') as f:json.dump(metadata,f,indent=2)
 for eye in COLORS['eye']:
  palette(pack,'tide','caramel',eye)
  for o in s.objects:
   if o.type in ['MESH','CURVE']:o.hide_render=not o.name.startswith(('Iris ','Pupil ','Eye light '))
  render(pack+'GazeEyes-'+eye)
 for st,h,sk,e in itertools.product(['sweep','crop'],COLORS['hair'],COLORS['skin'],COLORS['eye']):
  palette(pack,h,sk,e)
  if pack=='Nova':
   for kind in ['head','peek','body']:
    view(kind);style(pack,st)
    name='Nova-'+st+'-'+h+'-'+sk+'-'+e if kind=='head' else ('NovaPeek-'+st+'-'+h+'-'+sk+'-'+e if kind=='peek' else 'NovaBody-'+st+'-'+h+'-'+sk+'-'+e+'-classic')
    render(name)
  view('peek');style(pack,st)
  for o in s.objects:
   if o.name.startswith(('Iris ','Pupil ','Eye light ')):o.hide_render=True
  render(pack+'GazePeek-'+st+'-'+h+'-'+sk+'-'+e)
 if pack=='Nova':
  s=load(pack,'future');bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT,'blender','Nova-Future.blend'))
  for st,h,sk,e in itertools.product(['sweep','crop'],COLORS['hair'],COLORS['skin'],COLORS['eye']):
   view('body');style(pack,st);palette(pack,h,sk,e);render('NovaBody-'+st+'-'+h+'-'+sk+'-'+e+'-future')
  # Original matching-crop state frames for both outfits.
  for outfit in ['classic','future']:
   s=load(pack,outfit);prefix='Nova' if outfit=='classic' else 'NovaFuture'
   for name,f in {'Idle':1,'Wave':16,'Think':40,'Blink':58,'Celebrate':76}.items():
    s.frame_set(f);view('body');style(pack,'sweep');palette(pack,'tide','caramel','sea');render(prefix+name)
    view('peek');style(pack,'sweep')
    for o in s.objects:
     if o.name.startswith('Peek hand ') and o.name.endswith('-1'):o.location.z=1.93 if name=='Wave' else 1.79
    render(prefix+('Peek' if name=='Idle' else 'Peek'+name))
with open(os.path.join(OUT,'blender','gaze-geometry.json'),'w') as f:json.dump(metadata,f,indent=2)
