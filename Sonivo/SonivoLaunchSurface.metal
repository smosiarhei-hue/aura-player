// Original Sonivo launch-only material. One stitchable color pass on the wordmark.
// No sampled textures, time accumulators, feedback buffers or full-screen blur.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 sonivoLaunchChrome(
    float2 position, half4 source, float2 size, float time, float lightAppearance
) {
    if (source.a <= half(0.0)) { return source; }
    float2 uv = position / max(size, float2(1.0));
    float t = clamp(time, 0.0f, 4.2f);
    // Slow curved reflections stay inside the native glyph alpha.
    float flow = 0.5f + 0.5f * sin(uv.x * 5.0f + uv.y * 2.4f - t * 0.62f);
    float band = 0.5f + 0.5f * cos(uv.y * 9.0f + flow * 0.65f);
    float sweep = uv.x - (0.02f + t * 0.27f) + 0.07f * sin(uv.y * 3.0f);
    float reflection = exp(-sweep * sweep / 0.010f);
    float warm = 0.5f + 0.5f * sin(uv.x * 4.0f - t * 0.43f);
    float3 rgb;
    if (lightAppearance > 0.5f) {
        // Dark polished metal on a light canvas: never white-on-white chrome.
        float base = 0.055f + 0.13f * band + 0.06f * reflection;
        rgb = float3(base + 0.025f * warm, base, base + 0.018f);
    } else {
        // The base remains readable without the moving reflection.
        float base = 0.62f + 0.18f * band + 0.16f * reflection;
        rgb = float3(base + 0.035f * warm, base, base + 0.025f);
    }
    // SDR only. Preserve SwiftUI's premultiplied alpha and antialiased glyph edges.
    return half4(half3(clamp(rgb, float3(0.0), float3(1.0))) * source.a, source.a);
}