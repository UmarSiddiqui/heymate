// HeyMate's 3D shading, compiled at run time by DaVinciMetalRenderer.swift. The surface shading between the
// "shared" markers is plain math that mate-stage3d.js runs as GLSL for browser stages (scripts/stage3d_tests.mjs
// checks the two stay the same); the entry points around it are Metal's.
//
// Passes: mate_vertex places a part; mate_shade colours it (DaVinciMetalRenderer.swift's heymate_surface calls it
// and adds the cut-away); mate_part_id_fragment writes each part's id for the ink; mate_ink_vertex and
// mate_ink_and_seam_fragment then ink the outline round the figure and shade the seams between its parts.
#include <metal_stdlib>
using namespace metal;

// The layouts DaVinciMetalRenderer.swift packs, float by float (it fills them in this order; the names are ours).
// One corner of a mesh.
struct MeshVertex { packed_float3 at; packed_float3 facing; packed_float2 texcoord; packed_float4 tint; };
// The camera: world to clip space, where the eye is, and the look (x: 1 illustrated, 0 studio; yzw: toward the key light).
// Then the key light's own view of the figure, for the shadows parts cast on each other, and how to read it
// (x: 1 when there is one, y: how far along its normal a point steps before looking, z: one texel, w: depth slack).
struct View { float4x4 toClip; float4 eye; float4 look; float4x4 toKey; float4 shadow; };
// One part: where it is (and its normals' turn, a 3x3 in three rows), its colours and finish, and what it does.
struct Part {
    float4x4 placement; float4 turnRow0; float4 turnRow1; float4 turnRow2;
    float4 colour; float4 glow;
    float4 finish;      // roughness, metalness, opacity, number of stripes
    float4 options;     // uses vertex colours?, flat?, both sides?, unused
    float4 cutPlane;    // the plane's normal and offset: what lies past it is cut away
    float4 stripes[16]; // the colours of its horizontal stripes, top to bottom
};
// A point on a part's surface, between the two stages.
struct Surface {
    float4 clip [[position]];
    float3 world; float3 normal; float2 texcoord; float4 tint;
};

vertex Surface mate_vertex(uint index [[vertex_id]],
                           const device MeshVertex *mesh [[buffer(0)]],
                           constant View &view [[buffer(1)]],
                           constant Part &part [[buffer(2)]]) {
    MeshVertex corner = mesh[index];
    float3x3 turn = float3x3(part.turnRow0.xyz, part.turnRow1.xyz, part.turnRow2.xyz);
    Surface s;
    float4 world = part.placement * float4(float3(corner.at), 1.0);
    s.world = world.xyz;
    s.clip = view.toClip * world;
    s.normal = normalize(turn * float3(corner.facing));
    s.texcoord = float2(corner.texcoord);
    s.tint = float4(corner.tint);
    return s;
}

// ---- shared with mate-stage3d.js ----
// Colours are linear until the end. Two looks: illustrated, the way Mate draws with markers (the colour flat where
// the light falls, a cooler darker tone where it does not, a small hard highlight), and studio (soft physically
// based light: a sky above, a dark floor below, a key light and a cool rim light from behind).

float to_srgb_channel(float x) {
    return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
}
float3 to_srgb(float3 c) {
    c = max(c, float3(0.0));
    return float3(to_srgb_channel(c.x), to_srgb_channel(c.y), to_srgb_channel(c.z));
}

// The normal to light with: the face's own normal for flat-shaded parts (turned to the eye), the far side's
// normal turned round for double-sided parts seen from behind.
float3 lit_normal(float3 normal, float3 position, float3 eye, bool flatShading, bool doubleSided, bool front) {
    if (flatShading) {
        float3 n = normalize(cross(dfdx(position), dfdy(position)));
        return dot(n, eye - position) < 0.0 ? -n : n;
    }
    float3 n = normalize(normal);
    return (doubleSided && !front) ? -n : n;
}

