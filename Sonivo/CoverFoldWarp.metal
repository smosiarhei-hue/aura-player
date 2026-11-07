// Folding-cards cover warp (Basit / Bencho): cylindrical foreshortening + edge bow.
// distortionEffect samples FROM the returned position — curved top/bottom edges,
// not a rigid plane (rotation3DEffect alone cannot do this).
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] float2 coverFoldWarp(
    float2 position,
    float2 size,
    float amount
) {
    float w = max(size.x, 1.0f);
    float h = max(size.y, 1.0f);
    float a = clamp(amount, -1.25f, 1.25f);
    if (fabs(a) < 0.0008f) {
        return position;
    }

    float2 uv = float2(position.x / w, position.y / h);
    float nx = uv.x * 2.0f - 1.0f; // -1 left … +1 right

    // Outer half (sign matches fold direction) compresses toward the hinge.
    float outer = max(0.0f, nx * a);
    float pull = outer * fabs(a);

    // Read farther toward the folding-away edge → foreshortened face.
    float xSrc = nx + pull * 0.58f * nx;

    // Sinusoidal vertical bow — top/bottom edges curve like the reference mesh.
    float bow = sin(uv.y * 3.14159265f) * pull * pull * 0.14f;

    return float2((xSrc * 0.5f + 0.5f) * w, (uv.y + bow * ((a < 0.0f) ? -1.0f : 1.0f)) * h);
}
