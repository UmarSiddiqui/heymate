import bpy,math,os
OUT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bpy.ops.wm.open_mainfile(filepath=os.path.join(OUT,'blender','Milo-Classic.blend'))
s=bpy.context.scene;s.frame_set(1);head=bpy.data.objects['CTRL_head'];root=bpy.data.objects['CTRL_body']
hair=bpy.data.materials['Deep tide • hair'];skin=bpy.data.materials['Warm caramel • skin'];rim=bpy.data.materials['Ink • eye contour'];chalk=bpy.data.materials['Chalk • shoes']
def color(name,c):
 m=bpy.data.materials[name];m.diffuse_color=(*c,1);m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=(*c,1)
def sphere(name,loc,scale,m,parent=head):
 bpy.ops.mesh.primitive_uv_sphere_add(segments=40,ring_count=24);o=bpy.context.object;o.name=name;o.parent=parent;o.location=loc;o.scale=scale;o.data.materials.append(m)
 for p in o.data.polygons:p.use_smooth=True
 return o
def curve(name,pts,r,m,parent=head):
 c=bpy.data.curves.new(name,'CURVE');c.dimensions='3D';c.resolution_u=24;c.bevel_depth=r;c.bevel_resolution=4;sp=c.splines.new('BEZIER');sp.bezier_points.add(len(pts)-1)
 for b,p in zip(sp.bezier_points,pts):b.co=p;b.handle_left_type='AUTO';b.handle_right_type='AUTO'
 o=bpy.data.objects.new(name,c);s.collection.objects.link(o);o.parent=parent;c.materials.append(m);return o
for o in list(s.objects):
 if o.name.startswith('Hair •'):bpy.data.objects.remove(o,do_unlink=True)
bpy.data.objects['Head • original human sculpt'].scale=(.65,.44,.66)
# Original sculpted bob and high-bun silhouettes share a continuous crown.
verts=[];faces=[];N=64;R=24
for j in range(R+1):
 for i in range(N):
  a=i*2*math.pi/N;front=max(0,-math.sin(a));end=2.13-.92*front+.19*math.cos(a)*front;t=.001+(end-.001)*j/R
  verts.append((.69*math.sin(t)*math.cos(a),.49*math.sin(t)*math.sin(a)+.055,.72*math.cos(t)+.08))
for j in range(R):
 for i in range(N):faces.append((j*N+i,j*N+(i+1)%N,(j+1)*N+(i+1)%N,(j+1)*N+i))
mesh=bpy.data.meshes.new('Nova continuous sculpted crown');mesh.from_pydata(verts,[],faces);mesh.update();o=bpy.data.objects.new('Nova hair • crown',mesh);s.collection.objects.link(o);o.parent=head;o.data.materials.append(hair)
for p in mesh.polygons:p.use_smooth=True
o.modifiers.new('Crown thickness','SOLIDIFY').thickness=.04;o.modifiers.new('Soft crown','SUBSURF').levels=2
for x in [-1,1]:
 o=sphere('Nova bob • side '+str(x),(x*.59,.055,-.12),(.22,.34,.47),hair);o.rotation_euler[1]=x*.08
 curve('Nova bob • sculpted groove '+str(x),[(x*.62,-.20,.25),(x*.70,-.21,-.12),(x*.61,-.21,-.49)],.009,chalk)
# Asymmetric bangs expose eyes and make Nova distinct from Milo.
for i,(loc,scale,angle) in enumerate([((-.27,-.25,.48),(.35,.18,.18),-.38),((.22,-.25,.51),(.32,.17,.15),.22)]):
 o=sphere('Nova hair • fringe '+str(i),loc,scale,hair);o.rotation_euler[1]=angle
for i,(loc,scale) in enumerate([((0,.28,.60),(.27,.25,.22)),((0,.27,.76),(.19,.19,.17))]):
 o=sphere('Nova bun • coil '+str(i),loc,scale,hair);o.hide_render=True;o.hide_set(True)
for x in [-1,1]:
 for i in range(3):
  curve('Nova lash '+str(x)+' '+str(i),[(x*(.47+i*.035),-.44,.24+i*.025),(x*(.57+i*.043),-.43,.31+i*.035)],.012,rim)
 curve('Nova smile • soft upper '+str(x),[(0,-.444,-.412),(x*.07,-.43,-.405),(x*.115,-.408,-.39)],.009,bpy.data.materials['Cinnamon • cheeks'])
 # Small original orbit earrings, not copied reference logos.
 bpy.ops.mesh.primitive_torus_add(major_radius=.047,minor_radius=.012,major_segments=40,minor_segments=12)
 o=bpy.context.object;o.name='Nova earring • orbit '+str(x);o.parent=head;o.location=(x*.655,-.10,-.23);o.rotation_euler[0]=math.pi/2;o.data.materials.append(chalk)
color('Deep tide • hair',(.018,.035,.065));color('Cornflower • jacket',(.025,.26,.24));color('Periwinkle • collar',(.30,.65,.57));color('Coral • pocket tab',(.90,.64,.24))
s['character']='Nova — original feminine-presenting companion. Sculpted bob / high bun, expressive eyes, practical technical clothing. Same modular palette and rigid-part controls as Milo.'
for screen in bpy.data.screens:
 for a in screen.areas:
  if a.type=='VIEW_3D':a.spaces.active.shading.type='MATERIAL';a.spaces.active.overlay.show_overlays=False;a.spaces.active.region_3d.view_perspective='CAMERA'
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT,'blender','Nova-Classic.blend'))
exec(compile(open(os.path.join(OUT,'blender','future_outfit.py')).read(),'future_outfit.py','exec'))
color('Future • ocean technical fabric',(.035,.13,.19));color('Future • apricot piping',(.30,.78,.64))
s['outfit']='Nova Future — graphite ocean technical coat, mint piping, raised collar, gloves and magnetic-style boots. Original construction inspired by futuristic adventure clothing.'
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT,'blender','Nova-Future.blend'))
