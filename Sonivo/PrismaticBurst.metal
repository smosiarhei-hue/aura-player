// Native adaptation of React Bits / PrismaticBurst by David Haz (2026).
// Source: https://github.com/DavidHDev/react-bits (ca44b3f9ee180676a06d7de8ec6bea84cddff85b).
// MIT + Commons Clause; full notice: ThirdPartyNotices/ReactBits-PrismaticBurst-LICENSE.md.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float prismaticHash(float2 p) {
    return fract(52.9829189f * fract(dot(floor(p), float2(0.065f, 0.005f))));
}
static float prismaticNoise(float2 frag, float time) {
    float2 p = frag + float2(time * 30.0f, -time * 21.0f);
    p -= 1024.0f * floor(p / 1024.0f);
    float2 q = float2x2(float2(0.8f, -0.5f), float2(0.5f, 0.8f)) * p;
    return 0.40f * prismaticHash(q) + 0.25f * prismaticHash(q * 2.0f + 17.0f)
         + 0.20f * prismaticHash(q * 4.0f + 47.0f) + 0.10f * prismaticHash(q * 8.0f + 113.0f)
         + 0.05f * prismaticHash(q * 16.0f + 191.0f);
}
static float3x3 prismaticRotX(float a) {
    float c = cos(a), s = sin(a);
    return float3x3(float3(1,0,0), float3(0,c,-s), float3(0,s,c));
}
static float3x3 prismaticRotY(float a) {
    float c = cos(a), s = sin(a);
    return float3x3(float3(c,0,s), float3(0,1,0), float3(-s,0,c));
}
static float3x3 prismaticRotZ(float a) {
    float c = cos(a), s = sin(a);
    return float3x3(float3(c,-s,0), float3(s,c,0), float3(0,0,1));
}
static float2 prismaticRot2(float2 v, float a) {
    return float2x2(float2(cos(a), -sin(a)), float2(sin(a), cos(a))) * v;
}
static float prismaticBend(float3 q, float t) {
    return 0.8f * sin(q.x * 0.55f + t * 0.6f) + 0.7f * sin(q.y * 0.50f - t * 0.5f)
         + 0.6f * sin(q.z * 0.60f + t * 0.7f);
}
[[ stitchable ]] half4 prismaticBurst(
    float2 position, half4 currentColor, float4 bounds,
    float time, float kick, float bass, float mids, half4 colorA, half4 colorB, half4 colorC
) {
    float2 res = max(bounds.zw, float2(1.0f));
    float2 frag = position - bounds.xy;
    frag.y = res.y - frag.y;
    float impact = clamp(kick, 0.0f, 1.0f);
    float low = clamp(bass, 0.0f, 1.0f);
    float t = time * 0.5f;
    // Beat deforms the ray field with compression/release, without time jumps.
    float focal = res.y * (1.0f + impact * 0.16f + low * 0.08f);
    float3 dir = normalize(float3(2.0f * frag - res, focal));
    float3x3 rotation = prismaticRotZ(t * 0.17f + impact * 0.08f)
        * prismaticRotY(t * 0.21f) * prismaticRotX(t * 0.31f);
    float noise = prismaticNoise(frag, time);
    float amp = 0.04f + impact * 0.16f + clamp(mids, 0.0f, 1.0f) * 0.05f;
    float marchT = 0.0f;
    float3 col = float3(0.0f);
    for (int i = 0; i < 44; i++) {
        float3 P = marchT * dir;
        P.z -= 2.0f;
        float rad = length(P);
        float3 Pl = rotation * (P * (10.0f / max(rad, 1e-6f)));
        float stepLen = max(0.02f, min(rad - 0.3f, noise * 0.018f) + 0.1f);
        float grow = smoothstep(0.35f, 3.0f, marchT);
        float a1 = amp * grow * prismaticBend(Pl * 0.6f, t);
        float a2 = 0.5f * amp * grow * prismaticBend(Pl.zyx * 0.5f + 3.1f, t * 0.9f);
        float3 Pb = Pl;
        Pb.xz = prismaticRot2(Pb.xz, a1);
        Pb.xy = prismaticRot2(Pb.xy, a2);
        float pattern = smoothstep(0.5f, 0.7f,
            sin(Pb.x + cos(Pb.y) * cos(Pb.z)) * sin(Pb.z + sin(Pb.y) * cos(Pb.x + t)));
        float gradientPosition = fract(marchT * 0.25f + impact * 0.09f);
        gradientPosition *= gradientPosition * (3.0f - 2.0f * gradientPosition);
        float3 gradient = gradientPosition < 0.5f
            ? mix(float3(colorA.rgb), float3(colorB.rgb), gradientPosition * 2.0f)
            : mix(float3(colorB.rgb), float3(colorC.rgb), (gradientPosition - 0.5f) * 2.0f);
        float3 spectral = 1.0f + cos(marchT * 3.0f + float3(0,1,2));
        float3 palette = mix(spectral, gradient * 2.0f, 0.58f);
        // GLSL reversed smoothstep(5,0,r) rewritten with defined Metal semantics.
        float3 base = (0.05f / (0.4f + stepLen)) * (1.0f - smoothstep(0.0f, 5.0f, rad)) * palette;
        col += base * pattern;
        marchT += stepLen;
    }
    float radius = length(frag - 0.5f * res) / (0.5f * min(res.x, res.y));
    float x = clamp(radius, 0.0f, 1.0f);
    float edge = pow((x*x*x * (x * (x * 6.0f - 15.0f) + 10.0f)) * 0.5f, 1.5f);
    edge = mix(edge, 1.0f - pow(1.0f - edge, 2.0f), 0.2f);
    col *= edge * (1.55f + impact * 0.75f + low * 0.12f);
    col = clamp(col, 0.0f, 1.0f);
    return half4(half3(col), 1.0h);
}
