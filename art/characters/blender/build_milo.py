import bpy, math, os, json
from mathutils import Vector
OUT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bpy.ops.wm.read_factory_settings(use_empty=True)
s=bpy.context.scene;s.render.engine='CYCLES';s.cycles.samples=32;s.cycles.use_denoising=True
s.render.resolution_x=900;s.render.resolution_y=1000;s.render.resolution_percentage=100
s.render.image_settings.file_format='PNG';s.render.image_settings.color_mode='RGBA';s.render.film_transparent=True
s.render.fps=24;s.frame_end=96;s.world=bpy.data.worlds.new('Portrait studio');s.world.use_nodes=True
s.world.node_tree.nodes['Background'].inputs[0].default_value=(.5,.6,.75,1)
s.world.node_tree.nodes['Background'].inputs[1].default_value=.4;s.view_settings.view_transform='AgX'
def mat(name,c,r=.5,sub=0):
 m=bpy.data.materials.new(name);m.diffuse_color=(*c,1);m.use_nodes=True;p=m.node_tree.nodes['Principled BSDF'];p.inputs['Base Color'].default_value=(*c,1);p.inputs['Roughness'].default_value=r;p.inputs['Subsurface Weight'].default_value=sub;return m
skin=mat('Warm caramel • skin',(.62,.30,.17),.57,.12)
hair=mat('Deep tide • hair',(.022,.085,.115),.43)
rim=mat('Ink • eye contour',(.015,.024,.033),.38)
ivory=mat('Porcelain • eye white',(.92,.95,.94),.3)
iris=mat('Sea glass • iris',(.05,.40,.43),.24)
pupil=mat('Obsidian • pupil',(.006,.013,.02),.13)
glint=mat('Light • catchlights',(.99,1,1),.12)
shirt=mat('Cornflower • jacket',(.13,.30,.72),.58)
shirt2=mat('Periwinkle • collar',(.32,.48,.86),.6)
pants=mat('Midnight • trousers',(.055,.08,.15),.65)
sole=mat('Chalk • shoes',(.77,.84,.89),.5)
coral=mat('Coral • pocket tab',(.95,.31,.19),.5)
cheek=mat('Cinnamon • cheeks',(.67,.24,.17),.7,.08)
def ctrl(name,loc,parent=None):
 o=bpy.data.objects.new(name,None);s.collection.objects.link(o);o.location=loc;o.empty_display_type='SPHERE';o.empty_display_size=.1
 if parent:o.parent=parent
 return o
root=ctrl('CTRL_body',(0,0,0));head=ctrl('CTRL_head',(0,0,2.30),root)
la=ctrl('CTRL_arm_L',(-.38,0,1.45),root);ra=ctrl('CTRL_arm_R',(.38,0,1.45),root)
def sphere(name,loc,scale,m,parent=root):
 bpy.ops.mesh.primitive_uv_sphere_add(segments=48,ring_count=32);o=bpy.context.object;o.name=name;o.parent=parent;o.location=loc;o.scale=scale;o.data.materials.append(m)
 for p in o.data.polygons:p.use_smooth=True
 return o
def curve(name,pts,r,m,parent=root):
 c=bpy.data.curves.new(name,'CURVE');c.dimensions='3D';c.bevel_depth=r;c.bevel_resolution=5;c.resolution_u=24;sp=c.splines.new('BEZIER');sp.bezier_points.add(len(pts)-1)
 for b,p in zip(sp.bezier_points,pts):b.co=p;b.handle_left_type='AUTO';b.handle_right_type='AUTO'
 o=bpy.data.objects.new(name,c);s.collection.objects.link(o);o.parent=parent;c.materials.append(m);return o
torso=sphere('Jacket • rounded tunic',(0,.035,1.15),(.40,.27,.52),shirt)
neck=sphere('Neck',(0,0,1.68),(.17,.18,.23),skin)
collar=sphere('Collar • rolled',(0,-.03,1.61),(.27,.23,.10),shirt2)
curve('Jacket • zipper',[(0,-.257,.85),(0,-.275,1.15),(0,-.21,1.50)],.012,shirt2)
sphere('Zip pull',(0,-.263,1.39),(.025,.018,.05),sole)
sphere('Pocket • coral label',(.23,-.214,1.12),(.05,.018,.06),coral)
legs=[]
for x in [-1,1]:
 legs.append(sphere('Trouser '+str(x),(x*.18,.03,.60),(.15,.17,.34),pants))
 legs.append(sphere('Sneaker '+str(x),(x*.18,-.09,.30),(.18,.28,.14),sole))
 sphere('Sneaker upper '+str(x),(x*.18,-.07,.36),(.16,.23,.11),shirt2)
