# Sonivo / Resonance

Approved owner reference: asymmetric dark-glass ring, coral directional light, warm upper rim; Instrument Serif Regular wordmark. Icon contains no text. Seven in-app palettes do not change the fixed coral app icon.

## Shipped compatibility assets

`design/app-icon/generated/*.png.b64` stores opaque, square, unmasked 1024px RGB normal/dark/tinted icons, derived from the owner's approved reference. `scripts/materialize_app_icons.py` decodes these at build time using only the Python standard library. It also decodes the approved ring alpha mask from `generated/ResonanceRingMask.png.b64`. Native SwiftUI gradients supply the selected theme and one moving highlight; MP4 is not a runtime dependency.

## Icon Composer handoff (not a compiled .icon)

The SVGs are geometry-only layer candidates: background, asymmetric ring silhouette, upper warm-edge segment. They contain no gradient, baked shadow, rounded mask or material settings. Open on macOS in Icon Composer, review/smooth the traced paths, assign glass/materials and validate default/dark/tinted/clear appearances before replacing AppIcon with a real `.icon` document. Linux cannot validate Apple's system rendering. The included PNG compatibility icon must not be described as a native Liquid Glass icon.

## Motion

Owner preview is 5.8 seconds including about a second of settled home. Native overlay: 4.8 seconds; ring begins at 0.08, light sweep at 0.60, name at 1.55, tagline at 2.35, overlapping blur handoff at 3.75. Reduced Motion: static brand for 0.35 seconds. Two gentle haptic transients share the visual epoch; playback, Skip, background and deep links finish immediately.

No EQ, audio detector, wave physics, queue or music-haptic changes.
