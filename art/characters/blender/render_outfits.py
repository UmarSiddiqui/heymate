import bpy,os,itertools,shutil,json
from mathutils import Vector
OUT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
colors={'hair':{'tide':(.022,.085,.115),'copper':(.31,.075,.025),'lilac':(.28,.15,.42)},'skin':{'sand':(.83,.51,.32),'caramel':(.62,.30,.17),'umber':(.27,.105,.06)},'eye':{'sea':(.05,.40,.43),'amber':(.57,.27,.035),'violet':(.26,.17,.57)}}
for outfit in ['classic','future']:
    bpy.ops.wm.open_mainfile(filepath=os.path.join(OUT,'blender','Milo-Classic.blend'))
    s=bpy.context.scene;s.frame_set(1)
    for o in s.objects:
        if o.name.startswith('Peek '):o.hide_set(True)
    for screen in bpy.data.screens:
        for a in screen.areas:
            if a.type=='VIEW_3D':a.spaces.active.overlay.show_overlays=False;a.spaces.active.shading.type='MATERIAL';a.spaces.active.region_3d.view_perspective='CAMERA'
    if outfit=='future':exec(compile(open(os.path.join(OUT,'blender','future_outfit.py')).read(),'future_outfit.py','exec'))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT,'blender','Milo-'+outfit.title()+'.blend'))
    if outfit=='future':
        for n,f in {'idle':1,'wave':16,'think':40,'blink':58,'celebrate':76}.items():
            s.frame_set(f);s.render.filepath=os.path.join(OUT,'renders','milo-future-'+n+'.png');bpy.ops.render.render(write_still=True)
        s.frame_set(1)
    s.render.resolution_x=550;s.render.resolution_y=610;s.cycles.samples=16
    for style,hair,skin,eye in itertools.product(['sweep','crop'],colors['hair'],colors['skin'],colors['eye']):
        for key,label,name in [('hair',hair,'Deep tide • hair'),('skin',skin,'Warm caramel • skin'),('eye',eye,'Sea glass • iris')]:
            c=colors[key][label];m=bpy.data.materials[name];m.diffuse_color=(*c,1);m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=(*c,1)
        for o in s.objects:
            if o.name.startswith('Hair • swept lock') or o.name=='Hair • subtle part':o.hide_render=style=='crop'
        s.render.filepath=os.path.join(OUT,'renders',f'body-{style}-{hair}-{skin}-{eye}-{outfit}.png');bpy.ops.render.render(write_still=True)
    if outfit=='future':
        # Restore original look for the composer-specific future bust.
        bpy.ops.wm.open_mainfile(filepath=os.path.join(OUT,'blender','Milo-Future.blend'));s=bpy.context.scene;s.frame_set(1);head=bpy.data.objects['CTRL_head']
        for o in s.objects:
            if o.type not in ['MESH','CURVE']:continue
            p=o.parent;belongs=False
            while p:
                if p==head:belongs=True
                p=p.parent
            o.hide_render=not belongs
            if o.name.startswith('Peek '):o.hide_render=False
        cam=s.camera;cam.location=(.25,-10,2.9);cam.rotation_euler=(Vector((0,0,2.39))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=1.95
        s.render.resolution_x=900;s.render.resolution_y=800;s.render.filepath=os.path.join(OUT,'renders','milo-future-peek.png');bpy.ops.render.render(write_still=True)
with open(os.path.join(OUT,'blender','outfit-manifest.json'),'w') as f:json.dump({'outfits':['classic','future'],'body_renders':108,'future_poses':6,'reference':'https://tamashiiweb.com/topics/detail/tn_blog_187.html?wovn=en'},f,indent=2)
