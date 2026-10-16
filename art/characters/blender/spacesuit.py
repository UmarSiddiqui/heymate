import bpy
def apply_spacesuit():
    s=bpy.context.scene;root=bpy.data.objects['CTRL_body']
    def material(name,c,metal=.0):
        m=bpy.data.materials.get(name) or bpy.data.materials.new(name);m.use_nodes=True;m.diffuse_color=(*c,1)
        p=m.node_tree.nodes['Principled BSDF'];p.inputs['Base Color'].default_value=(*c,1);p.inputs['Roughness'].default_value=.37;p.inputs['Metallic'].default_value=metal
        return m
    shell=material('Suit • ceramic shell',(.68,.79,.87),.18)
    navy=material('Suit • flexible navy seals',(.022,.055,.095),.12)
    panel=material('Suit • chest module',(.035,.15,.24),.3)
    cyan=material('Suit • oxygen indicators',(.12,.75,.92),.3)
    orange=material('Suit • rescue orange',(.95,.30,.055),.15)
    def box(name,loc,scale,m,bevel=.04,parent=root):
        bpy.ops.mesh.primitive_cube_add();o=bpy.context.object;o.name=name;o.parent=parent;o.location=loc;o.scale=scale
        bpy.ops.object.transform_apply(location=False,rotation=False,scale=True);o.data.materials.append(m)
        b=o.modifiers.new('Rounded armor edges','BEVEL');b.width=bevel;b.segments=4
        o.modifiers.new('Weighted armor normals','WEIGHTED_NORMAL');return o
    def ring(name,loc,major,minor,m,scale=(1,1,1)):
        bpy.ops.mesh.primitive_torus_add(major_radius=major,minor_radius=minor,major_segments=48,minor_segments=16);o=bpy.context.object;o.name=name;o.parent=root;o.location=loc;o.scale=scale;o.data.materials.append(m)
        for p in o.data.polygons:p.use_smooth=True
    for name in ['Jacket • zipper','Zip pull','Pocket • coral label']:
        o=bpy.data.objects.get(name)
        if o:o.hide_render=True;o.hide_set(True)
    for o in s.objects:
        if o.name.startswith(('Jacket • rounded','Trouser')):o.data.materials.clear();o.data.materials.append(navy)
        if o.name.startswith(('Sleeve ','Hand ','Thumb ','Sneaker upper','Cuff ')) or o.name.startswith('Peek hand '):
            o.data.materials.clear();o.data.materials.append(shell)
        if o.name.startswith('Sneaker '):o.data.materials.clear();o.data.materials.append(navy)
    bpy.data.objects['Collar • rolled'].data.materials.clear();bpy.data.objects['Collar • rolled'].data.materials.append(shell)
    ring('Suit • pressure collar seal',(0,-.025,1.68),.20,.035,navy,(1,.9,1))
    box('Suit • breastplate',(0,-.23,1.29),(.30,.075,.25),shell,.09)
    box('Suit • chest computer',(0,-.312,1.29),(.17,.035,.12),panel,.035)
    for x in [-.095,0,.095]:box('Suit • oxygen bar '+str(x),(x,-.354,1.30),(.025,.008,.05),cyan,.008)
    box('Suit • rescue tab',(.22,-.31,1.44),(.04,.014,.035),orange,.01)
    ring('Suit • waist belt',(0,.015,.91),.34,.055,shell,(1,.72,1))
    box('Suit • belt buckle',(0,-.245,.91),(.07,.033,.06),panel,.015)
    for x in [-1,1]:
        box('Suit • knee shell '+str(x),(x*.18,-.15,.60),(.12,.055,.12),shell,.045)
        box('Suit • boot toe '+str(x),(x*.18,-.245,.33),(.155,.13,.10),shell,.06)
        box('Suit • boot sole '+str(x),(x*.18,-.11,.21),(.18,.26,.035),navy,.035)
        arm=bpy.data.objects['CTRL_arm_L' if x==-1 else 'CTRL_arm_R']
        box('Suit • shoulder armor '+str(x),(x*.025,-.03,-.06),(.16,.17,.095),shell,.07,arm)
        box('Suit • cuff seal '+str(x),(x*.12,-.02,-.405),(.14,.15,.035),navy,.025,arm)
    s['clothing_notes']='Futuristic pressure suit: ceramic chest and shoulder plates, chest computer, oxygen indicators, pressure collar, flexible dark seals, gloves, knee shells and boot soles. Face/body proportions retained.'
apply_spacesuit()
