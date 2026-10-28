#include <metal_stdlib>
using namespace metal;

struct VertexIn { packed_float3 position; packed_float3 normal; packed_float2 uv; packed_float4 color; };
struct FrameUniforms { float4x4 viewProjection; float4 eye; float4 style; };
struct ObjectUniforms {
    float4x4 model; float4 normal0; float4 normal1; float4 normal2;
    float4 baseColor; float4 emissive; float4 surface; float4 flags; float4 cut; float4 bands[16];
};
struct VertexOut {
    float4 position [[position]];
    float3 worldPosition; float3 normal; float2 uv; float4 color;
};

vertex VertexOut davinci_vertex(uint vertexID [[vertex_id]],
                                const device VertexIn *vertices [[buffer(0)]],
                                constant FrameUniforms &frame [[buffer(1)]],
                                constant ObjectUniforms &object [[buffer(2)]]) {
    VertexIn in = vertices[vertexID];
    float4 world = object.model * float4(float3(in.position), 1.0);
    float3x3 normalMatrix = float3x3(object.normal0.xyz, object.normal1.xyz, object.normal2.xyz);
    VertexOut out;
    out.position = frame.viewProjection * world;
    out.worldPosition = world.xyz;
    out.normal = normalize(normalMatrix * float3(in.normal));
    out.uv = float2(in.uv);
    out.color = float4(in.color);
    return out;
}

constant float RECIPROCAL_PI = 0.3183098861837907;

// three.js lighting (r15x physical lights): GGX specular, Lambert diffuse.
float D_GGX(float alpha, float dotNH) {
    float a2 = alpha * alpha;
    float denominator = dotNH * dotNH * (a2 - 1.0) + 1.0;
    return RECIPROCAL_PI * a2 / (denominator * denominator);
}
float V_GGX_SmithCorrelated(float alpha, float dotNL, float dotNV) {
    float a2 = alpha * alpha;
    float gv = dotNL * sqrt(a2 + (1.0 - a2) * dotNV * dotNV);
    float gl = dotNV * sqrt(a2 + (1.0 - a2) * dotNL * dotNL);
    return 0.5 / max(gv + gl, 1e-6);
}
float3 F_Schlick(float3 f0, float f90, float dotVH) {
    float fresnel = exp2((-5.55473 * dotVH - 6.98316) * dotVH);
    return f0 * (1.0 - fresnel) + f90 * fresnel;
}
float3 BRDF_GGX(float3 lightDirection, float3 viewDirection, float3 normal, float3 specularColor, float roughness) {
    float alpha = roughness * roughness;
    float3 halfDirection = normalize(lightDirection + viewDirection);
    float dotNL = saturate(dot(normal, lightDirection));
    float dotNV = saturate(dot(normal, viewDirection));
    float dotNH = saturate(dot(normal, halfDirection));
    float dotVH = saturate(dot(viewDirection, halfDirection));
    return F_Schlick(specularColor, 1.0, dotVH) * (V_GGX_SmithCorrelated(alpha, dotNL, dotNV) * D_GGX(alpha, dotNH));
}
float3 sRGBFromLinear(float3 value) {
    return mix(pow(max(value, 0.0), float3(0.41666)) * 1.055 - 0.055, value * 12.92, float3(value <= 0.0031308));
}