for arm,x in [(la,-1),(ra,1)]:
 o=sphere('Sleeve '+str(x),(x*.08,0,-.20),(.15,.17,.32),shirt,arm);o.rotation_euler[1]=-x*.20
 sphere('Cuff '+str(x),(x*.12,-.02,-.39),(.15,.17,.065),shirt2,arm)
 sphere('Hand '+str(x),(x*.12,-.02,-.50),(.14,.14,.17),skin,arm)
 sphere('Thumb '+str(x),(x*.035,-.12,-.48),(.075,.08,.10),skin,arm)
face=sphere('Head • original human sculpt',(0,0,0),(.68,.44,.67),skin,head)
for x in [-1,1]:
 sphere('Ear '+str(x),(x*.65,.015,-.03),(.13,.105,.20),skin,head)
 sphere('Ear fold '+str(x),(x*.68,-.083,-.02),(.063,.022,.105),cheek,head)
 sphere('Cheek '+str(x),(x*.43,-.346,-.25),(.10,.025,.065),cheek,head)
eyes=[]
for x in [-1,1]:
 ec=ctrl('CTRL_eye_'+str(x),(x*.278,-.382,.005),head);eyes.append(ec)
 sphere('Eye contour '+str(x),(0,0,0),(.286,.10,.342),rim,ec)
 sphere('Eye white '+str(x),(0,-.042,.008),(.263,.087,.315),ivory,ec)
 sphere('Iris '+str(x),(x*.017,-.108,.006),(.220,.069,.278),iris,ec)
 sphere('Pupil '+str(x),(x*.017,-.148,.012),(.168,.047,.232),pupil,ec)
 sphere('Eye light '+str(x),(-.055,-.186,.11),(.057,.017,.075),glint,ec)
 sphere('Eye light small '+str(x),(.075,-.184,-.10),(.021,.01,.027),glint,ec)
 curve('Brow '+str(x),[(x*.278-.14,-.34,.41),(x*.278,-.385,.455),(x*.278+.12,-.35,.425)],.025,hair,head)
sphere('Nose • button',(0,-.466,-.20),(.075,.085,.085),skin,head)
curve('Smile • resting',[(-.105,-.403,-.40),(0,-.432,-.427),(.105,-.403,-.40)],.015,rim,head)

# Original swept cap: continuous mesh with asymmetric forehead boundary.
verts=[];faces=[];N=72;R=24
for j in range(R+1):
 for i in range(N):
  a=i*2*math.pi/N
  front=max(0,-math.sin(a));sweep=.23*math.cos(a)*front
  end=1.83-.72*front+sweep
  t=.001+(end-.001)*j/R
  verts.append((.705*math.sin(t)*math.cos(a),.47*math.sin(t)*math.sin(a)+.035,.705*math.cos(t)+.06))
for j in range(R):
 for i in range(N):
  ni=(i+1)%N;faces.append((j*N+i,j*N+ni,(j+1)*N+ni,(j+1)*N+i))
mesh=bpy.data.meshes.new('Swept hair surface');mesh.from_pydata(verts,[],faces);mesh.update();cap=bpy.data.objects.new('Hair • asymmetric swept cap',mesh);s.collection.objects.link(cap);cap.parent=head;cap.data.materials.append(hair)
for p in mesh.polygons:p.use_smooth=True
solid=cap.modifiers.new('Hair thickness','SOLIDIFY');solid.thickness=.045
sub=cap.modifiers.new('Soft silhouette','SUBSURF');sub.levels=2
# Long flattened side-swept locks overlap cap, giving dimensional readable bangs.
for i,(loc,scale,angle) in enumerate([((-.21,-.25,.50),(.36,.19,.17),-.30),((.14,-.29,.48),(.38,.18,.16),.47),((.39,-.24,.29),(.17,.15,.34),-.47)]):
 o=sphere('Hair • swept lock '+str(i),loc,scale,hair,head);o.rotation_euler[1]=angle