float3 illustrated_tone(float3 colour, float3 n, float3 v, float3 light, float roughness, float metalness) {
    float facing = dot(n, light);
    // where the light falls, with a soft edge just past the terminator
    float lit = smoothstep(-0.1, 0.12, facing);
    float3 shadow = colour * mix(float3(0.54, 0.57, 0.70), float3(0.33, 0.35, 0.46), metalness);
    float3 tone = mix(shadow, colour, lit);
    // the side turned right away from the light a little deeper, so round things read as round
    tone *= mix(0.84, 1.0, smoothstep(-0.8, -0.3, facing));
    // a faint lift along the edges facing away from the eye, on the lit side
    float edge = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 3.0);
    tone = mix(tone, float3(1.0), 0.10 * edge * lit);
    // one small highlight: smaller and sharper the smoother the part, a little wider on metal
    float3 h = normalize(light + v);
    float gloss = clamp(1.0 - roughness, 0.0, 1.0);
    float size = 0.012 + 0.03 * roughness + 0.05 * metalness;
    float spot = smoothstep(1.0 - size, 1.0 - size * 0.35, dot(n, h));
    return mix(tone, float3(1.0), spot * (0.3 + 0.6 * gloss));
}

// GGX microfacets: distribution, height-correlated Smith visibility and Schlick's Fresnel.
float ggx_distribution(float a2, float nh) {
    float d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (3.14159265 * d * d);
}
float smith_visibility(float a2, float nl, float nv) {
    float l = nv * sqrt(nl * nl * (1.0 - a2) + a2);
    float w = nl * sqrt(nv * nv * (1.0 - a2) + a2);
    return 0.5 / max(l + w, 1e-5);
}
float3 schlick_fresnel(float3 f0, float vh) {
    float k = pow(1.0 - vh, 5.0);
    return f0 + (float3(1.0) - f0) * k;
}
float3 studio_light(float3 n, float3 v, float3 l, float3 radiance, float3 diffuse, float3 f0, float a2) {
    float nl = clamp(dot(n, l), 0.0, 1.0);
    if (nl <= 0.0) return float3(0.0);
    float3 h = normalize(l + v);
    float nv = max(dot(n, v), 1e-4), nh = clamp(dot(n, h), 0.0, 1.0), vh = clamp(dot(v, h), 0.0, 1.0);
    float3 specular = schlick_fresnel(f0, vh) * (ggx_distribution(a2, nh) * smith_visibility(a2, nl, nv));
    return radiance * nl * (diffuse / 3.14159265 + specular);
}
// What a polished part reflects: a studio with a pale ceiling, a softbox overhead and a little to the front, a cool
// strip light to one side, grey walls and a dark floor. blur (the part's roughness) widens every edge in it.
float3 studio_room(float3 d, float blur) {
    float edge = mix(0.06, 0.7, blur);
    float3 c = mix(float3(0.10, 0.105, 0.12), float3(0.54, 0.56, 0.61), smoothstep(-edge, edge, d.y + 0.08));
    c = mix(c, float3(0.95, 0.96, 1.0), smoothstep(0.35 - edge, 0.8 + edge, d.y));
    float box = dot(d, normalize(float3(-0.35, 0.8, 0.5)));
    c += float3(1.6, 1.58, 1.5) * smoothstep(0.9 - edge * 0.6, 0.96 + edge * 0.04, box) * mix(1.0, 0.35, blur);
    float beside = dot(normalize(d.xz + 0.0001), normalize(float2(0.9, -0.45)));
    float strip = smoothstep(0.82 - edge * 0.5, 0.9, beside) * (1.0 - smoothstep(0.0, 0.45 + edge, abs(d.y - 0.1)));
    c += float3(0.7, 0.78, 0.95) * strip * mix(1.0, 0.3, blur);
    return c;
}
// keyLight: how much of the key light reaches this point (0 in another part's shadow, 1 in the open).
float3 studio_tone(float3 colour, float3 n, float3 geometryNormal, float3 v, float3 key, float roughness, float metalness, float keyLight) {
    float3 diffuse = colour * (1.0 - metalness);
    float3 f0 = mix(float3(0.04), colour, metalness);
    // rougher where the surface curves fast across a pixel, so highlights don't sparkle on small curved parts
    float3 bend = fwidth(geometryNormal);
    float r = clamp(roughness + max(bend.x, max(bend.y, bend.z)), 0.06, 1.0);
    float a2 = r * r * r * r;
    float3 sky = float3(1.15), ground = float3(0.10, 0.115, 0.15);
    // a part's shadow also takes a little of the sky's light, so it reads on a pale surface
    float3 c = mix(ground, sky, 0.5 + 0.5 * n.y) * diffuse / 3.14159265 * (0.62 + 0.38 * keyLight);
    // the room, mirrored in the part: what makes a metal read as metal. How much of it a surface returns at this
    // angle and roughness is the usual fitted curve (Karis), not a lookup table.
    float nv = clamp(dot(n, v), 0.0, 1.0);
    float4 k = r * float4(-1.0, -0.0275, -0.572, 0.022) + float4(1.0, 0.0425, 1.04, -0.04);
    float a004 = min(k.x * k.x, exp2(-9.28 * nv)) * k.x + k.y;
    float2 ab = float2(-1.04, 1.04) * a004 + k.zw;
    c += studio_room(reflect(-v, n), r) * (f0 * ab.x + ab.y);
    c += keyLight * studio_light(n, v, normalize(key), float3(2.1), diffuse, f0, a2);
    c += studio_light(n, v, normalize(float3(-4.0, 2.0, -4.0)), float3(0.33, 0.48, 0.86), diffuse, f0, a2);
    return c;
}