fragment float4 davinci_fragment(VertexOut in [[stage_in]], bool isFrontFacing [[front_facing]],
                                 constant FrameUniforms &frame [[buffer(1)]],
                                 constant ObjectUniforms &object [[buffer(2)]]) {
    float3 normal = normalize(in.normal);
    if (object.flags.y > 0.5) {
        normal = normalize(cross(dfdx(in.worldPosition), dfdy(in.worldPosition)));
        if (dot(normal, frame.eye.xyz - in.worldPosition) < 0.0) normal = -normal;
    } else if (object.flags.z > 0.5 && !isFrontFacing) {
        normal = -normal;
    }
    float4 base = object.baseColor;
    if (object.flags.x > 0.5) base.rgb *= in.color.rgb;
    int bandCount = int(object.surface.w);
    if (bandCount > 0) {
        int band = clamp(int(floor((1.0 - in.uv.y) * float(bandCount))), 0, bandCount - 1);
        base.rgb *= object.bands[band].rgb;
    }
    float metalness = object.surface.y;
    float3 diffuseColor = base.rgb * (1.0 - metalness);
    float3 specularColor = mix(float3(0.04), base.rgb, metalness);
    float3 geometryNormal = normalize(in.normal);
    float3 variation = max(abs(dfdx(geometryNormal)), abs(dfdy(geometryNormal)));
    float roughness = min(max(object.surface.x, 0.0525) + max(max(variation.x, variation.y), variation.z), 1.0);

    float3 viewDirection = normalize(frame.eye.xyz - in.worldPosition);
    if (frame.style.x > 0.5) {
        // Mate's illustrated look, like its marker drawings: the colour flat where the light
        // falls, one cool darker tone where it does not (a soft edge between), a small white
        // highlight on glossy parts, metal with a deeper shade and a brighter shine.
        float3 light = normalize(frame.style.yzw);
        float facing = dot(normal, light);
        float lit = smoothstep(-0.08, 0.14, facing);
        float3 colour = base.rgb;
        float3 shade = colour * mix(float3(0.50, 0.53, 0.66), float3(0.30, 0.32, 0.42), metalness);
        float3 tone = mix(shade, colour, lit);
        // Turned right away from the light: a touch deeper still, so round things stay round.
        tone *= mix(0.86, 1.0, smoothstep(-0.75, -0.35, facing));
        float3 halfway = normalize(light + viewDirection);
        float shininess = saturate(1.0 - object.surface.x);
        float highlight = smoothstep(0.985 - 0.06 * metalness - 0.03 * (1.0 - shininess), 0.995 - 0.06 * metalness, dot(normal, halfway));
        tone = mix(tone, float3(1.0), highlight * (0.35 + 0.55 * shininess));
        tone += object.emissive.rgb;
        return float4(sRGBFromLinear(tone), base.a * object.surface.z);
    }
    // Hemisphere light: sky white, ground #3a4658, intensity 1.2 (indirect diffuse).
    float3 sky = float3(1.0) * 1.2;
    float3 ground = float3(0.04231, 0.06124, 0.09758) * 1.2;
    float3 irradiance = mix(ground, sky, 0.5 * normal.y + 0.5);
    float3 outgoing = irradiance * diffuseColor * RECIPROCAL_PI;
    // Key light: white × 2.2 from (3, 5, 4). Rim light: #9fc4ff × 0.9 from (-4, 2, -4).
    float3 directions[2] = { normalize(float3(3.0, 5.0, 4.0)), normalize(float3(-4.0, 2.0, -4.0)) };
    float3 colors[2] = { float3(2.2), float3(0.34670, 0.55201, 1.0) * 0.9 };
    for (int index = 0; index < 2; index++) {
        float dotNL = saturate(dot(normal, directions[index]));
        float3 lightIrradiance = dotNL * colors[index];
        outgoing += lightIrradiance * diffuseColor * RECIPROCAL_PI;
        outgoing += lightIrradiance * BRDF_GGX(directions[index], viewDirection, normal, specularColor, roughness);
    }
    outgoing += object.emissive.rgb;
    return float4(sRGBFromLinear(outgoing), base.a * object.surface.z);
}

// The ink outline: a full-screen triangle; every pixel within half a pen
// width of a change of part id (in either grid) is inked, edges antialiased.
// The outline round the object (a part against nothing) and the seams
// between parts can take different pens (InkOutline.seamWidth/seamStrength);
// with the same pen it is the one outline it always was.
struct OutlineUniforms { float4 color; float halfWidth; float seamHalfWidth; float seamStrength; float seamShade; };

vertex float4 davinci_outline_vertex(uint vid [[vertex_id]]) {
    float2 corner = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
    return float4(corner, 0.0, 1.0);
}