curve('Hair • subtle part',[(.01,-.35,.64),(.18,-.37,.57),(.36,-.34,.43)],.007,mat('Hair • part sheen',(.05,.16,.19),.55),head)

peekHands=[]
for x in [-1,1]:
 p=sphere('Peek hand '+str(x),(x*.40,-.49,1.79),(.145,.13,.13),skin);p.hide_render=True;p.hide_set(True);peekHands.append(p)
 for dx in [-.035,.035]:
  p=curve('Peek finger '+str(x),[(x*.40+dx,-.61,1.77),(x*.40+dx,-.615,1.83)],.006,cheek);p.hide_render=True;p.hide_set(True);peekHands.append(p)

def light(name,loc,power,size,color):
 d=bpy.data.lights.new(name,'AREA');d.energy=power;d.shape='DISK';d.size=size;d.color=color;o=bpy.data.objects.new(name,d);s.collection.objects.link(o);o.location=loc;o.rotation_euler=(Vector((0,0,1.9))-o.location).to_track_quat('-Z','Y').to_euler()
light('Key • soft cool',(-3,-4,6),500,4,(.88,.95,1));light('Fill • warm',(3,-3,3),230,3,(1,.83,.70));light('Rim • edge',(1,3,5),550,3,(.64,.79,1))
bpy.ops.object.camera_add(location=(1.0,-10,3.2));cam=bpy.context.object;cam.name='Portrait camera';cam.data.type='ORTHO';cam.data.ortho_scale=3.8;cam.rotation_euler=(Vector((0,0,1.65))-cam.location).to_track_quat('-Z','Y').to_euler();s.camera=cam
def pose(name):
 root.location=(0,0,0);head.rotation_euler=(0,0,0);la.rotation_euler=(0,0,0);ra.rotation_euler=(0,0,0)
 for e in eyes:e.scale=(1,1,1)
 if name=='wave':la.rotation_euler[1]=2.6;head.rotation_euler[1]=-.09
 if name=='think':ra.rotation_euler[1]=-1.85;ra.rotation_euler[0]=-.5;head.rotation_euler[1]=.12;head.rotation_euler[2]=-.12
 if name=='blink':
  for e in eyes:e.scale.z=.06
 if name=='celebrate':la.rotation_euler[1]=2.25;ra.rotation_euler[1]=-2.25;root.location.z=.12
frames={'idle':1,'wave':16,'think':40,'blink':58,'celebrate':76}
for f,n in [(1,'idle'),(16,'wave'),(28,'idle'),(40,'think'),(52,'idle'),(58,'blink'),(62,'idle'),(76,'celebrate'),(96,'idle')]:
 pose(n);s.timeline_markers.new(n.upper(),frame=f)
 for c in [root,head,la,ra]+eyes:
  for p in ['location','rotation_euler','scale']:c.keyframe_insert(data_path=p,frame=f)
s.frame_set(1);s['rig_notes']='Original character. Named rigid-part transform controls; nine editable pose beats. No weighted skin, IK, phonemes or production rig claim.'
for screen in bpy.data.screens:
 for a in screen.areas:
  if a.type=='VIEW_3D':a.spaces.active.region_3d.view_perspective='CAMERA'
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT,'blender','Milo.blend'))
for n,f in frames.items():
 s.frame_set(f);s.render.filepath=os.path.join(OUT,'renders','milo-'+n+'.png');bpy.ops.render.render(write_still=True)
s.frame_set(1)
for o in s.objects:
 if o.type in ['MESH','CURVE'] and o.parent!=head and o not in peekHands:
  # Hide body and arm parts for composer bust; keep head descendants.
  p=o.parent;belongs=False
  while p:
   if p==head:belongs=True
   p=p.parent
  if not belongs:o.hide_render=True
for o in peekHands:o.hide_render=False
cam.location=(.25,-10,2.9);cam.rotation_euler=(Vector((0,0,2.39))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=1.95
s.render.resolution_x=900;s.render.resolution_y=800;s.render.filepath=os.path.join(OUT,'renders','milo-peek.png');bpy.ops.render.render(write_still=True)
with open(os.path.join(OUT,'blender','milo-manifest.json'),'w') as f:json.dump({'blender':bpy.app.version_string,'objects':len(s.objects),'poses':frames,'editable_rig':'Rigid part parent controls; no IK or weighted skin','original_assets':True},f,indent=2)