// A part's colour on screen (sRGB) and its opacity.
float4 shade_surface(float3 position, float3 normal, bool front, float3 eye, float4 style,
                     float3 colour, float3 emissive, float4 surface, float4 flags, float keyLight) {
    float3 n = lit_normal(normal, position, eye, flags.y > 0.5, flags.z > 0.5, front);
    float3 v = normalize(eye - position);
    float3 c = style.x > 0.5
        ? illustrated_tone(colour, n, v, normalize(style.yzw), surface.x, surface.y)
        : studio_tone(colour, n, normalize(normal), v, style.yzw, surface.x, surface.y, keyLight);
    return float4(to_srgb(c + emissive), surface.z);
}
// ---- end shared ----

// The colour of the stripe a point is in (white for a part without stripes).
float3 stripe_colour(float2 texcoord, constant Part &part) {
    int count = int(part.finish.w);
    if (count <= 0) return float3(1.0);
    return part.stripes[clamp(int(floor((1.0 - texcoord.y) * float(count))), 0, count - 1)].rgb;
}

// How much of the key light reaches a point: 1 in the open, less where another part stands in the way. Nine looks
// at the key light's depth map, each already smoothed by the sampler, give the shadow a soft edge.
float key_reach(float3 world, float3 normal, constant View &view, depth2d<float> keyShadows, sampler compare) {
    if (view.shadow.x < 0.5) return 1.0;
    float4 p = view.toKey * float4(world + normalize(normal) * view.shadow.y, 1.0);
    float2 uv = float2(p.x, -p.y) * 0.5 + 0.5;
    float depth = min(p.z - view.shadow.w, 0.9999);
    float lit = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            lit += keyShadows.sample_compare(compare, uv + float2(x, y) * view.shadow.z * 1.5, depth);
        }
    }
    return mix(0.1, 1.0, lit / 9.0);
}

float4 mate_shade(Surface in, bool front, constant View &view, constant Part &part,
                  depth2d<float> keyShadows, sampler compare) {
    float3 colour = part.colour.rgb * stripe_colour(in.texcoord, part) * (part.options.x > 0.5 ? in.tint.rgb : float3(1.0));
    float3 facing = (part.options.z > 0.5 && !front) ? -in.normal : in.normal;
    float keyLight = key_reach(in.world, facing, view, keyShadows, compare);
    float4 shaded = shade_surface(in.world, in.normal, front, view.eye.xyz, view.look, colour, part.glow.rgb, part.finish, part.options, keyLight);
    return float4(shaded.rgb, shaded.a * part.colour.a);
}

