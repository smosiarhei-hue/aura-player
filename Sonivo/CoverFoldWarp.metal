// Soft folding-card silhouette. The source is drawn into a transparent padded
// canvas so the stretched top and bottom can actually extend beyond the cover.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] float2 coverFoldWarp(
    float2 position,
    float side,
    float padX,
    float padY,
    float amount
) {
    float w = max(side, 1.0f);
    float a = clamp(amount, -1.0f, 1.0f);
    float magnitude = fabs(a);
    if (magnitude < 0.0008f) return position;

    float direction = a < 0.0f ? -1.0f : 1.0f;
    float nx = ((position.x - padX) / w) * 2.0f - 1.0f;
    // A flat inner half opens smoothly into the outward-facing edge.
    float edge = smoothstep(0.0f, 1.0f, max(0.0f, nx * direction));
    float strength = smoothstep(0.0f, 1.0f, magnitude) * edge;
    float middle = padY + w * 0.5f;

    // Inverse sampling stretches the image AND its silhouette, unlike warping
    // pixels inside the original rectangle where the curve is clipped away.
    float xSource = position.x - direction * w * 0.10f * strength;
    float ySource = middle + (position.y - middle) / (1.0f + 0.44f * strength);
    return float2(xSource, ySource);
}