/// How far (pixels) the nearest change of part id is, against nothing (x) and between parts (y): the pixels round it
/// nearest first, each once (DaVinci3DRenderer.edgeNeighbours: x, y, how far it counts).
float2 nearestEdges(int2 p, constant float4 *neighbours, uint neighbourCount, bool readsClear, texture2d<uint> opaqueIDs, texture2d<uint> clearIDs) {
    int2 size = int2(opaqueIDs.get_width(), opaqueIDs.get_height());
    uint a = opaqueIDs.read(uint2(p)).r, b = readsClear ? clearIDs.read(uint2(p)).r : 0u;
    float2 nearest = float2(1e9);
    // Independent reads let the texture unit work ahead of the distance reduction. The table is sorted by ring
    // distance, so scanning it all gives the same minima as stopping once both edges have been found.
    uint index = 0;
    for (; index + 4 <= neighbourCount; index += 4) {
        uint4 opaque, clear = uint4(b);
        float4 distances;
        #pragma unroll
        for (uint lane = 0; lane < 4; lane++) {
            float4 neighbour = neighbours[index + lane];
            int2 q = clamp(p + int2(neighbour.xy), int2(0), size - 1);
            opaque[lane] = opaqueIDs.read(uint2(q)).r;
            if (readsClear) clear[lane] = clearIDs.read(uint2(q)).r;
            distances[lane] = neighbour.z;
        }
        bool4 changed = (opaque != a) || (clear != b);
        bool4 silhouette = (opaque == 0u) != (a == 0u);
        float4 outside = select(float4(1e9), distances, changed && silhouette);
        float4 inside = select(float4(1e9), distances, changed && !silhouette);
        nearest = min(nearest, float2(min(min(outside.x, outside.y), min(outside.z, outside.w)),
                                      min(min(inside.x, inside.y), min(inside.z, inside.w))));
    }
    for (; index < neighbourCount; index++) {
        float4 neighbour = neighbours[index];
        int2 q = clamp(p + int2(neighbour.xy), int2(0), size - 1);
        uint qa = opaqueIDs.read(uint2(q)).r, qb = readsClear ? clearIDs.read(uint2(q)).r : 0u;
        if (qa != a || qb != b) {
            if ((qa == 0u) != (a == 0u)) nearest.x = min(nearest.x, neighbour.z);
            else nearest.y = min(nearest.y, neighbour.z);
        }
    }
    return nearest;
}

fragment float4 davinci_outline_fragment(float4 position [[position]], constant OutlineUniforms& u [[buffer(0)]],
                                         constant float4 *neighbours [[buffer(1)]], constant uint &neighbourCount [[buffer(2)]],
                                         constant uint &readsClear [[buffer(3)]],
                                         texture2d<uint> opaqueIDs [[texture(0)]], texture2d<uint> clearIDs [[texture(1)]]) {
    float2 nearest = nearestEdges(int2(position.xy), neighbours, neighbourCount, readsClear != 0u, opaqueIDs, clearIDs);
    float coverage = max(saturate(u.halfWidth - nearest.x + 1.0), u.seamStrength * saturate(u.seamHalfWidth - nearest.y + 1.0));
    return u.color * coverage;
}

// The outline in ink (over what is there) and the seams in a shade of each part's own colour, in one pass: the blend
// multiplies what is there by the second output, so colour = ink * shade + what is there * (1 - ink's alpha) * shade
// (what the two passes this replaced gave, but for rounding between them).
struct InkAndSeam { float4 color [[color(0), index(0)]]; float4 factor [[color(0), index(1)]]; };
fragment InkAndSeam davinci_ink_and_seam_fragment(float4 position [[position]], constant OutlineUniforms& u [[buffer(0)]],
                                                  constant float4 *neighbours [[buffer(1)]], constant uint &neighbourCount [[buffer(2)]],
                                                  constant uint &readsClear [[buffer(3)]],
                                                  texture2d<uint> opaqueIDs [[texture(0)]], texture2d<uint> clearIDs [[texture(1)]]) {
    float2 nearest = nearestEdges(int2(position.xy), neighbours, neighbourCount, readsClear != 0u, opaqueIDs, clearIDs);
    float4 ink = u.color * saturate(u.halfWidth - nearest.x + 1.0);
    float shade = 1.0 - u.seamStrength * saturate(u.seamHalfWidth - nearest.y + 1.0) * (1.0 - u.seamShade);
    InkAndSeam out;
    out.color = float4(ink.rgb * shade, ink.a);
    out.factor = float4(float3((1.0 - ink.a) * shade), 1.0 - ink.a);
    return out;
}

fragment uint davinci_uncut_id_fragment(constant uint &identifier [[buffer(3)]]) {
    return identifier;
}

// A part's id; a cut part's ids stop at its cut (the side taken away isn't there), and what shows through the
// opening (its inside) gets an id of its own, so the pen draws round the cut face too.
fragment uint davinci_picking_fragment(VertexOut in [[stage_in]], bool isFrontFacing [[front_facing]],
                                       constant ObjectUniforms &object [[buffer(2)]], constant uint &identifier [[buffer(3)]]) {
    if (dot(object.cut.xyz, object.cut.xyz) > 0.25) {
        if (dot(in.worldPosition, object.cut.xyz) > object.cut.w) discard_fragment();
        if (!isFrontFacing && object.flags.z < 0.5) return identifier | 0x80000000u;
    }
    return identifier;
}