// What a light sees of a part: only its depth, stopping at its cut.
fragment void mate_shadow_fragment(Surface in [[stage_in]], constant Part &part [[buffer(2)]]) {
    bool cut = dot(part.cutPlane.xyz, part.cutPlane.xyz) > 0.25;
    if (cut && dot(in.world, part.cutPlane.xyz) > part.cutPlane.w) discard_fragment();
}

// A different number for every pixel, evenly spread: turns each pixel's ring of looks so their pattern never shows.
float pixel_turn(float2 pixel) {
    return 6.2831853 * fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
}

// The ground under a figure: nothing but the soft shadow that sits it down. `fromBelow` is the figure seen from the
// ground looking up, so each spot knows how far above it the nearest part is: dark and tight under what touches
// the ground, faint and wide under what hangs high.
struct Ground {
    float4x4 fromBelow;
    float4 place;   // the middle (x, the ground's height, z) and how far the ground reaches from it
    float4 shade;   // the height the view from below spans, the darkest the shadow gets, its blur, the height it fades over
};
struct GroundPoint { float4 clip [[position]]; float3 world; };

vertex GroundPoint mate_ground_vertex(uint vid [[vertex_id]], constant View &view [[buffer(1)]], constant Ground &ground [[buffer(2)]]) {
    float2 corner = float2(float(vid & 1u), float(vid >> 1u)) * 2.0 - 1.0;
    GroundPoint g;
    g.world = float3(ground.place.x + corner.x * ground.place.w, ground.place.y, ground.place.z + corner.y * ground.place.w);
    g.clip = view.toClip * float4(g.world, 1.0);
    return g;
}

fragment float4 mate_ground_fragment(GroundPoint in [[stage_in]], constant Ground &ground [[buffer(2)]],
                                     depth2d<float> above [[texture(1)]], sampler nearest [[sampler(1)]]) {
    float4 p = ground.fromBelow * float4(in.world, 1.0);
    float2 uv = float2(p.x, -p.y) * 0.5 + 0.5;
    float dark = 0.0, total = 0.0;
    for (int i = 0; i < 40; i++) {
        float t = (float(i) + 0.5) / 40.0, turn = float(i) * 2.39996323 + pixel_turn(in.clip.xy);
        float2 beside = float2(cos(turn), sin(turn)) * sqrt(t) * ground.shade.z;
        float depth = above.sample(nearest, uv + beside);
        float weight = 1.0 - 0.6 * t;
        dark += depth < 0.9999 ? weight * exp(-depth * ground.shade.x / ground.shade.w) : 0.0;
        total += weight;
    }
    float fade = 1.0 - smoothstep(0.5, 1.0, length((in.world.xz - ground.place.xz) / ground.place.w));
    return float4(0.0, 0.0, 0.0, ground.shade.y * fade * dark / total);
}

// Each part's id, for the ink. A cut part stops at its cut, and the inside seen through the opening gets an id of
// its own (the high bit), so the pen also draws round the cut face.
fragment uint mate_part_id_fragment(Surface in [[stage_in]], bool front [[front_facing]],
                                    constant Part &part [[buffer(2)]], constant uint &identifier [[buffer(3)]]) {
    bool cut = dot(part.cutPlane.xyz, part.cutPlane.xyz) > 0.25;
    if (cut && dot(in.world, part.cutPlane.xyz) > part.cutPlane.w) discard_fragment();
    return cut && !front && part.options.z < 0.5 ? (identifier | 0x80000000u) : identifier;
}

// The ink: one triangle over the whole target. A pixel near a change of part id is inked: near the figure's edge
// (a part against nothing) in the ink colour, near a seam between parts as a shade of the parts' own colour.
// Then the contact shade: how dark it gets where parts meet or fold inward, and how far round a pixel it looks.
struct Pen { float4 ink; float halfWidth; float seamHalfWidth; float seamStrength; float seamShade; float contact; float contactReach; float unused0; float unused1; };

vertex float4 mate_ink_vertex(uint vid [[vertex_id]]) {
    return float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0.0, 1.0);
}

