// Original Sonivo music-reactive ribbon field. No ray marching, grain, or strobe.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 musicWaveRibbons(
    float2 position, half4 currentColor, float4 bounds,
    float phase, float energy, float impact, float detail, float darkMode,
    half4 colorA, half4 colorB, half4 colorC
) {
    float2 uv = clamp((position - bounds.xy) / max(bounds.zw, float2(1.0f)), 0.0f, 1.0f);
    float aspect = clamp(bounds.z / max(bounds.w, 1.0f), 0.35f, 2.5f);
    float x = (uv.x - 0.5f) * aspect * 2.0f;
    float strength = clamp(energy, 0.0f, 1.0f);
    float pulse = clamp(impact, 0.0f, 1.0f);
    float shimmer = clamp(detail, 0.0f, 1.0f);
    float3 pigment = float3(0.0f);
    float weight = 0.0f;
    for (int i = 0; i < 5; i++) {
        float layer = float(i);
        float offset = layer * 1.17f;
        float amplitude = 0.055f + strength * 0.085f + pulse * 0.035f;
        float center = 0.23f + layer * 0.135f
            + amplitude * sin(x * (2.4f + layer * 0.34f) - phase * (0.80f + layer * 0.09f) + offset)
            + 0.034f * sin(x * 5.0f + phase * 0.44f - offset);
        // Small travelling ripples ride the large ribbons; transients bend rather than flash.
        center += pulse * 0.018f * sin(x * 8.0f - phase * 1.4f + offset);
        float distance = abs(uv.y - center);
        float width = 0.012f + strength * 0.016f + shimmer * 0.004f;
        float core = exp(-pow(distance / width, 2.0f));
        float halo = exp(-pow(distance / (width * 4.5f), 2.0f));
        float ribbon = core * 0.28f + halo * 0.14f;
        float blend = clamp(layer / 4.0f + 0.08f * sin(phase * 0.25f + offset), 0.0f, 1.0f);
        float3 tint = blend < 0.5f
            ? mix(float3(colorA.rgb), float3(colorB.rgb), blend * 2.0f)
            : mix(float3(colorB.rgb), float3(colorC.rgb), (blend - 0.5f) * 2.0f);
        pigment += tint * ribbon;
        weight += ribbon;
    }
    // Wide feathered falloff on ALL edges, especially the bottom into themed sections.
    float featherX = smoothstep(0.0f, 0.16f, uv.x) * (1.0f - smoothstep(0.84f, 1.0f, uv.x));
    float featherY = smoothstep(0.0f, 0.14f, uv.y) * (1.0f - smoothstep(0.78f, 1.0f, uv.y));
    float alpha = min(weight, 0.72f) * featherX * featherY
        * mix(0.64f, 1.0f, darkMode) * (0.78f + strength * 0.22f);
    float3 rgb = clamp(pigment / max(weight, 0.0001f), 0.0f, 1.0f);
    // SwiftUI color effects return premultiplied alpha for correct light/dark compositing.
    return half4(half3(rgb * alpha), half(alpha)) * currentColor.a;
}
