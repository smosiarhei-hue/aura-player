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

// Polar SDF Ring Deformation with dynamic music harmonics
static float sdDeformedRing(float2 p, float time, float bass, float mid) {
    float angle = atan2(p.y, p.x);
    float radius = length(p);

    // Dynamic harmonic wave oscillations + curl noise morphing
    float wave = sin(angle * 3.0 + time * 1.8) * 0.09 * (1.0 + mid * 2.5)
               + cos(angle * 5.0 - time * 1.2) * 0.06 * (0.8 + bass * 1.5)
               + noise2D(p * 2.8 + time * 0.50) * 0.16 * (0.40 + mid * 1.2);

    float baseRadius = 0.44 + bass * 0.22;
    float thickness = 0.045 + bass * 0.055;
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

    float r = length(uv);
    float angle = atan2(uv.y, uv.x);

    // Dynamic music-reactive chromatic dispersion (RGB spectral offset)
    float dispersion = 0.045 * (1.0 + high * 3.8);

    float distR = sdDeformedRing(uv * (1.0 + dispersion), time, bass, mid);
    float distG = sdDeformedRing(uv, time, bass, mid);
    float distB = sdDeformedRing(uv * (1.0 - dispersion), time, bass, mid);

    // Exponential HDR Bloom & Fresnel Glow
    half glowR = half(smoothstep(0.12, 0.0, distR) * 1.1 + 0.038 / (abs(distR) + 0.024));
    half glowG = half(smoothstep(0.12, 0.0, distG) * 1.1 + 0.038 / (abs(distG) + 0.024));
    half glowB = half(smoothstep(0.12, 0.0, distB) * 1.1 + 0.038 / (abs(distB) + 0.024));

    // Dynamic Caustic Rays reacting to music highs & mids
    float causticRays = sin(angle * 8.0 + time * 2.4) * cos(angle * 5.0 - time * 1.8);
    causticRays = pow(max(0.0, causticRays * 0.5 + 0.5), 3.0) * (0.25 + high * 2.8 + mid * 1.4);
    half rayGlow = half(causticRays * smoothstep(0.9, 0.2, r));

    // Specular Lens Glints / Star Flares rotating on bass peaks
    float2 rotUV;
    float rotA = time * 0.45 + bass * 0.8;
    float cosA = cos(rotA);
    float sinA = sin(rotA);
    rotUV.x = uv.x * cosA - uv.y * sinA;
    rotUV.y = uv.x * sinA + uv.y * cosA;
    float starFlare = max(0.0, 1.0 - abs(rotUV.x * rotUV.y) * 45.0) * smoothstep(0.7, 0.0, r);
    half flareGlow = half(starFlare * (0.6 + bass * 2.2 + high * 1.6));

    // Dynamic Multi-Color Interpolation with HDR White Highlights
    half4 finalColor = half4(0.0);
    finalColor.r = (glowR + rayGlow * 0.8 + flareGlow) * color1.r + (glowG + rayGlow * 0.5) * color2.r * 0.5;
    finalColor.g = (glowG + rayGlow * 0.8 + flareGlow) * color2.g + (glowB + rayGlow * 0.5) * color3.g * 0.5;
    finalColor.b = (glowB + rayGlow * 0.8 + flareGlow) * color3.b + (glowR + rayGlow * 0.5) * color1.b * 0.5;

    // Specular Hotspot Highlights (pure bright reflections)
    half specular = half(clamp(flareGlow * 0.65 + pow(max(0.0, float(glowG) - 1.2), 2.0), 0.0, 1.0));
    finalColor.rgb += half3(specular * 0.85);

    half maxAlpha = max(glowR, max(glowG, glowB)) + rayGlow * 0.7 + flareGlow * 0.9;
    finalColor.a = clamp(maxAlpha, half(0.0), half(1.0));

    return finalColor;
}