// How far the nearest edge (x) and the nearest seam (y) are, in pixels. `offsets` lists the pixels round this one
// (x, y, distance), nearest first, so the search stops once both are found or nothing further could be inked.
float2 nearest_changes(int2 p, float reach, constant float4 *offsets, uint count, bool hasClearLayer,
                       texture2d<uint> solidParts, texture2d<uint> clearParts) {
    int2 last = int2(solidParts.get_width(), solidParts.get_height()) - 1;
    uint here = solidParts.read(uint2(p)).r, hereClear = hasClearLayer ? clearParts.read(uint2(p)).r : 0u;
    float2 nearest = float2(1e9);
    for (uint i = 0; i < count; i++) {
        float4 o = offsets[i];
        if (o.z > reach || (nearest.x < 1e9 && nearest.y < 1e9)) break;
        uint2 q = uint2(clamp(p + int2(o.xy), int2(0), last));
        uint there = solidParts.read(q).r, thereClear = hasClearLayer ? clearParts.read(q).r : 0u;
        if (there == here && thereClear == hereClear) continue;
        if ((there == 0u) != (here == 0u)) nearest.x = min(nearest.x, o.z);
        else nearest.y = min(nearest.y, o.z);
    }
    return nearest;
}

// How open a pixel is to the room: 1 on a flat or outward-turning surface, less in a crease, under an overhang or
// where one part meets another. Read from depth alone: across a flat surface 1 - depth changes evenly, so a pixel
// whose neighbours on opposite sides are, between them, nearer than it is sits in a hollow.
float contact_shade(uint2 p, float reach, float strength, depth2d<float> depths) {
    float here = 1.0 - depths.read(p);
    if (strength <= 0.0 || here <= 0.0) return 1.0;
    int2 last = int2(depths.get_width(), depths.get_height()) - 1;
    float hollow = 0.0;
    for (int i = 0; i < 16; i++) {
        float turn = float(i) * 2.39996323 + pixel_turn(float2(p)), far = reach * sqrt((float(i) + 0.5) / 16.0);
        int2 o = int2(round(float2(cos(turn), sin(turn)) * far));
        float a = 1.0 - depths.read(uint2(clamp(int2(p) + o, int2(0), last)));
        float b = 1.0 - depths.read(uint2(clamp(int2(p) - o, int2(0), last)));
        float nearer = ((a + b) * 0.5 - here) / here;
        hollow += smoothstep(0.0008, 0.014, nearer) * (1.0 - smoothstep(0.02, 0.06, nearer));
    }
    return 1.0 - strength * hollow / 16.0;
}

// Ink over what is there, seams darkening it: blended as colour + destination * factor (dual-source).
struct InkBlend { float4 add [[color(0), index(0)]]; float4 keep [[color(0), index(1)]]; };
fragment InkBlend mate_ink_and_seam_fragment(float4 position [[position]], constant Pen &u [[buffer(0)]],
                                               constant float4 *offsets [[buffer(1)]], constant uint &count [[buffer(2)]],
                                               constant uint &hasClearLayer [[buffer(3)]],
                                               texture2d<uint> solidParts [[texture(0)]], texture2d<uint> clearParts [[texture(1)]],
                                               depth2d<float> depths [[texture(2)]]) {
    float reach = max(u.halfWidth, u.seamStrength > 0.0 ? u.seamHalfWidth : 0.0) + 1.0;
    float2 nearest = nearest_changes(int2(position.xy), reach, offsets, count, hasClearLayer != 0u, solidParts, clearParts);
    float4 ink = u.ink * saturate(u.halfWidth + 1.0 - nearest.x);
    float seam = 1.0 - u.seamStrength * (1.0 - u.seamShade) * saturate(u.seamHalfWidth + 1.0 - nearest.y);
    seam *= contact_shade(uint2(position.xy), u.contactReach, u.contact, depths);
    float through = 1.0 - ink.a;
    InkBlend blend;
    blend.add = float4(ink.rgb * seam, ink.a);
    blend.keep = float4(through * seam, through * seam, through * seam, through);
    return blend;
}
