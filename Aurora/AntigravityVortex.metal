// Path: Aurora/AntigravityVortex.metal
// Шейдер кинетического вихря «Антигравити» для экрана «Моя волна» (iOS 26+)

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 antigravityVortex(
    float2 position,
    half4 currentColor,
    float4 boundingRect,
    float distortionStrength,
    float vortexAngle,
    float colorShift,
    half4 neonAccent
) {
    float minDim = min(boundingRect.z, boundingRect.w);
    if (minDim <= 0.0) { return currentColor; }

    // Нормализованные координаты [-1, 1] относительно центра экрана
    float2 center = boundingRect.xy + 0.5 * boundingRect.zw;
    float2 uv = (position - center) / (minDim * 0.5);
    float r = length(uv);
    float angle = atan2(uv.y, uv.x);

    // Спиральное закручивание вихря (Swirl vortex)
    float swirl = (1.0 - smoothstep(0.0, 1.8, r)) * vortexAngle * distortionStrength;
    float twistedAngle = angle + swirl;

    // Световые неоновые всполохи в вихре
    float tendrils = sin(twistedAngle * 5.0) * cos(twistedAngle * 3.0 + r * 4.0);
    tendrils = pow(max(0.0, tendrils * 0.5 + 0.5), 2.5) * distortionStrength;

    // Спектральный переход: дымчато-серый -> угольно-черный
    half4 smokyGray = half4(0.24, 0.25, 0.28, 1.0);
    half4 charcoalBlack = half4(0.04, 0.04, 0.06, 1.0);
    half4 baseBackground = mix(smokyGray, charcoalBlack, half(clamp(colorShift, 0.0f, 1.0f)));

    // Всполохи неона в цветах текущего трека
    half4 neonBursts = neonAccent * half(tendrils * 1.5);
    half4 finalColor = baseBackground + neonBursts;
    finalColor.a = 1.0;

    return finalColor;
}
