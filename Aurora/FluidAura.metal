#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 2D Simplex / Hash Noise
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise2D(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i + float2(0.0, 0.0)), hash21(i + float2(1.0, 0.0)), u.x),
               mix(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), u.x), u.y);
}

// Polar SDF Ring Deformation
static float sdDeformedRing(float2 p, float time, float bass, float mid) {
    float angle = atan2(p.y, p.x);
    float radius = length(p);

    // Dynamic harmonic wave oscillations + curl noise morphing
    float wave = sin(angle * 3.0 + time * 1.6) * 0.08 * (1.0 + mid * 2.2)
               + cos(angle * 2.0 - time * 0.9) * 0.05
               + noise2D(p * 2.6 + time * 0.45) * 0.14 * (0.35 + mid);

    float baseRadius = 0.44 + bass * 0.16;
    float thickness = 0.042 + bass * 0.040;
    return abs(radius - (baseRadius + wave)) - thickness;
}

[[ stitchable ]] half4 fluidAuraWave(
    float2 position,
    half4 currentColor,
    float4 boundingRect,
    float time,
    float bass,
    float mid,
    float high,
    half4 color1,
    half4 color2,
    half4 color3
) {
    // Aspect-ratio normalized coordinates [-1, 1]
    float minDim = min(boundingRect.z, boundingRect.w);
    if (minDim <= 0.0) { return half4(0.0); }
    float2 uv = (position - boundingRect.xy - 0.5 * boundingRect.zw) / (minDim * 0.5);

    // Chromatic dispersion (RGB Spectral Offset)
    float dispersion = 0.038 * (1.0 + high * 3.2);

    float distR = sdDeformedRing(uv * (1.0 + dispersion), time, bass, mid);
    float distG = sdDeformedRing(uv, time, bass, mid);
    float distB = sdDeformedRing(uv * (1.0 - dispersion), time, bass, mid);

    // Exponential HDR Bloom & Fresnel Glow
    half glowR = half(smoothstep(0.09, 0.0, distR) + 0.028 / (abs(distR) + 0.028));
    half glowG = half(smoothstep(0.09, 0.0, distG) + 0.028 / (abs(distG) + 0.028));
    half glowB = half(smoothstep(0.09, 0.0, distB) + 0.028 / (abs(distB) + 0.028));

    // Dynamic Multi-Color Interpolation
    half4 finalColor = half4(0.0);
    finalColor.r = glowR * color1.r + glowG * color2.r * 0.45;
    finalColor.g = glowG * color2.g + glowB * color3.g * 0.45;
    finalColor.b = glowB * color3.b + glowR * color1.b * 0.45;
    finalColor.a = clamp(max(glowR, max(glowG, glowB)), half(0.0), half(1.0));

    return finalColor;
}
