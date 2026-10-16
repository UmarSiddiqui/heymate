import bpy,math
def apply_future_outfit():
    s=bpy.context.scene;root=bpy.data.objects['CTRL_body']
    def mat(name,c,rough=.4,metal=.0):
        m=bpy.data.materials.new(name);m.use_nodes=True;m.diffuse_color=(*c,1);p=m.node_tree.nodes['Principled BSDF'];p.inputs['Base Color'].default_value=(*c,1);p.inputs['Roughness'].default_value=rough;p.inputs['Metallic'].default_value=metal;return m
    coat=mat('Future • ocean technical fabric',(.035,.20,.37),.45)
    trim=mat('Future • apricot piping',(.95,.36,.075),.36)
    chalk=mat('Future • pearl hardware',(.72,.83,.86),.33,.15)
    sole=mat('Future • dark flexible sole',(.018,.04,.07),.6)
    def sphere(name,loc,scale,m,parent=root):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=40,ring_count=24);o=bpy.context.object;o.name=name;o.parent=parent;o.location=loc;o.scale=scale;o.data.materials.append(m)
        for p in o.data.polygons:p.use_smooth=True
        return o
    def curve(name,pts,r,m,parent=root):
        c=bpy.data.curves.new(name,'CURVE');c.dimensions='3D';c.resolution_u=24;c.bevel_depth=r;c.bevel_resolution=4;sp=c.splines.new('BEZIER');sp.bezier_points.add(len(pts)-1)
        for b,p in zip(sp.bezier_points,pts):b.co=p;b.handle_left_type='AUTO';b.handle_right_type='AUTO'
        o=bpy.data.objects.new(name,c);s.collection.objects.link(o);o.parent=parent;c.materials.append(m);return o
    def torus(name,loc,r,t,m,parent=root,scale=(1,1,1)):
        bpy.ops.mesh.primitive_torus_add(major_radius=r,minor_radius=t,major_segments=64,minor_segments=16);o=bpy.context.object;o.name=name;o.parent=parent;o.location=loc;o.scale=scale;o.data.materials.append(m)
        for p in o.data.polygons:p.use_smooth=True
        return o
    for name in ['Jacket • rounded tunic','Jacket • zipper','Zip pull','Pocket • coral label','Collar • rolled']:
        o=bpy.data.objects.get(name)
        if o:o.hide_render=True;o.hide_set(True)
    for o in list(s.objects):
        if o.name.startswith(('Sneaker ','Sneaker upper')):o.hide_render=True;o.hide_set(True)
        if o.name.startswith('Sleeve '):o.data.materials.clear();o.data.materials.append(coat);o.scale.x*=1.12;o.scale.y*=1.1
        if o.name.startswith('Cuff '):o.data.materials.clear();o.data.materials.append(trim)
        if o.name.startswith(('Hand ','Thumb ','Peek hand ')):o.data.materials.clear();o.data.materials.append(coat)
    # Flared technical coat, distinct from the original rounded romper.
    rings=[(.76,.43),(.82,.46),(1.02,.43),(1.32,.39),(1.52,.32),(1.58,.25)]
    verts=[];faces=[];N=64
    for z,r in rings:
        for i in range(N):
            a=i*2*math.pi/N;verts.append((r*math.cos(a),r*.70*math.sin(a)+.025,z))
    for j in range(len(rings)-1):
        for i in range(N):faces.append((j*N+i,j*N+(i+1)%N,(j+1)*N+(i+1)%N,(j+1)*N+i))
    mesh=bpy.data.meshes.new('Flared coat shell');mesh.from_pydata(verts,[],faces);mesh.update();o=bpy.data.objects.new('Future • flared jacket',mesh);s.collection.objects.link(o);o.parent=root;o.data.materials.append(coat)
    for p in mesh.polygons:p.use_smooth=True
    sub=o.modifiers.new('Soft technical shell','SUBSURF');sub.levels=2;sol=o.modifiers.new('Jacket thickness','SOLIDIFY');sol.thickness=.035
    # Oversized raised collar and hem piping echo the verified reference structure.
    torus('Future • raised collar',(0,0,1.61),.265,.085,coat,scale=(1,.82,1.45))
    torus('Future • collar rim',(0,0,1.70),.265,.018,trim,scale=(1,.82,1))
    curve('Future • front piping',[(0,-.19,1.69),(0,-.245,1.48),(0,-.285,1.22),(0,-.303,.82)],.014,trim)
    torus('Future • piped hem',(0,.025,.80),.45,.015,trim,scale=(1,.7,1))
    for x in [-1,1]:
        curve('Future • panel seam '+str(x),[(x*.27,-.17,1.52),(x*.29,-.20,1.25),(x*.34,-.20,.86)],.010,chalk)
        sphere('Future • tall boot '+str(x),(x*.20,-.07,.43),(.225,.265,.28),coat)
        sphere('Future • oversized toe '+str(x),(x*.20,-.22,.29),(.245,.34,.16),coat)
        sphere('Future • boot sole '+str(x),(x*.20,-.18,.19),(.25,.34,.065),sole)
        torus('Future • boot rim '+str(x),(x*.20,-.07,.64),.20,.035,trim,scale=(1,1.1,1))
        sphere('Future • boot side disc '+str(x),(x*.39,-.07,.44),(.035,.085,.09),chalk)
    emblem=torus('Future • original orbit badge',(-.18,-.258,1.37),.055,.012,chalk);emblem.rotation_euler[0]=math.pi/2
    sphere('Future • orbit dot',(-.14,-.278,1.40),(.018,.012,.018),trim)
    s['outfit']='Future: original ocean-blue technical coat, raised collar, apricot piping, chunky magnetic-style boots. Inspired by Egghead clothing construction, no copied logo or costume.'
apply_future_outfit()
