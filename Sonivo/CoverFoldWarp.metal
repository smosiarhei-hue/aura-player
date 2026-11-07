// Folding-cards cover warp (Basit / Bencho):
// separate floating plates with a strong jelly/mesh edge bend.
// Rigid rotation3DEffect alone produces "cubes" — this shader is the look.
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
    float a = clamp(amount, -1.0f, 1.0f);
    float mag = fabs(a);
    if (mag < 0.0008f) {
        return position;
    }

    float2 uv = float2(position.x / w, position.y / h);
    float nx = uv.x * 2.0f - 1.0f; // -1 left … +1 right
    float ny = uv.y * 2.0f - 1.0f;

    // Folding-away half (same sign as amount) gets the mesh.
    float outer = max(0.0f, nx * a);
    float pull = outer * mag;

    // Strong cylindrical foreshortening toward the trailing edge.
    float compress = pull * pull;
    float xSrc = nx
        + compress * 0.95f * nx
        - pull * 0.42f * ((a < 0.0f) ? -1.0f : 1.0f);

    // Primary vertical bow — the soft curved silhouette from the reference.
    float bow = sin(uv.y * 3.14159265f) * compress * 0.42f;
    // Secondary ripple so the edge reads as a mesh, not a hard box side.
    float ripple = sin(uv.y * 3.14159265f * 2.0f) * pull * 0.10f;
    // Mild vertical stretch near the warped edge (reference jelly corners).
    float yStretch = ny * compress * 0.12f;

    float ySrc = uv.y
        + (bow + ripple) * ((a < 0.0f) ? -1.0f : 1.0f)
        + yStretch * 0.5f;

    return float2((xSrc * 0.5f + 0.5f) * w, ySrc * h);
}
