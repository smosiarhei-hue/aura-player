// Native Metal port of the user's Three.js ShaderAnimation fragment shader.
// Legacy filename retained; the old antigravity vortex implementation is removed.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 radialShaderAnimation(
    float2 position, half4 currentColor, float4 bounds, float elapsed, float impulse
) {
    float minDim = max(1.0f, min(bounds.z, bounds.w));
    // Match WebGL's bottom-up gl_FragCoord and normalize for every screen aspect.
    float2 pixel = position - bounds.xy;
    pixel.y = bounds.w - pixel.y;
    float2 uv = (pixel * 2.0f - bounds.zw) / minDim;
    // Compression/release affects the whole field, not the artwork's contour.
    uv /= (1.0f + clamp(impulse, 0.0f, 1.0f) * 0.20f);
    float t = elapsed * 0.30f;
    float lineWidth = 0.002f;
    float3 color = float3(0.0f);
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 5; i++) {
            // GLSL mod is floor-based (Metal fmod differs for negative values).
            float diagonal = uv.x + uv.y;
            float grid = diagonal - 0.2f * floor(diagonal / 0.2f);
            float distance = abs(fract(t - 0.01f * float(j) + float(i) * 0.01f)
                                 * 5.0f - length(uv) + grid);
            // Finite denominator prevents white singularities/NaNs in the reference.
            float pixelWidth = 1.2f / minDim;
            color[j] += lineWidth * float(i * i) / max(pixelWidth, distance);
        }
    }
    color *= 0.32f + clamp(impulse, 0.0f, 1.0f) * 0.22f;
    color = color / (1.0f + color); // bounded radiance; no full-screen strobe
    // Transparent between the rings. SwiftUI colorEffect requires premultiplied RGB.
    float glowAlpha = clamp(max(color.r, max(color.g, color.b)), 0.0f, 1.0f);
    return half4(half3(color * glowAlpha), half(glowAlpha));
}
